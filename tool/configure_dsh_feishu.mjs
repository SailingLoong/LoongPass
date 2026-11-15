/** Update this integration's profile rows under DSH's native writer lock. */
import { lstat, readFile, realpath, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { isDeepStrictEqual } from 'node:util';
import { withFileLock, writeFileAtomic } from '../integrations/dsh-feishu/atomic-write/index.ts';

const BEGIN = '- id: agent-team # LoongPass DSH Feishu BEGIN';
const END = '  # LoongPass DSH Feishu END';
const LIST_KEYS = ['senderAllowlist', 'approvers', 'groupAllowlist'];
const TOKENS = /#[^\r\n]*|"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[{}\[\],:]|[^\s{}\[\],:#]+/g;

class ConfigurationError extends Error {}

function scalar(token) {
  if (token.startsWith('"')) return JSON.parse(token);
  if (token.startsWith("'")) return token.slice(1, -1).replaceAll("''", "'");
  return token;
}

/** Inspect row metadata, leaving unrelated plugin config and its custom tags intact. */
function checkEntries(entries, indent = 0) {
  let index = 0;
  while (index < entries.length) {
    const [level, text] = entries[index];
    if (level !== indent || !text.startsWith('- ')) {
      throw new ConfigurationError('Use native block-style YAML patch rows with indented fields');
    }
    let end = index + 1;
    while (end < entries.length && entries[end][0] > indent) end++;
    const fields = [[indent + 2, text.slice(2)], ...entries.slice(index + 1, end)];
    let field = 0;
    while (field < fields.length) {
      const [level, text] = fields[field];
      if (level !== indent + 2) {
        throw new ConfigurationError('Use native block-style YAML patch rows with indented fields');
      }
      let following = field + 1;
      while (following < fields.length && fields[following][0] > level) following++;
      const nested = fields.slice(field + 1, following);
      const tokens = (text.match(TOKENS) ?? []).filter(token => !token.startsWith('#'));
      if (tokens.length < 2 || tokens[1] !== ':') {
        throw new ConfigurationError('Flow-style, dynamic or aliased patch rows need manual configuration');
      }
      const key = scalar(tokens[0]);
      const values = tokens.slice(2);
      if (key === '<<') throw new ConfigurationError('Merged YAML patch entries need manual configuration');
      if (key === 'id') {
        if (nested.length || values.length !== 1 || /^[!*&|>{\[]/.test(values[0])) {
          throw new ConfigurationError('Patch entry IDs must be static strings');
        }
        if (['agent-team', 'lark-channel'].includes(scalar(values[0]))) {
          throw new ConfigurationError('Existing agent-team or lark-channel configuration is outside this tool\'s block');
        }
      }
      if (key === 'insert') {
        if (values.length && !isDeepStrictEqual(values, ['[', ']'])) {
          throw new ConfigurationError('Use native block-style insert lists');
        }
        if (nested.length) checkEntries(nested, nested[0][0]);
      }
      field = following;
    }
    index = end;
  }
}

function checkUnmanaged(text) {
  const lines = text.split(/\r?\n/).filter(line => line.trim() && !line.trimStart().startsWith('#'));
  if (lines[0] === '---') lines.shift();
  if (lines.length === 1 && /^\[\]\s*(?:#.*)?$/.test(lines[0])) return true;
  checkEntries(lines.map(line => [line.length - line.trimStart().length, line.trimStart()]));
  return false;
}

function ownedBlock(text) {
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  const starts = [], ends = [];
  lines.forEach((line, index) => {
    const content = line.replace(/\r?\n$/, '');
    if (content === BEGIN) starts.push(index);
    if (content === END) ends.push(index);
  });
  if (!starts.length && !ends.length) return { before: text, after: '', rows: undefined };
  if (starts.length !== 1 || ends.length !== 1 || ends[0] <= starts[0]) {
    throw new ConfigurationError('The managed configuration markers have been changed or duplicated');
  }
  const start = starts[0], end = ends[0];
  const following = lines.slice(end + 1).find(line => line.trim() && !line.trimStart().startsWith('#'));
  if (following && /^\s/.test(following)) {
    throw new ConfigurationError('The managed configuration block has custom row content');
  }
  const block = lines.slice(start, end + 1).join('');
  if ((block.match(TOKENS) ?? []).some(token => token.startsWith('!'))) {
    throw new ConfigurationError('Tagged values in the managed block need native configuration');
  }
  let rows;
  try { rows = Bun.YAML.parse(block); }
  catch { throw new ConfigurationError('The managed configuration block must contain valid YAML'); }
  if (!Array.isArray(rows) || rows.length !== 2 || rows[0]?.id !== 'agent-team' || rows[1]?.id !== 'lark-channel'
    || rows.some(row => Object.keys(row).some(key => !['id', 'config'].includes(key))
      || !row.config || typeof row.config !== 'object' || Array.isArray(row.config))) {
    throw new ConfigurationError('The managed block must contain its Teams and Feishu config rows');
  }
  return { before: lines.slice(0, start).join(''), after: lines.slice(end + 1).join(''), rows };
}

async function directory(value) {
  if (typeof value !== 'string') throw new ConfigurationError('Workspace paths must identify existing directories');
  const path = await realpath(resolve(value.replace(/^~(?=$|[/\\])/, homedir())));
  if (!(await stat(path)).isDirectory()) throw new ConfigurationError('Workspace paths must identify existing directories');
  return path;
}

function identifier(value, prefix) {
  if (typeof value !== 'string' || !new RegExp('^' + prefix + '[A-Za-z0-9_]+$').test(value)) {
    throw new ConfigurationError('Use exact Feishu IDs with the expected cli_, ou_, or oc_ prefix');
  }
  return value;
}

async function renderPatch(text, options) {
  const { before, after, rows } = ownedBlock(text);
  const empty = checkUnmanaged(before + after);
  const separator = typeof options.model === 'string' ? options.model.indexOf('/') : -1;
  if (separator <= 0 || !options.model.slice(0, separator).trim() || !options.model.slice(separator + 1).trim()
    || /[\x00-\x1f\x7f]/.test(options.model)) {
    throw new ConfigurationError('Specify a model as PROVIDER/MODEL');
  }
  const previous = rows?.[1].config ?? {};
  const workspace = await directory(options.workspace);
  const roots = options.workspaceRoots ?? previous.workspaceRoots ?? [workspace];
  if (!Array.isArray(roots)) throw new ConfigurationError('workspaceRoots must be a list of directories');
  const config = { ...previous, cwd: workspace, workspaceRoots: await Promise.all(roots.map(directory)),
    provider: options.model.slice(0, separator), model: options.model.slice(separator + 1) };
  const appId = options.appId ?? previous.appId;
  if (appId !== undefined) config.appId = identifier(appId, 'cli_');
  for (const key of LIST_KEYS) {
    const values = options[key] ?? previous[key] ?? [];
    if (!Array.isArray(values)) throw new ConfigurationError('Feishu access lists must contain exact IDs');
    config[key] = values.map(value => identifier(value, key === 'groupAllowlist' ? 'oc_' : 'ou_'));
  }
  const team = { ...(rows?.[0].config ?? {}), defaultEnabled: true };
  if (rows && isDeepStrictEqual(rows[0].config, team) && isDeepStrictEqual(previous, config)) return text;
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  const block = [BEGIN, '  config: ' + JSON.stringify(team), '- id: lark-channel',
    '  config: ' + JSON.stringify(config), END, ''].join(newline);
  if (empty) return before.replace(/^\[\](?=\s*(?:#.*)?$)/m, () => block);
  return before + (before && !/[\r\n]$/.test(before) ? newline : '') + block + after;
}

async function configure(options) {
  const profile = options.profileDirectory;
  const packagePath = join(profile, 'package.json'), patchPath = join(profile, 'cordis.patch.yml');
  return withFileLock(packagePath, async () => {
    for (const path of [profile, packagePath, patchPath]) {
      if ((await lstat(path)).isSymbolicLink()) throw new ConfigurationError('Use an existing native profile without symlinked files');
    }
    const metadata = JSON.parse(await readFile(packagePath, 'utf8'));
    const bundles = metadata?.dsh?.profile?.bundles;
    if (!Array.isArray(bundles) || bundles.some(bundle => typeof bundle !== 'string')) {
      throw new ConfigurationError('Profile metadata must come from dsh plugin initialization');
    }
    const original = await readFile(patchPath, 'utf8');
    const updated = await renderPatch(original, options);
    if (updated === original) return false;
    const state = await lstat(patchPath);
    if (state.isSymbolicLink() || await readFile(patchPath, 'utf8') !== original) {
      throw new ConfigurationError('The profile patch changed during configuration. Retry using its current content');
    }
    await writeFileAtomic(patchPath, updated, { mode: state.mode & 0o777 });
    return true;
  });
}

try {
  if (!Bun.YAML?.parse) throw new ConfigurationError('Use a Bun runtime with YAML support');
  const options = JSON.parse(await Bun.stdin.text());
  console.log(JSON.stringify({ changed: await configure(options) }));
} catch (error) {
  const contention = error?.message?.startsWith('atomic-write: timed out waiting for the writer lock');
  console.log(JSON.stringify({ error: error instanceof ConfigurationError ? error.message
    : contention ? 'Another native profile configuration is active. Retry after it completes'
      : 'Check native profile files, workspace directories, and write permissions' }));
  process.exitCode = 1;
}
