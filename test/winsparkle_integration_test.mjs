// Run the real Windows DLL against loopback synthetic feeds and ephemeral keys.
import assert from 'node:assert/strict';
import {generateKeyPairSync, randomUUID, sign} from 'node:crypto';
const executable = process.argv[2];
assert(executable && process.platform === 'win32');
const {publicKey, privateKey} = generateKeyPairSync('ed25519');
const key = Buffer.from(publicKey.export({format: 'jwk'}).x, 'base64url').toString('base64');
const payload = Buffer.from('LoongPass synthetic signed update fixture\n'.repeat(8192));
const signature = sign(null, payload, privateKey).toString('base64');
const counts = new Map();
const children = new Set();
const server = Bun.serve({hostname: '127.0.0.1', port: 0, fetch(request) {
  const url = new URL(request.url);
  const mode = url.searchParams.get('mode');
  counts.set(`${mode}:${url.pathname}`, (counts.get(`${mode}:${url.pathname}`) ?? 0) + 1);
  if (url.pathname === '/update.exe') {
    const body = mode === 'bad-signature' ? Buffer.concat([payload, Buffer.from('invalid')]) : payload;
    return new Response(body, {headers: {'Content-Type': 'application/octet-stream', 'Content-Length': String(body.length)}});
  }
  assert.equal(url.pathname, '/appcast.xml');
  const version = mode === 'no-update' ? '1' : '2';
  return new Response(`<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>Fixture</title><sparkle:version>${version}</sparkle:version><sparkle:shortVersionString>1.0.${version}</sparkle:shortVersionString><enclosure url="${url.origin}/update.exe?mode=${mode}" sparkle:os="windows" sparkle:edSignature="${signature}" length="${payload.length}" type="application/octet-stream" /></item></channel></rss>`, {headers: {'Content-Type': 'application/xml'}});
}});
try {
  for (const mode of ['ready', 'bad-signature', 'tampered', 'skip', 'no-update']) {
    const child = Bun.spawn([executable, mode, `http://127.0.0.1:${server.port}/appcast.xml?mode=${mode}`, key, randomUUID()], {stdout: 'inherit', stderr: 'inherit'});
    children.add(child);
    const timer = setTimeout(() => child.kill(), 90000);
    try { assert.equal(await child.exited, 0, `Native integration: ${mode}`); }
    finally { clearTimeout(timer); children.delete(child); }
    assert.equal(counts.get(`${mode}:/appcast.xml`), mode === 'skip' ? 3 : 1, `feed requests: ${mode}`);
    assert.equal(counts.get(`${mode}:/update.exe`) ?? 0, mode === 'no-update' ? 0 : mode === 'skip' ? 2 : 1, `payload requests: ${mode}`);
  }
  console.log('WinSparkle signed staging, prepared install, skip, invalid signatures, staged tampering and no-popup checks passed');
} finally {
  for (const child of children) { child.kill(); await child.exited; }
  await server.stop(true);
}
