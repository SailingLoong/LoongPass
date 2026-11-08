// One-time acquisition only: no refresh, credential persistence or model calls.
// The native host imports and owns the returned job grant.
import { protocol, _internal } from './vendor/plugins/qoder/index.mjs'

export async function prepareCredential(provider, auth) {
  if (provider !== 'qoder') return auth
  const chat = await protocol.exchangeDeviceGrant(_internal.SITES.qoder, {
    token: auth.deviceToken, refresh_token: auth.deviceRefresh,
  })
  const next = { ...auth, ...chat }
  delete next.deviceChat
  return next
}

if (import.meta.main) {
  try {
    const input = JSON.parse(await Bun.stdin.text())
    const auth = await prepareCredential(input.provider, input.auth)
    process.stdout.write(JSON.stringify({ ok: true, auth }))
  } catch (error) {
    process.stdout.write(JSON.stringify({ ok: false, rejected: [401, 403].includes(error?.status) }))
  }
}
