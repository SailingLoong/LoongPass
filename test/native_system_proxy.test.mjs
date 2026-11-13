import { expect, test } from 'bun:test';
import { systemProxyEnvironment } from '../runtime/system-proxy.mjs';

const mac = `<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 8080
  HTTPSEnable : 1
  HTTPSProxy : ::1
  HTTPSPort : 8081
  ExceptionsList : <array> {
    0 : *.local
    1 : 192.168.0.0/16
  }
}`;

test('a desktop launch supplies the system proxy and preserves local bypasses', () => {
  const env = systemProxyEnvironment({
    platform: 'darwin', environment: { NO_PROXY: 'private.example' }, read: () => mac,
  });
  expect(env.HTTPS_PROXY).toBe('http://[::1]:8081');
  expect(env.HTTP_PROXY).toBe('http://[::1]:8081');
  expect(env.NO_PROXY.split(',')).toEqual([
    'localhost', '127.0.0.1', '::1', 'private.example', '.local', '192.168.0.0/16',
  ]);
  expect(env.https_proxy).toBe(env.HTTPS_PROXY);
  expect(env.no_proxy).toBe(env.NO_PROXY);
});

test('an explicit launch proxy remains authoritative without probing the OS', () => {
  for (const key of ['HTTPS_PROXY', 'http_proxy', 'ALL_PROXY']) {
    let reads = 0;
    const env = systemProxyEnvironment({
      platform: 'darwin', environment: { [key]: 'http://chosen.example:9000' },
      read: () => { reads++; return mac; },
    });
    expect(env).toEqual({});
    expect(reads).toBe(0);
  }
});

test('disabled, malformed or unreadable settings never create a proxy', () => {
  for (const output of [
    '', mac.replaceAll('Enable : 1', 'Enable : 0'),
    'HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 99999',
    'SOCKSEnable : 1\nSOCKSProxy : 127.0.0.1\nSOCKSPort : 1080',
  ]) {
    expect(systemProxyEnvironment({ platform: 'darwin', environment: {}, read: () => output })).toEqual({});
  }
  expect(systemProxyEnvironment({ platform: 'win32', environment: {}, read: () => { throw new Error('denied'); } })).toEqual({});
});

test('Windows manual proxies respect enablement, protocol lists and bypasses', () => {
  const registry = `HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=localhost:8080;https=proxy.example:8081;socks=localhost:1080
    ProxyOverride    REG_SZ    <local>;*.internal;10.0.0.0/8`;
  const env = systemProxyEnvironment({ platform: 'win32', environment: {}, read: () => registry });
  expect(env.HTTPS_PROXY).toBe('http://proxy.example:8081');
  expect(env.NO_PROXY).toBe('localhost,127.0.0.1,::1,.internal,10.0.0.0/8');
  expect(systemProxyEnvironment({ platform: 'win32', environment: {}, read: () => registry.replace('0x1', '0x0') })).toEqual({});
  const single = registry.replace(/ProxyServer    REG_SZ    .*/, 'ProxyServer    REG_SZ    localhost:8082');
  expect(systemProxyEnvironment({ platform: 'win32', environment: {}, read: () => single }).HTTP_PROXY).toBe('http://localhost:8082');
});

test('HTTP-only settings are usable and other platforms leave the environment alone', () => {
  expect(systemProxyEnvironment({ platform: 'darwin', environment: {}, read: () => mac.replace('HTTPSEnable : 1', 'HTTPSEnable : 0') }).HTTPS_PROXY).toBe('http://127.0.0.1:8080');
  expect(systemProxyEnvironment({ platform: 'linux', environment: {}, read: () => { throw new Error('unsupported OS'); } })).toEqual({});
});
