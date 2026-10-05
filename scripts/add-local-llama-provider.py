"""Insert one provider into mutable JSON/JSONC without rewriting existing text."""
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|[{}\[\]:,]')


def parse(text):
    clean = TOKEN.sub(lambda m: " " * len(m[0]) if m[0].startswith(("//", "/*")) else m[0], text)
    tokens = list(TOKEN.finditer(clean))
    for i, token in enumerate(tokens[:-1]):
        following = tokens[i + 1]
        if token[0] == "," and following[0] in ("}", "]") and not clean[token.end():following.start()].strip():
            clean = clean[:token.start()] + " " + clean[token.end():]
    return json.loads(clean)


def add(path, key, fragment):
    if path.is_symlink():
        raise ValueError(f"refusing to replace managed symlink: {path}")
    text = path.read_text() if path.exists() else "{}\n"
    data = parse(text)
    providers = data.get(key, {})
    if not isinstance(providers, dict):
        raise ValueError(f"{key} must be an object")
    name, value = next(iter(fragment.items()))
    if name in providers:
        if providers[name] != value:
            raise ValueError(f"{name} already exists with different settings; left unchanged")
        return
    depth = 0
    insertion = None
    tokens = [m for m in TOKEN.finditer(text) if not m[0].startswith(("//", "/*"))]
    for i, token in enumerate(tokens):
        if depth == 1 and token[0].startswith('"') and json.loads(token[0]) == key:
            if tokens[i + 1][0] == ":" and tokens[i + 2][0] == "{":
                insertion = tokens[i + 2].end()
                break
        if token[0] in ("{", "["):
            depth += 1
        elif token[0] in ("}", "]"):
            depth -= 1
    entry = json.dumps(name) + ": " + json.dumps(value, indent=2)
    if key in data:
        if insertion is None:
            raise ValueError("cannot locate provider object")
        addition = "\n" + entry + ("," if providers else "") + "\n"
    else:
        insertion = tokens[0].end()
        addition = "\n" + json.dumps(key) + ": {" + entry + "}" + ("," if data else "") + "\n"
    result = text[:insertion] + addition + text[insertion:]
    expected = dict(data)
    expected[key] = {**providers, name: value}
    if parse(result) != expected:
        raise ValueError("provider insertion validation failed")
    path.parent.mkdir(parents=True, exist_ok=True)
    backup = path.with_name(path.name + ".before-local-llama")
    if path.exists() and not backup.exists():
        shutil.copy2(path, backup)
        backup.chmod(0o600)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(result)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    home = Path(sys.argv[1])
    fragments = json.loads(Path(sys.argv[2]).read_text())
    kilo = home / ".config/kilo/kilo.jsonc"
    if not kilo.exists():
        kilo = home / ".config/kilo/kilo.json"
    add(home / ".pi/agent/models.json", "providers", fragments["pi"])
    add(kilo, "provider", fragments["kilo"])
