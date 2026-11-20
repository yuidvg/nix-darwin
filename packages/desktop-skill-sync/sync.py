"""Reconcile Claude Desktop account skills against a directory of skill ZIPs.

`reconcile` is a coroutine: it yields effects and receives their results, and
never performs IO itself. Two drivers interpret it:

  plan   offline; reads Claude Desktop's local skills manifest, uploads nothing.
  apply  sends operations to Safari (Apple Events) and uploads from a
         claude.ai tab with that tab's own session. No cookie or token leaves
         the browser. It does not touch Safari when the local state says
         every skill is synced. Otherwise the uploads depend on a signed-in
         tab: apply uses one that is open or opens one in the background,
         and brings Safari forward only when a sign-in is needed.

Re-running is safe. State is written after each verified upload, so an
interrupted run resumes with what is left. Account skills are never deleted,
and a skill this tool did not upload is replaced only with --adopt.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

ORIGIN = "https://claude.ai"
SETTINGS_URL = f"{ORIGIN}/settings/capabilities"
STATE_DIR = Path(
    os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")
) / "desktop-skill-sync"
DESKTOP_MANIFESTS = str(
    Path.home()
    / "Library/Application Support/Claude/local-agent-mode-sessions"
    / "skills-plugin/*/*/manifest.json"
)


# --- desired state ---------------------------------------------------------


@dataclass(frozen=True)
class Desired:
    name: str  # name in the skill's frontmatter; the account's key
    zip_path: Path
    sha256: str


def frontmatter_name(zip_path: Path) -> str:
    with zipfile.ZipFile(zip_path) as z:
        entry = next(
            (n for n in z.namelist() if re.fullmatch(r"[^/]+/skill\.md", n, re.I)),
            None,
        )
        if entry is None:
            raise SystemExit(f"{zip_path.name}: no <skill>/Skill.md inside")
        text = z.read(entry).decode("utf-8")
    block = re.match(r"---\n(.*?)\n---", text, re.S)
    found = block and re.search(r"^name:\s*(.+?)\s*$", block.group(1), re.M)
    if not found:
        raise SystemExit(f"{zip_path.name}: Skill.md has no frontmatter name")
    return found.group(1).strip("\"'")


def load_desired(zip_dir: Path) -> list[Desired]:
    zips = sorted(zip_dir.glob("*.zip"))
    if not zips:
        raise SystemExit(f"no skill ZIPs in {zip_dir}")
    return [
        Desired(
            name=frontmatter_name(p),
            zip_path=p,
            sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
        )
        for p in zips
    ]


# --- effects ---------------------------------------------------------------


DONE = "done"
DRY_RUN = "dry-run"


@dataclass(frozen=True)
class ListRemote:
    """-> {name: {"updated_at": str | None, "creator": str | None}}"""


@dataclass(frozen=True)
class Upload:
    """-> DONE, DRY_RUN, or an error message."""

    skill: Desired
    overwrite: bool


@dataclass(frozen=True)
class Record:
    """Persist that `skill` is on the account as of `updated_at`."""

    skill: Desired
    updated_at: str | None


@dataclass(frozen=True)
class Report:
    name: str
    status: str
    detail: str = ""


def reconcile(desired: list[Desired], state: dict, adopt: set[str]):
    remote = yield ListRemote()
    for skill in desired:
        there = remote.get(skill.name)
        known = state.get(skill.name)

        if there is None:
            overwrite = False
        elif known is None:
            if skill.name not in adopt:
                yield Report(
                    skill.name,
                    "unmanaged",
                    "already on the account, not uploaded by this tool; "
                    "pass --adopt to replace it",
                )
                continue
            overwrite = True
        elif known.get("updated_at") != there.get("updated_at"):
            if skill.name not in adopt:
                yield Report(
                    skill.name,
                    "conflict",
                    "changed on the account since the last sync; "
                    "pass --adopt to replace it",
                )
                continue
            overwrite = True
        elif known.get("sha256") == skill.sha256:
            yield Report(skill.name, "in sync")
            continue
        else:
            overwrite = True

        outcome = yield Upload(skill, overwrite)
        if outcome == DRY_RUN:
            yield Report(skill.name, "would replace" if overwrite else "would create")
            continue
        if outcome != DONE:
            yield Report(skill.name, "failed", outcome)
            continue

        after = (yield ListRemote()).get(skill.name)
        if after is None:
            yield Report(skill.name, "failed", "accepted but not listed afterwards")
            continue
        yield Record(skill, after.get("updated_at"))
        yield Report(skill.name, "replaced" if overwrite else "created")


def run(coroutine, handle) -> list[Report]:
    """Drive `coroutine`, answering each effect with `handle(effect)`."""
    reports: list[Report] = []
    answer = None
    try:
        while True:
            effect = coroutine.send(answer)
            if isinstance(effect, Report):
                reports.append(effect)
                detail = f"  ({effect.detail})" if effect.detail else ""
                print(f"  {effect.status:14} {effect.name}{detail}", flush=True)
                answer = None
            else:
                answer = handle(effect)
    except StopIteration:
        return reports


# --- state -----------------------------------------------------------------


def load_state() -> dict:
    path = STATE_DIR / "state.json"
    return json.loads(path.read_text()) if path.exists() else {}


def save_state(state: dict) -> None:
    path = STATE_DIR / "state.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def record(state: dict, effect: Record) -> None:
    state[effect.skill.name] = {
        "sha256": effect.skill.sha256,
        "updated_at": effect.updated_at,
        "synced_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    save_state(state)


def normalise(skills: list[dict]) -> dict:
    return {
        s["name"]: {
            "updated_at": s.get("updated_at", s.get("updatedAt")),
            "creator": s.get("creator_type", s.get("creatorType")),
        }
        for s in skills
        if isinstance(s, dict) and s.get("name")
    }


# --- plan driver (offline) -------------------------------------------------


def desktop_manifest_remote() -> dict:
    paths = sorted(glob.glob(DESKTOP_MANIFESTS), key=os.path.getmtime)
    if not paths:
        raise SystemExit(
            "Claude Desktop's skills manifest was not found; run `apply` instead"
        )
    return normalise(json.loads(Path(paths[-1]).read_text()).get("skills", []))


def drive_plan(desired, state, adopt) -> list[Report]:
    remote = desktop_manifest_remote()

    def handle(effect):
        if isinstance(effect, ListRemote):
            return remote
        if isinstance(effect, Upload):
            return DRY_RUN
        raise AssertionError(effect)

    return run(reconcile(desired, state, adopt), handle)


# --- apply driver (Safari) --------------------------------------------------
#
# Operations are sent to Safari as Apple Events (`do JavaScript`) and run in a
# claude.ai tab of the user's own Safari, with its session. Nothing is clicked
# and Safari is not brought forward unless a sign-in is needed.

RESULTS = "__desktopSkillSync"

JS_GET = """(async () => {
  const r = await fetch(%(path)s, {credentials: 'include'});
  let body = null;
  try { body = await r.json(); } catch {}
  return {status: r.status, body};
})()"""

JS_UPLOAD = """(async () => {
  const bytes = Uint8Array.from(atob(%(b64)s), c => c.charCodeAt(0));
  const form = new FormData();
  form.append('file', new Blob([bytes], {type: 'application/zip'}), %(filename)s);
  const r = await fetch(%(path)s, {method: 'POST', body: form, credentials: 'include'});
  let body = null;
  try { body = await r.json(); } catch {}
  return {status: r.status, body};
})()"""

JS_LAST_ORG = "(document.cookie.match(/(?:^|; )lastActiveOrg=([^;]+)/) || [])[1] || null"

# `do JavaScript` returns synchronously, so a promise is started here and its
# settled value is collected by JS_COLLECT on a later call.
JS_START = """(() => {
  if (location.origin !== %(origin)s) return 'elsewhere';
  const box = window[%(box)s] = window[%(box)s] || {};
  box[%(key)s] = '';
  Promise.resolve().then(() => (%(expr)s)).then(
    v => { box[%(key)s] = JSON.stringify({value: v === undefined ? null : v}); },
    e => { box[%(key)s] = JSON.stringify({error: String(e)}); });
  return 'started';
})()"""

JS_COLLECT = """(() => {
  const box = window[%(box)s] || {};
  const got = box[%(key)s] || '';
  if (got) delete box[%(key)s];
  return got;
})()"""

# argv: 1 = origin, 2 = path of a file holding the JavaScript.
OSA_EVAL = """on run argv
  set js to read (POSIX file (item 2 of argv)) as «class utf8»
  tell application "Safari"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if URL of t starts with (item 1 of argv) then
            set got to do JavaScript js in t
            if got is missing value then return ""
            return got as text
          end if
        end try
      end repeat
    end repeat
  end tell
  return "no-tab"
end run"""

# argv: 1 = URL. Opens it in a background tab; an empty Safari gets a window.
OSA_OPEN = """on run argv
  tell application "Safari"
    if (count of windows) is 0 then
      make new document with properties {URL:(item 1 of argv)}
    else
      tell window 1 to make new tab with properties {URL:(item 1 of argv)}
    end if
  end tell
end run"""

# argv: 1 = origin. Shows the tab so the user can sign in.
OSA_SHOW = """on run argv
  tell application "Safari"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if URL of t starts with (item 1 of argv) then
            set current tab of w to t
            set index of w to 1
            activate
            return
          end if
        end try
      end repeat
    end repeat
  end tell
end run"""

# argv: 1 = URL prefix. Closes the first matching tab.
OSA_CLOSE = """on run argv
  tell application "Safari"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if URL of t starts with (item 1 of argv) then
            close t
            return
          end if
        end try
      end repeat
    end repeat
  end tell
end run"""


class NotSignedIn(Exception):
    pass


class SafariError(Exception):
    pass


def osascript(script: str, *argv: str, timeout_s: int = 60) -> str:
    try:
        done = subprocess.run(
            ["/usr/bin/osascript", "-", *argv],
            input=script,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        raise SafariError(
            "Safari did not answer. macOS may be asking whether this terminal "
            "may control Safari: allow it (System Settings › Privacy & "
            "Security › Automation) and run again."
        ) from None
    if done.returncode != 0:
        message = done.stderr.strip()
        if "Allow JavaScript from Apple Events" in message:
            message = (
                "Safari refuses JavaScript from Apple Events. Turn on Safari › "
                "Settings › Developer › “Allow JavaScript from Apple Events” "
                "(enable “Show features for web developers” under Advanced "
                "first) and run again."
            )
        raise SafariError(message)
    return done.stdout.rstrip("\n")


class Safari:
    """A claude.ai tab in the user's Safari, addressed by Apple Events."""

    def __init__(self):
        self.opened_tab = False
        self.calls = 0

    def send(self, javascript: str) -> str:
        """Run `javascript` in the claude.ai tab; 'no-tab' when there is none."""
        script = STATE_DIR / "safari-call.js"
        script.write_text(javascript)
        try:
            return osascript(OSA_EVAL, ORIGIN, str(script))
        finally:
            script.unlink(missing_ok=True)

    def js(self, template: str, timeout_s: int = 120, **values):
        """Evaluate a (possibly async) expression; None when it did not run."""
        self.calls += 1
        slot = {
            "box": json.dumps(RESULTS),
            "key": json.dumps(f"call{os.getpid()}_{self.calls}"),
        }
        expr = template % {k: json.dumps(v) for k, v in values.items()}
        started = self.send(
            JS_START % {**slot, "origin": json.dumps(ORIGIN), "expr": expr}
        )
        if started != "started":
            return None
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            got = self.send(JS_COLLECT % slot)
            if got and got != "no-tab":
                settled = json.loads(got)
                return settled.get("value") if "error" not in settled else None
            time.sleep(0.3)
        return None

    def ensure_tab(self) -> None:
        if self.send("'here'") == "no-tab":
            osascript(OSA_OPEN, SETTINGS_URL)
            self.opened_tab = True

    def show(self) -> None:
        osascript(OSA_SHOW, ORIGIN)

    def close(self) -> None:
        if self.opened_tab:
            try:
                osascript(OSA_CLOSE, SETTINGS_URL)
            except SafariError:
                pass


def signed_in_safari(timeout_s: int):
    """Resolve the uploads' prerequisite: a claude.ai tab with a session.

    Uses a claude.ai tab already open in Safari, or opens one in the
    background. Only when that tab has no session is Safari brought forward,
    for the user to sign in. Returns (safari, organizations).
    """
    safari = Safari()
    safari.ensure_tab()
    try:
        shown = False
        quiet_until = time.monotonic() + 20  # let a fresh tab load
        deadline = time.monotonic() + timeout_s
        last = None
        while time.monotonic() < deadline:
            last = safari.js(JS_GET, timeout_s=30, path="/api/organizations")
            if last and last["status"] == 200 and isinstance(last["body"], list):
                return safari, last["body"]
            if not shown and time.monotonic() > quiet_until:
                safari.show()
                print("  no claude.ai session in Safari; sign in in the tab "
                      "that was just brought forward. Waiting…", flush=True)
                shown = True
            time.sleep(2)
        raise NotSignedIn(f"last response: HTTP {last and last['status']}")
    except BaseException:
        safari.close()
        raise


def choose_org(orgs: list[dict], safari: Safari, wanted: str | None) -> str:
    ids = [o.get("uuid") for o in orgs if o.get("uuid")]
    if wanted:
        if wanted not in ids:
            raise SystemExit(f"--org {wanted} is not one of this account's organizations")
        return wanted
    last = safari.js(JS_LAST_ORG)
    if last in ids:
        return last
    if len(ids) == 1:
        return ids[0]
    listing = "\n".join(f"  {o.get('uuid')}  {o.get('name')}" for o in orgs)
    raise SystemExit(f"several organizations; pass --org <uuid>:\n{listing}")


def upload(safari: Safari, base: str, effect: Upload) -> str:
    flag = "true" if effect.overwrite else "false"
    got = safari.js(
        JS_UPLOAD,
        timeout_s=300,
        b64=base64.b64encode(effect.skill.zip_path.read_bytes()).decode(),
        filename=f"{effect.skill.name}.skill",
        path=f"{base}/upload-skill?overwrite={flag}",
    )
    if not got:
        return "the upload request did not complete"
    body = got["body"] or {}
    if got["status"] >= 400:
        message = (body.get("error") or {}).get("message") or body
        return f"HTTP {got['status']}: {message}"
    problems = [
        e.get("message") or e.get("error_code")
        for e in body.get("validation_errors") or []
    ]
    return "; ".join(map(str, problems)) if problems else DONE


def drive_apply(desired, state, adopt, org: str | None, timeout_s: int):
    safari, orgs = signed_in_safari(timeout_s)
    try:
        base = f"/api/organizations/{choose_org(orgs, safari, org)}/skills"

        def handle(effect):
            if isinstance(effect, ListRemote):
                got = safari.js(JS_GET, path=f"{base}/list-skills")
                if not got or got["status"] != 200:
                    raise SystemExit(f"listing skills failed: {got and got['status']}")
                return normalise(got["body"].get("skills", []))
            if isinstance(effect, Upload):
                return upload(safari, base, effect)
            if isinstance(effect, Record):
                record(state, effect)
                return None
            raise AssertionError(effect)

        return run(reconcile(desired, state, adopt), handle)
    finally:
        safari.close()


# --- entry point -----------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="sync-desktop-skills", description=__doc__.split("\n\n")[0]
    )
    parser.add_argument("mode", nargs="?", choices=["plan", "apply"], default="plan")
    parser.add_argument(
        "--zip-dir",
        type=Path,
        default=os.environ.get("DESKTOP_SKILLS_DIR"),
        help="directory of <skill>.zip files (set by the Nix wrapper)",
    )
    parser.add_argument(
        "--adopt",
        action="append",
        default=[],
        metavar="NAME",
        help="replace this account skill even though this tool did not upload "
        "it, or it changed on the account (repeatable; 'all' for every skill)",
    )
    parser.add_argument("--org", help="organization UUID, when the account has several")
    parser.add_argument("--login-timeout", type=int, default=600, metavar="SECONDS")
    args = parser.parse_args()
    if args.zip_dir is None:
        parser.error("--zip-dir is required")

    desired = load_desired(Path(args.zip_dir))
    adopt = {d.name for d in desired} if "all" in args.adopt else set(args.adopt)
    unknown = adopt - {d.name for d in desired}
    if unknown:
        parser.error(f"--adopt names not in the desired set: {', '.join(sorted(unknown))}")

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / "lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another sync-desktop-skills run is in progress", file=sys.stderr)
            return 75
        state = load_state()
        if args.mode == "plan":
            print("Plan (against Claude Desktop's local copy, which can lag "
                  "the account):")
            reports = drive_plan(desired, state, adopt)
        elif not adopt and all(
            state.get(d.name, {}).get("sha256") == d.sha256 for d in desired
        ):
            print(f"Desktop skills: {len(desired)} in sync (local state); "
                  "nothing to upload.")
            return 0
        else:
            print("Apply:")
            try:
                reports = drive_apply(
                    desired, state, adopt, args.org, args.login_timeout
                )
            except NotSignedIn as err:
                print(f"timed out waiting for the claude.ai sign-in ({err})",
                      file=sys.stderr)
                return 2
            except SafariError as err:
                print(f"Safari: {err}", file=sys.stderr)
                return 2

    return 1 if any(r.status == "failed" for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
