# skill-import: unpack a Claude `.skill` archive into the canonical skill tree
# `.skill` is a transport format (a zip of one directory). Storage format here
# is a plain directory under prompt/claude-code/skills/<name>/, which
# modules/claude-code.nix picks up via readDir with no Nix edit required.
# Dependencies injected by Nix: unzip, coreutils, findutils, gnused, gawk, git
# Strict mode (errexit/nounset/pipefail) is supplied by writeShellApplication.

REPO=""
NAME_OVERRIDE=""
FORCE=0
DO_GIT_ADD=1
SKILLS_REL="prompt/claude-code/skills"

usage() {
  cat <<'HELP'
skill-import - Unpack a Claude .skill archive into prompt/claude-code/skills/

USAGE:
  skill-import <path.skill | directory> [OPTIONS]

DESCRIPTION:
  Extracts a .skill archive (or copies a plain directory) into the canonical
  skill tree, normalises it, validates the SKILL.md frontmatter, and stages the
  result with `git add`.

  No Nix edit is needed to add a skill: modules/claude-code.nix enumerates
  prompt/claude-code/skills/ with readDir and projects every DIRECTORY into
  ~/.claude/skills, ~/.codex/skills, and the desktop-skills ZIPs. A .skill file
  left in that tree is silently ignored, which is why this tool exists.

OPTIONS:
  -C, --repo <dir>   Repository root. Default: $NIX_DARWIN_DIR, else the git
                     root of the current directory if it contains the skill
                     tree, else /etc/nix-darwin.
  -n, --name <name>  Force the skill directory name. Default: the `name:` field
                     in SKILL.md frontmatter, falling back to the archive's
                     top-level directory, then the file basename.
  -f, --force        Replace an existing skill directory of the same name.
      --no-add       Skip `git add` (Nix path inputs ignore untracked files, so
                     a build right after will not see the new skill).
  -h, --help         Show this help.

NORMALISATION:
  - drops .DS_Store, __MACOSX, and ._* resource forks
  - renames Skill.md to SKILL.md (two-step, for case-insensitive filesystems)
  - resets modes to u=rwX,go=rX

VALIDATION (fatal unless noted):
  - SKILL.md exists
  - YAML frontmatter delimited by --- on line 1
  - `name:` and `description:` are both present
  - `name:` matches the target directory. Claude keys skills by directory, so
    frontmatter is authoritative by default and the two cannot diverge; this
    only rejects a --name that contradicts SKILL.md.
  - description longer than 1024 characters (warning only)

EXAMPLES:
  skill-import ~/Downloads/carnegie-influence.skill
  skill-import ~/Downloads/foo.skill -n better-name -f
  skill-import ./some-skill-dir -C /etc/nix-darwin
HELP
}

die() {
  echo "skill-import: $*" >&2
  exit 1
}

warn() {
  echo "skill-import: warning: $*" >&2
}

# Read one top-level key out of the YAML frontmatter block.
# Exits non-zero when line 1 is not the opening ---.
read_frontmatter_key() {
  awk -v key="$1" '
    NR == 1 {
      if ($0 !~ /^---[[:space:]]*$/) { exit 2 }
      next
    }
    /^---[[:space:]]*$/ { exit 0 }
    {
      k = $0
      sub(/:.*$/, "", k)
      if (k == key) {
        v = $0
        sub(/^[^:]*:[[:space:]]*/, "", v)
        print v
        exit 0
      }
    }
  ' "$2"
}

SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -C | --repo)
      [ $# -ge 2 ] || die "$1 needs a directory"
      REPO="$2"
      shift 2
      ;;
    -n | --name)
      [ $# -ge 2 ] || die "$1 needs a name"
      NAME_OVERRIDE="$2"
      shift 2
      ;;
    -f | --force)
      FORCE=1
      shift
      ;;
    --no-add)
      DO_GIT_ADD=0
      shift
      ;;
    -*)
      die "unknown option '$1' (--help for usage)"
      ;;
    *)
      [ -z "$SOURCE" ] || die "expected exactly one source, got '$SOURCE' and '$1'"
      SOURCE="$1"
      shift
      ;;
  esac
done

[ -n "$SOURCE" ] || {
  usage >&2
  exit 1
}
[ -e "$SOURCE" ] || die "no such file or directory: $SOURCE"

# ── Resolve the repository root ───────────────────────────────────────────
if [ -z "$REPO" ]; then
  if [ -n "${NIX_DARWIN_DIR:-}" ]; then
    REPO="$NIX_DARWIN_DIR"
  else
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$git_root" ] && [ -d "$git_root/$SKILLS_REL" ]; then
      REPO="$git_root"
    else
      REPO="/etc/nix-darwin"
    fi
  fi
fi

[ -d "$REPO/$SKILLS_REL" ] || die "no $SKILLS_REL under '$REPO' (use --repo)"
SKILLS_DIR="$(cd "$REPO/$SKILLS_REL" && pwd)"

# ── Stage the payload in a scratch directory ──────────────────────────────
work="$(mktemp -d)"
# shellcheck disable=SC2064  # expand $work now, not at trap time
trap "rm -rf '$work'" EXIT
extract="$work/extract"
mkdir -p "$extract"

if [ -d "$SOURCE" ]; then
  cp -R "$SOURCE/." "$extract/"
else
  unzip -q "$SOURCE" -d "$extract" || die "not a readable zip archive: $SOURCE"
fi

find "$extract" \( -name '.DS_Store' -o -name '__MACOSX' -o -name '._*' \) \
  -exec rm -rf {} + 2>/dev/null || true

# ── Locate the skill root (archives wrap in a directory; directories do not) ──
shopt -s nullglob
entries=("$extract"/*)
shopt -u nullglob

case "${#entries[@]}" in
  0) die "archive is empty: $SOURCE" ;;
  1)
    if [ -d "${entries[0]}" ]; then
      root="${entries[0]}"
      archive_name="$(basename "$root")"
    else
      root="$extract"
      archive_name=""
    fi
    ;;
  *)
    root="$extract"
    archive_name=""
    ;;
esac

# ── Normalise the main file to SKILL.md ───────────────────────────────────
main_file=""
for candidate in "$root"/*; do
  base="$(basename "$candidate")"
  case "$base" in
    [Ss][Kk][Ii][Ll][Ll].md) main_file="$base" ;;
  esac
done

[ -n "$main_file" ] || die "no SKILL.md at the archive root (found: $(
  cd "$root" && printf '%s ' * 2>/dev/null || echo 'nothing'
))"

if [ "$main_file" != "SKILL.md" ]; then
  # Two-step: a direct rename is a no-op on case-insensitive filesystems.
  mv "$root/$main_file" "$root/.skill-import-rename.md"
  mv "$root/.skill-import-rename.md" "$root/SKILL.md"
  echo "skill-import: renamed $main_file -> SKILL.md"
fi

# ── Decide the skill name ─────────────────────────────────────────────────
fm_status=0
fm_name="$(read_frontmatter_key name "$root/SKILL.md")" || fm_status=$?
[ "$fm_status" -ne 2 ] || die "SKILL.md has no YAML frontmatter (line 1 must be ---)"

fm_description="$(read_frontmatter_key description "$root/SKILL.md")" || true

if [ -n "$NAME_OVERRIDE" ]; then
  name="$NAME_OVERRIDE"
  origin="--name"
elif [ -n "$fm_name" ]; then
  name="$fm_name"
  origin="SKILL.md frontmatter"
elif [ -n "$archive_name" ]; then
  name="$archive_name"
  origin="archive directory"
else
  name="$(basename "$SOURCE")"
  name="${name%.skill}"
  origin="source filename"
fi

case "$name" in
  '' | */* | .*) die "refusing unusable skill name: '$name'" ;;
esac

# ── Validate ──────────────────────────────────────────────────────────────
[ -n "$fm_name" ] || die "SKILL.md frontmatter is missing 'name:'"
[ -n "$fm_description" ] || die "SKILL.md frontmatter is missing 'description:'"

if [ "$fm_name" != "$name" ]; then
  die "frontmatter name '$fm_name' does not match target directory '$name' (Claude keys skills by directory; fix SKILL.md or pass --name)"
fi

desc_len="${#fm_description}"
if [ "$desc_len" -gt 1024 ]; then
  warn "description is $desc_len characters; Claude's limit is 1024"
fi

# ── Install ───────────────────────────────────────────────────────────────
dest="$SKILLS_DIR/$name"
if [ -e "$dest" ]; then
  [ "$FORCE" -eq 1 ] || die "'$name' already exists at $dest (use --force to replace)"
  rm -rf "$dest"
  echo "skill-import: replaced existing $name"
fi

mkdir -p "$dest"
cp -R "$root/." "$dest/"
chmod -R u=rwX,go=rX "$dest"

echo "skill-import: installed $name (name from $origin)"
find "$dest" -type f | sed "s|^$SKILLS_DIR/|  |" | sort

# ── Stage, so Nix path inputs actually see it ─────────────────────────────
if [ "$DO_GIT_ADD" -eq 1 ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" add -- "$dest"
  echo "skill-import: staged with git add"
fi

cat <<NEXT

next:
  nix build .#desktop-skills --no-link --print-out-paths
  git -C $REPO commit
  $REPO/apply
NEXT
