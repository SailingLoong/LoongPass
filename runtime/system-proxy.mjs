import { execFileSync } from 'node:child_process';
import { win32 } from 'node:path';

// Startup integration for the pinned host's native *_PROXY support. Semantics
// follow Magpie internal/netproxy (MIT; runtime/vendor/magpie/LICENSE): explicit
// environment wins, then the OS manual HTTPS/HTTP proxy, with loopback bypassed.
// PAC evaluation and SOCKS-to-HTTP bridging are not provided here.
export function systemProxyEnvironment({
  platform = process.platform, environment = process.env, read = execFileSync,
} = {}) {
  if (Object.entries(environment).some(([key, value]) =>
    /^(https?|all)_proxy$/i.test(key) && String(value).trim())) return {};

  let proxy;
  let bypass = [];
  const options = { encoding: 'utf8', timeout: 10_000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] };
  try {
    if (platform === 'darwin') {
      const output = read('/usr/sbin/scutil', ['--proxy'], options);
      const values = {};
      let inList = false;
      for (const raw of output.split('\n')) {
        const line = raw.trim();
        if (line === '}') { inList = false; continue; }
        const at = line.indexOf(' : ');
        if (at < 0) continue;
        const key = line.slice(0, at), value = line.slice(at + 3);
        if (inList) bypass.push(value);
        else if (key === 'ExceptionsList') inList = true;
        else values[key] = value;
      }
      for (const kind of ['HTTPS', 'HTTP']) {
        if (values[`${kind}Enable`] !== '1') continue;
        let host = values[`${kind}Proxy`];
        if (!host) continue;
        if (host.includes(':') && !host.startsWith('[')) host = `[${host}]`;
        const port = values[`${kind}Port`];
        proxy = httpProxy(`http://${host}${port ? `:${port}` : ''}`);
        if (proxy) break;
      }
    } else if (platform === 'win32') {
      const output = read(win32.join(environment.SystemRoot || 'C:\\Windows', 'System32', 'reg.exe'), [
        'query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings',
      ], options);
      const values = Object.fromEntries([...output.matchAll(/^\s*(ProxyEnable|ProxyServer|ProxyOverride)\s+REG_\w+\s+(.+)$/gm)]
        .map((match) => [match[1], match[2].trim()]));
      if (Number(values.ProxyEnable) !== 1) return {};
      const server = values.ProxyServer || '';
      if (server.includes('=')) {
        const protocols = Object.fromEntries(server.split(';').map((part) => {
          const at = part.indexOf('=');
          return [part.slice(0, at).trim().toLowerCase(), part.slice(at + 1).trim()];
        }));
        proxy = httpProxy(protocols.https) || httpProxy(protocols.http);
      } else proxy = httpProxy(server);
      bypass = (values.ProxyOverride || '').split(';');
    }
  } catch {
    // An unavailable OS setting must not prevent the credential owner starting.
    return {};
  }
  if (!proxy) return {};
  const no = new Set(['localhost', '127.0.0.1', '::1']);
  for (const value of [environment.NO_PROXY || '', environment.no_proxy || '', ...bypass]) {
    for (const entry of value.split(',')) {
      const host = entry.trim().replace(/^\*/, '');
      if (host && host !== '<local>') no.add(host);
    }
  }
  const result = {};
  for (const name of ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY']) {
    result[name] = result[name.toLowerCase()] = name === 'NO_PROXY' ? [...no].join(',') : proxy;
  }
  return result;
}

function httpProxy(value) {
  if (!value) return undefined;
  try {
    const url = new URL(value.includes('://') ? value : `http://${value}`);
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname ||
        url.pathname !== '/' || url.search || url.hash) return undefined;
    return url.href.replace(/\/$/, '');
  } catch { return undefined; }
}
