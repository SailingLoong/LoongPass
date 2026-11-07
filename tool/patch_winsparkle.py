"""Minimal WinSparkle extension: automatic installation with upstream skip policy.

Only the exact pinned source or this script's exact patched result is accepted.
The update checker retains OneShotUpdateChecker's feed, download and skip logic.
"""
import argparse
import hashlib
from pathlib import Path

UPSTREAM_COMMIT = "a8986caf620262f7d4581b241436ceaa0cc9370f"

PATCHES = {
    "src/updatechecker.h": (
        "aa8e44f8cff9ba4d23310b8828992f8b861cb992eff3f6abe9ea02a4be79f1af",
        "\n\n} // namespace winsparkle",
        """
// LoongPass extension: retain the automatic checker's SkipThisVersion policy.
class AutomaticInstallUpdateChecker : public OneShotUpdateChecker
{
protected:
    bool ShouldAutomaticallyInstall() const override { return true; }
};
""",
    ),
    "src/dll_api.cpp": (
        "e06b4a56d5058b751b05328a52dabed6d86db6f53ab42d8d1d04cda37f7f1ac5",
        "WIN_SPARKLE_API void __cdecl win_sparkle_set_user_run_installer_callback",
        """// LoongPass extension: background check with upstream automatic skip policy.
WIN_SPARKLE_API void __cdecl win_sparkle_check_update_without_ui_and_install()
{
    try
    {
        UpdateChecker *check = new AutomaticInstallUpdateChecker();
        check->Start();
    }
    CATCH_ALL_EXCEPTIONS
}

""",
    ),
    "include/winsparkle.h": (
        "f1d7f33d0ebd88b83414c1f4901632d485ab776a859bf5f5dc74d809acb08976",
        "WIN_SPARKLE_API void __cdecl win_sparkle_check_update_without_ui();",
        """/**
    LoongPass extension: check in the background and install available updates.
    Respects the user's SkipThisVersion choice. No checking UI is displayed;
    upstream download, signature verification and installation UI are retained.
*/
WIN_SPARKLE_API void __cdecl win_sparkle_check_update_without_ui_and_install();

""",
    ),
}


def patch_tree(root):
    prepared = {}
    states = set()
    for name, (digest, anchor, addition) in PATCHES.items():
        path = root / name
        content = path.read_bytes()
        extra = addition.encode()
        original = content
        patched = content.count(extra) == 1
        if patched:
            original = content.replace(extra, b"", 1)
        if hashlib.sha256(original).hexdigest() != digest:
            raise ValueError(f"Pinned WinSparkle source drift: {name}")
        marker = anchor.encode()
        if original.count(marker) != 1:
            raise ValueError(f"Ambiguous patch context: {name}")
        result = original.replace(marker, extra + marker, 1)
        if patched and result != content:
            raise ValueError(f"Unexpected patch location: {name}")
        prepared[path] = result
        states.add(patched)
    if len(states) != 1:
        raise ValueError("Partially patched WinSparkle tree; use a fresh pinned checkout")
    if True in states:
        return False
    # Validate the entire patch before changing any source file.
    for path, result in prepared.items():
        path.write_bytes(result)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--upstream-commit", action="store_true")
    args = parser.parse_args()
    if args.upstream_commit:
        print(UPSTREAM_COMMIT)
        return
    if args.source is None:
        parser.error("source directory is required")
    changed = patch_tree(args.source)
    print("Applied WinSparkle automatic-install extension" if changed else "WinSparkle extension already applied")


if __name__ == "__main__":
    main()
