"""Manual, loopback-only llama.cpp launcher; weights and cache stay outside Nix."""
import argparse
import os
from pathlib import Path
import socket
import sys

server = sys.argv.pop(1)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model", nargs="?", help="GGUF path (or LLAMA_MODEL)")
parser.add_argument("--port", type=int, default=8080)
parser.add_argument("--diagnostics", action="store_true", help="Show backend/offload trace on the terminal; no log file")
parser.add_argument("--hf-repo", help="Explicitly download/use this Hugging Face GGUF repository")
parser.add_argument("--hf-file", help="Exact GGUF filename; required with --hf-repo")
args = parser.parse_args()
model = args.model or os.environ.get("LLAMA_MODEL")
if args.hf_repo:
    if model or not args.hf_file:
        parser.error("--hf-repo requires --hf-file and cannot be combined with a local model")
    model_args = ["--hf-repo", args.hf_repo, "--hf-file", args.hf_file]
else:
    if args.hf_file or not model:
        parser.error("specify a GGUF path or LLAMA_MODEL (or both --hf-repo and --hf-file)")
    path = Path(model).expanduser().resolve()
    if not path.is_file() or path.suffix.lower() != ".gguf":
        parser.error("model must be an existing GGUF file")
    if path.is_relative_to("/nix/store"):
        parser.error("model weights must live outside /nix/store")
    model_args = ["--model", str(path), "--offline"]
if not 1 <= args.port <= 65535:
    parser.error("port must be between 1 and 65535")
try:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", args.port))
except OSError:
    parser.error(f"127.0.0.1:{args.port} is unavailable; no process was stopped")

# Ignore inherited server options (including file/prompt logging, tools, host,
# router and cache types). Explicit CLI flags below define this launch contract.
env = {k: v for k, v in os.environ.items() if not k.startswith("LLAMA_ARG_")}
cache = Path(env.get("LLAMA_CACHE", str(Path(env.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "llama.cpp"))).expanduser().resolve()
if cache.is_relative_to("/nix/store"):
    parser.error("LLAMA_CACHE must be outside /nix/store")
env["LLAMA_CACHE"] = str(cache)
os.execve(server, [server, *model_args,
    "--alias", "local-qwen", "--host", "127.0.0.1", "--port", str(args.port),
    "--gpu-layers", "all", "--ctx-size", "16384", "--parallel", "1",
    "--jinja", "--flash-attn", "auto", "--log-verbosity", "4" if args.diagnostics else "3", "--no-agent",
], env)
