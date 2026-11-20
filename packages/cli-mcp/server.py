"""Minimal stdio MCP server with one tool that runs a local command.

argv is executed as-is (no shell); stdin is passed through. stdout, stderr
and a non-zero exit code are returned to the caller.
"""

import json
import subprocess
import sys

SUPPORTED_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

TOOL = {
    "name": "run",
    "description": (
        "Run a command on the user's Mac and return its output. `argv[0]` is "
        "the program (resolved on PATH, e.g. cosense, gws, freee-call, git), "
        "the rest are its arguments; no shell is involved, so use "
        "[\"sh\", \"-c\", \"...\"] for pipes or redirects. `stdin` is written "
        "to the program's stdin. Cosense: use the cosense CLI as the cosense "
        "skill describes; default project https://scrapbox.io/diverge-internal."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "argv": {
                "type": "array",
                "items": {"type": "string"},
                "minItems": 1,
                "description": "Program and arguments, e.g. [\"cosense\", \"--help\"]",
            },
            "stdin": {"type": "string", "description": "Text written to stdin."},
            "cwd": {"type": "string", "description": "Working directory (default: home)."},
            "timeoutSeconds": {"type": "number", "description": "Default 300."},
        },
        "required": ["argv"],
        "additionalProperties": False,
    },
}


def run(arguments):
    argv = arguments.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise ValueError("argv must be a non-empty array of strings")
    stdin = arguments.get("stdin")
    timeout = arguments.get("timeoutSeconds") or 300
    try:
        proc = subprocess.run(
            argv,
            input=stdin if isinstance(stdin, str) else "",
            capture_output=True,
            text=True,
            cwd=arguments.get("cwd") or None,
            timeout=timeout,
        )
    except FileNotFoundError as e:
        return f"{e}", True
    except subprocess.TimeoutExpired:
        return f"timed out after {timeout}s", True
    out = proc.stdout
    if proc.stderr:
        out = f"{out}\n[stderr]\n{proc.stderr}" if out else proc.stderr
    if proc.returncode != 0:
        out = f"{out}\n[exit {proc.returncode}]"
    return out, proc.returncode != 0


def handle(msg):
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0]
        return {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "cli", "version": "1.0.0"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [TOOL]}
    if method == "tools/call":
        if params.get("name") != TOOL["name"]:
            raise ValueError(f"unknown tool: {params.get('name')}")
        text, is_error = run(params.get("arguments") or {})
        return {"content": [{"type": "text", "text": text}], "isError": is_error}
    raise LookupError(method)


def reply(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        if "id" not in msg:
            continue
        try:
            reply({"jsonrpc": "2.0", "id": msg["id"], "result": handle(msg)})
        except LookupError as e:
            reply({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"method not found: {e}"}})
        except ValueError as e:
            reply({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32602, "message": str(e)}})


if __name__ == "__main__":
    main()
