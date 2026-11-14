#!/usr/bin/env python3
"""Prepare an initialized DSH profile for its native Teams and Feishu plugins."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import stat
import tempfile


BEGIN = "- id: agent-team # LoongPass DSH Feishu BEGIN"
END = "  # LoongPass DSH Feishu END"
LIST_OPTIONS = {
    "sender_allowlist": "senderAllowlist",
    "approvers": "approvers",
    "group_allowlist": "groupAllowlist",
}
CONFIG_KEYS = {"cwd", "workspaceRoots", "provider", "model", "appId", *LIST_OPTIONS.values()}
YAML_TOKENS = re.compile(r'''\#[^\r\n]*|"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[{}\[\],:]|[^\s{}\[\],:\#]+''')


def directory(value):
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise ValueError("Workspace paths must identify existing directories")
    return str(path)


def identifier(value, prefix):
    if not re.fullmatch(prefix + r"[A-Za-z0-9_]+", value):
        raise ValueError("Use exact Feishu IDs with the expected cli_, ou_, or oc_ prefix")
    return value


def profile_patch(name):
    if not name or name in {".", ".."} or re.search(r"[/\\\x00-\x1f\x7f]", name):
        raise ValueError("Use a single DSH profile name")
    home = Path(os.environ.get("DSH_HOME") or Path.home() / ".dsh").expanduser()
    profile = home / "profiles" / name
    package = profile / "package.json"
    patch = profile / "cordis.patch.yml"
    if profile.is_symlink() or any(path.is_symlink() or not path.is_file() for path in (package, patch)):
        raise ValueError("Use an existing profile initialized by dsh plugin")
    try:
        metadata = json.loads(package.read_bytes())
        bundles = metadata["dsh"]["profile"]["bundles"]
        if not isinstance(bundles, list) or not all(isinstance(bundle, str) for bundle in bundles):
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise ValueError("Profile metadata must come from dsh plugin initialization") from None
    return patch


def scalar(token):
    if token.startswith('"'):
        try:
            return json.loads(token)
        except ValueError:
            raise ValueError("Unsupported YAML scalar in a patch entry ID") from None
    if token.startswith("'"):
        return token[1:-1].replace("''", "'")
    return token


def check_entries(entries, indent=0):
    """Check native block rows and insert lists, ignoring each config subtree."""
    index = 0
    while index < len(entries):
        level, text = entries[index]
        if level != indent or not text.startswith("- "):
            raise ValueError("Use native block-style YAML patch rows with indented fields")
        end = index + 1
        while end < len(entries) and entries[end][0] > indent:
            end += 1
        fields = [(indent + 2, text[2:]), *entries[index + 1:end]]
        field = 0
        while field < len(fields):
            level, text = fields[field]
            if level != indent + 2:
                raise ValueError("Use native block-style YAML patch rows with indented fields")
            following = field + 1
            while following < len(fields) and fields[following][0] > level:
                following += 1
            nested = fields[field + 1:following]
            tokens = [match.group() for match in YAML_TOKENS.finditer(text)
                      if not match.group().startswith("#")]
            if len(tokens) < 2 or tokens[1] != ":":
                raise ValueError("Flow-style, dynamic or aliased patch rows need manual configuration")
            key = scalar(tokens[0])
            values = tokens[2:]
            if key == "<<":
                raise ValueError("Merged YAML patch entries need manual configuration")
            if key == "id":
                if nested or len(values) != 1 or values[0].startswith(("!", "*", "&", "|", ">", "{", "[")):
                    raise ValueError("Patch entry IDs must be static strings")
                if scalar(values[0]) in {"agent-team", "lark-channel"}:
                    raise ValueError("Existing agent-team or lark-channel configuration is outside this tool's block")
            if key == "insert":
                if values and values != ["[", "]"]:
                    raise ValueError("Use native block-style insert lists")
                if nested:
                    check_entries(nested, nested[0][0])
            field = following
        index = end


def check_unmanaged(text):
    content = [line for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if content and content[0] == "---":
        content.pop(0)
    if len(content) == 1 and re.fullmatch(r"\[\]\s*(?:#.*)?", content[0]):
        return True
    check_entries([(len(line) - len(line.lstrip(" ")), line.lstrip(" ")) for line in content])
    return False


def owned_block(text):
    lines = text.splitlines(keepends=True)
    starts = [index for index, line in enumerate(lines) if line.rstrip("\r\n") == BEGIN]
    ends = [index for index, line in enumerate(lines) if line.rstrip("\r\n") == END]
    if not starts and not ends:
        return text, "", {}
    if len(starts) != 1 or len(ends) != 1 or ends[0] - starts[0] != 4:
        raise ValueError("The managed configuration block has been changed or duplicated")
    start, end = starts[0], ends[0]
    following = next((line for line in lines[end + 1:] if line.strip() and not line.lstrip().startswith("#")), "")
    if following and following[0].isspace():
        raise ValueError("The managed configuration block has custom content")
    block = [line.rstrip("\r\n") for line in lines[start:end + 1]]
    if block[2] != "- id: lark-channel" or any(not block[index].startswith("  config: {") for index in (1, 3)):
        raise ValueError("The managed configuration block has custom content")
    try:
        team = json.loads(block[1].removeprefix("  config: "))
        config = json.loads(block[3].removeprefix("  config: "))
        if team != {"defaultEnabled": True} or not isinstance(config, dict) or set(config) - CONFIG_KEYS:
            raise ValueError()
    except ValueError:
        raise ValueError("The managed configuration block has custom content") from None
    return "".join(lines[:start]), "".join(lines[end + 1:]), config


def render_patch(text, arguments):
    before, after, previous = owned_block(text)
    empty = check_unmanaged(before + after)
    provider, separator, model = arguments.model.partition("/")
    if not separator or not provider.strip() or not model.strip() or re.search(r"[\x00-\x1f\x7f]", arguments.model):
        raise ValueError("Specify a model as PROVIDER/MODEL")
    workspace = directory(arguments.workspace)
    roots = arguments.workspace_roots
    if roots is None:
        roots = previous.get("workspaceRoots", [workspace])
    config = {"cwd": workspace, "workspaceRoots": [directory(root) for root in roots],
              "provider": provider, "model": model}
    app_id = arguments.app_id if arguments.app_id is not None else previous.get("appId")
    if app_id is not None:
        config["appId"] = identifier(app_id, "cli_")
    for option, key in LIST_OPTIONS.items():
        values = getattr(arguments, option)
        if values is None:
            values = previous.get(key, [])
        if not isinstance(values, list):
            raise ValueError("The managed configuration block has custom content")
        config[key] = [identifier(value, "oc_" if key == "groupAllowlist" else "ou_") for value in values]
    newline = "\r\n" if "\r\n" in text else "\n"
    block = newline.join([BEGIN, '  config: {"defaultEnabled": true}', "- id: lark-channel",
                          "  config: " + json.dumps(config, ensure_ascii=True), END]) + newline
    if empty:
        return re.sub(r"(?m)^\[\](?=\s*(?:#.*)?$)", lambda _: block, before, count=1)
    if before and not before.endswith(("\n", "\r")):
        before += newline
    return before + block + after


@contextmanager
def profile_lock(patch):
    lock = patch.parent / ".loongpass-feishu-config.lock"
    # Keep the inode stable. Closing the descriptor, including on process exit,
    # releases the OS lock without leaving a stale ownership marker.
    with lock.open("a+b") as handle:
        try:
            if os.name == "nt":
                import msvcrt
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise ValueError("Another profile configuration is active") from None
        yield


def configure(arguments):
    patch = profile_patch(arguments.profile)
    with profile_lock(patch):
        original = patch.read_bytes()
        updated = render_patch(original.decode("utf-8"), arguments).encode("utf-8")
        if updated == original:
            return False
        mode = stat.S_IMODE(patch.stat().st_mode)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=patch.parent, prefix=".loongpass-feishu-", delete=False) as output:
                temporary = Path(output.name)
                os.chmod(temporary, mode)
                output.write(updated)
                output.flush()
                os.fsync(output.fileno())
            if patch.is_symlink() or patch.read_bytes() != original:
                raise ValueError("The profile patch changed during configuration. Retry using its current content")
            os.replace(temporary, patch)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--profile", required=True, help="Existing dedicated DSH profile name")
    parser.add_argument("--workspace", required=True, help="Existing default working directory")
    parser.add_argument("--model", required=True, help="Explicit PROVIDER/MODEL")
    parser.add_argument("--workspace-roots", nargs="*", help="Allowed existing directories for /cd")
    parser.add_argument("--app-id", help="Feishu cli_ application ID")
    for option in LIST_OPTIONS:
        parser.add_argument("--" + option.replace("_", "-"), nargs="*",
                            help="Exact IDs. Omit to preserve existing values, pass no IDs to clear")
    arguments, unknown = parser.parse_known_args()
    if unknown:
        parser.error("Unsupported arguments")
    try:
        changed = configure(arguments)
    except ValueError as error:
        parser.exit(1, f"Profile configuration failed. {error}\n")
    except (OSError, TypeError):
        parser.exit(1, "Profile configuration failed. Check profile files and directory access\n")
    print("Profile configuration updated" if changed else "Profile configuration already matches")


if __name__ == "__main__":
    main()
