"""Merge local providers and Pi compaction budgets into mutable client files."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\]:,]')


def parse(text):
    clean = TOKEN.sub(lambda m: " " * len(m[0]) if m[0].startswith(("//", "/*")) else m[0], text)
    tokens = list(TOKEN.finditer(clean))
    for i, token in enumerate(tokens[:-1]):
        following = tokens[i + 1]
        if token[0] == "," and following[0] in ("}", "]") and not clean[token.end():following.start()].strip():
            clean = clean[:token.start()] + " " + clean[token.end():]
    return json.loads(clean)


def update_parameters(text, key, name, current, desired):
    endpoint = ["baseUrl"] if key == "providers" else ["options", "baseURL"]
    model = ["models", 0] if key == "providers" else ["models", "local-qwen"]
    context = [*model, "contextWindow"] if key == "providers" else [*model, "limit", "context"]
    display_name = [*model, "name"]

    def parent_at(data, fields):
        for field in fields[:-1]:
            data = data[field]
        return data

    changes = []
    candidate = copy.deepcopy(current)
    try:
        for data in (current, desired):
            url = parent_at(data, endpoint)[endpoint[-1]]
            match = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})/v1", url)
            if not match or not 1 <= int(match[1]) <= 65535:
                raise ValueError("port updates require loopback endpoints")
            size = parent_at(data, context)[context[-1]]
            title = parent_at(data, display_name)[display_name[-1]]
            if type(size) is not int or size < 1024 or size % 1024:
                raise ValueError("context must be a positive multiple of 1024")
            if title != f"Local Qwen ({size // 1024}K; capabilities pending verification)":
                raise ValueError("custom model names are left unchanged")
        for fields in (endpoint, context, display_name):
            old = parent_at(candidate, fields)[fields[-1]]
            new = parent_at(desired, fields)[fields[-1]]
            parent_at(candidate, fields)[fields[-1]] = new
            if old != new:
                changes.append(([key, name, *fields], old, new))
    except (KeyError, IndexError, TypeError) as error:
        raise ValueError(f"{name} has unexpected settings; left unchanged") from error
    if candidate != desired:
        raise ValueError(f"{name} already exists with different settings; left unchanged")
    for fields, old, new in changes:
        text = replace_scalar(text, fields, old, new)
    return text


def replace_scalar(text, fields, old, new):
    # Find one exact object/array path. Preserve all other JSONC text, including
    # comments, auth, and identical names, numbers or URLs in other providers.
    tokens = [m for m in TOKEN.finditer(text) if not m[0].startswith(("//", "/*"))]
    start = 0
    for field in fields:
        container = "[" if isinstance(field, int) else "{"
        if tokens[start][0] != container:
            raise ValueError("cannot locate parameter container")
        depth, index = 1, 0
        for i in range(start + 1, len(tokens)):
            token = tokens[i][0]
            if depth == 1:
                if container == "[" and token not in (",", "]") and index == field:
                    start = i
                    break
                if container == "{" and token.startswith('"') and json.loads(token) == field and tokens[i + 1][0] == ":":
                    start = i + 2
                    break
                if token == ",":
                    index += 1
            if token in ("{", "["):
                depth += 1
            elif token in ("}", "]"):
                depth -= 1
                if depth == 0:
                    raise ValueError("cannot locate parameter field")
        else:
            raise ValueError("cannot locate parameter field")
    target = tokens[start]
    if json.loads(target[0]) != old:
        raise ValueError("parameter token does not match parsed value")
    return text[:target.start()] + json.dumps(new) + text[target.end():]


def insert_provider(text, data, key, providers, name, value):
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
    return text[:insertion] + addition + text[insertion:]


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
        if providers[name] == value:
            return
        result = update_parameters(text, key, name, providers[name], value)
    else:
        result = insert_provider(text, data, key, providers, name, value)
    expected = dict(data)
    expected[key] = {**providers, name: value}
    if parse(result) != expected:
        raise ValueError("provider insertion validation failed")
    write_with_backup(path, result)


def write_with_backup(path, result):
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


def add_compaction(path, fragment):
    if path.is_symlink():
        raise ValueError(f"refusing to replace managed symlink: {path}")
    # Pi settings are ordinary JSON, unlike Kilo's JSONC. Preserve every other
    # value, including global budgets, other model overrides and UI settings.
    data = json.loads(path.read_text()) if path.exists() else {}
    original = copy.deepcopy(data)
    parent = data
    for key in ("compaction", "modelOverrides"):
        if not isinstance(parent, dict):
            raise ValueError("Pi compaction settings must be objects")
        parent = parent.setdefault(key, {})
    if not isinstance(parent, dict):
        raise ValueError("Pi compaction modelOverrides must be an object")
    for model, budgets in fragment.items():
        current = parent.setdefault(model, {})
        if not isinstance(current, dict):
            raise ValueError(f"Pi compaction override for {model} must be an object")
        current.update(budgets)
    if data != original:
        write_with_backup(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    home = Path(sys.argv[1])
    fragments = json.loads(Path(sys.argv[2]).read_text())
    kilo = home / ".config/kilo/kilo.jsonc"
    if not kilo.exists():
        kilo = home / ".config/kilo/kilo.json"
    add(home / ".pi/agent/models.json", "providers", fragments["pi"])
    add(kilo, "provider", fragments["kilo"])
    add_compaction(home / ".pi/agent/settings.json", fragments["piCompaction"])
