// LoongPass owns the process lease; the pinned Magpie host owns credentials.
// SQLite's OS lock survives parent loss and is released when this host exits.
import { Database } from 'bun:sqlite';
import { chmodSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

process.umask(0o077);
let lease;
try {
  lease = new Database('host-lease.sqlite', { create: true, strict: true });
  if (process.platform !== 'win32') chmodSync('host-lease.sqlite', 0o600);
  lease.exec('PRAGMA busy_timeout = 0; PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;');
} catch {
  // Do not print paths or plugin account data to stderr.
  process.exit(73);
}
process.on('exit', () => lease.close());
await import(pathToFileURL(process.argv[2]).href);
