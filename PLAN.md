# Development scope

Keep one small Flutter/Dart application using Material 3. Account backups are local to the same machine. Do not add a service, another runtime, cross-machine migration, or new encryption.

Implemented and locally checked:
1. Same-machine seven-field snapshot/switch decisions in pure Dart.
2. Single synthetic account page, search/import/switch interactions, disabled unavailable actions.
3. Strict explicit-file read, byte-preserving backup, and snapshot re-import with temporary synthetic filesystem tests.
4. Generated macOS runner and a minimal system-picker-to-Dart-backup bridge; 8 bridge tests and 2 additional Widget tests passed. Six native tests are written but not run.

Next native integration must verify the actual installed client, identity, existing encryption, file ownership/ACLs and process state before connecting real-account actions. Reuse current upstream behavior only after checking it. Native credential replacement, real check-in, account persistence, Windows runner and distributable packaging remain unfinished. The macOS runner still requires actual Xcode compilation and sandbox testing. Do not label the synthetic preview as a working real-account release.
