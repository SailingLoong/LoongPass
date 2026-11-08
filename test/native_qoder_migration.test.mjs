import { test, expect } from 'bun:test'
import { protocol, _internal } from '../runtime/vendor/plugins/qoder/index.mjs'

test('global device grant exchanges to a job grant with millisecond expiry', async () => {
  const original = globalThis.fetch
  const now = Date.now()
  const calls = []
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init })
    expect(String(url)).toEndWith('/api/v1/me/jobToken')
    return Response.json({ token: 'job-token', refresh_token: 'job-refresh', expires_in: 60000 })
  }
  try {
    const grant = await protocol.exchangeDeviceGrant(_internal.SITES.qoder,
      { token: 'device-token', refresh_token: 'device-refresh', expires_in: 3600 })
    expect(grant.access).toBe('job-token')
    expect(grant.refresh).toBe('job-refresh')
    expect(grant.deviceChat).toBeUndefined()
    expect(grant.expires).toBeGreaterThanOrEqual(now + 60000)
    expect(grant.expires).toBeLessThan(Date.now() + 61000)
    expect(calls).toHaveLength(1)
  } finally { globalThis.fetch = original }
})

test('only the declared CN site may fall back to device-chat', async () => {
  const original = globalThis.fetch
  globalThis.fetch = async () => new Response('denied', { status: 403 })
  try {
    await expect(protocol.exchangeDeviceGrant(_internal.SITES.qoder,
      { token: 'device-token' })).rejects.toThrow()
    const cn = await protocol.exchangeDeviceGrant(_internal.SITES['qoder-cn'],
      { token: 'device-token', refresh_token: 'device-refresh', expires_in: 60 })
    expect(cn.access).toBe('device-token')
    expect(cn.refresh).toBe('device-refresh')
    expect(cn.deviceChat).toBe(true)
  } finally { globalThis.fetch = original }
})
