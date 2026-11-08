const ID = 'loongpass'
const DEFAULT_ENDPOINT = 'http://127.0.0.1:3426'
const MODEL_HEADER = 'x-loongpass-model'
const NPM_HEADER = 'x-loongpass-npm'
const SESSION_HEADER = 'x-loongpass-session'
// The pinned Magpie host's sdkHeaders uses these three authentication headers.
const SDK_AUTH_HEADERS = ['authorization', 'x-api-key', 'x-goog-api-key']
const MODALITIES = ['text', 'image', 'audio', 'video', 'pdf']

function endpointOf(value) {
  const error = () => new Error('LoongPass endpoint must be an HTTP loopback origin (127.0.0.1 or [::1]) with no path, query or credentials')
  if (value != null && typeof value !== 'string') throw error()
  const text = value?.trim() || DEFAULT_ENDPOINT
  // Check the literal host before URL normalization can turn numeric aliases,
  // userinfo or backslashes into an apparently valid loopback address.
  if (!/^http:\/\/(?:127\.0\.0\.1|\[::1\])(?::\d+)?\/?$/.test(text)) throw error()
  try { return new URL(text).origin } catch { throw error() }
}

function credentials(auth) {
  if (auth?.type !== 'api' || typeof auth.key !== 'string' || !auth.key.trim()) throw new Error('A LoongPass account grant is required')
  return { endpoint: endpointOf(auth.metadata?.endpoint), key: auth.key }
}

async function catalog(auth, signal) {
  const { endpoint, key } = credentials(auth)
  signal?.throwIfAborted()
  const response = await fetch(`${endpoint}/plugin/catalog`, {
    method: 'GET', headers: { authorization: `Bearer ${key}` }, redirect: 'error', signal,
  })
  if (!response.ok) throw new Error(`LoongPass catalog: HTTP ${response.status}`)
  const value = await response.json()
  if (typeof value?.account?.provider !== 'string' || !value.account.provider || !Array.isArray(value.models)) {
    throw new Error('LoongPass returned an invalid native model catalog')
  }
  return value
}

function modalities(kinds, said) {
  if (!said && !Array.isArray(kinds)) return undefined
  return { ...(said ? Object.fromEntries(MODALITIES.map(kind => [kind, false])) : {}),
    ...Object.fromEntries((kinds ?? []).map(kind => [kind, true])) }
}

function modelOf(provider, native) {
  if (!native || !native.id || ['id', 'npm', 'url', 'apiId'].some(key => typeof native[key] !== 'string')) {
    throw new Error('LoongPass returned an incomplete native model')
  }
  const input = modalities(native.inputs, native.inputsSaid)
  if (input && !native.imageSaid) delete input.image
  return {
    id: `${provider}/${native.id}`, providerID: ID, name: native.name,
    api: { id: native.apiId, npm: native.npm, url: native.url },
    limit: { context: native.context, input: native.input, output: native.output },
    capabilities: {
      reasoning: native.reasoning,
      input: native.imageSaid ? { ...input, image: native.image } : input,
      output: modalities(native.outputs, native.outputsSaid),
    },
    cost: native.cost,
    // rowOf exports variant names only; the native supplier host retains the
    // option payloads. Do not invent options while reconstructing its shape.
    variants: Object.fromEntries((native.variants ?? []).map(name => [name, {}])),
    free: native.free, rate: native.rate, rateWas: native.rateWas,
    ...(typeof native.temperature === 'boolean' ? { temperature: native.temperature } : {}),
    release_date: native.released, fast: native.fast, serviceTiers: native.serviceTiers,
    decides: native.decides, searches: native.searches,
  }
}

async function bodyOf(body, signal) {
  signal?.throwIfAborted()
  if (body == null) return ''
  const stream = body instanceof ReadableStream ? body : new Response(body).body
  const reader = stream.getReader(), chunks = []
  const abort = () => { reader.cancel(signal.reason).catch(() => {}) }
  signal?.addEventListener('abort', abort, { once: true })
  try {
    for (;;) {
      const { done, value } = await reader.read()
      signal?.throwIfAborted()
      if (done) return Buffer.concat(chunks).toString('base64')
      chunks.push(value)
    }
  } finally {
    signal?.removeEventListener('abort', abort)
    reader.releaseLock()
  }
}

export const LoongPassPlugin = async () => ({
  auth: {
    provider: ID,
    methods: [{ type: 'api', label: 'LoongPass account key', prompts: [
      { type: 'text', key: 'endpoint', message: 'LoongPass endpoint', placeholder: DEFAULT_ENDPOINT,
        validate: value => { try { endpointOf(value) } catch (error) { return error.message } } },
      // Magpie's standard API-account identity/dedup field; this is the opaque
      // identity issued with one LoongPass account grant, not an email address.
      { type: 'text', key: 'email', message: 'LoongPass account identity',
        validate: value => typeof value === 'string' && value.trim() ? undefined : 'Enter the account identity supplied by LoongPass' },
    ] }],
    // Magpie declares these limits for a whole provider. Per-supplier/account
    // maxConcurrency/maxAccounts stay with LoongPass's local service, which
    // returns 429/Retry-After when busy; no last-read account becomes global.
    async loader(getAuth) {
      credentials(await getAuth())
      return {
        apiKey: 'loongpass',
        async fetch(input, init = {}) {
          const original = input instanceof Request ? input : undefined
          const headers = new Headers(original?.headers)
          new Headers(init.headers).forEach((value, key) => headers.set(key, value))
          const signal = init.signal ?? original?.signal
          signal?.throwIfAborted()
          const model = headers.get(MODEL_HEADER)
          if (!model) throw new Error('LoongPass request has no native model marker')
          const npm = headers.get(NPM_HEADER)
          if (!npm) throw new Error('LoongPass request has no native SDK marker')
          const session = headers.get(SESSION_HEADER) ?? ''
          for (const name of [MODEL_HEADER, NPM_HEADER, SESSION_HEADER, ...SDK_AUTH_HEADERS]) headers.delete(name)
          const { endpoint, key } = credentials(await getAuth())
          const body = await bodyOf(init.body === undefined ? original?.body : init.body, signal)
          // Capture all x-magpie-* context in JSON before the native host's
          // global fetch removes its internal headers. Only the local grant
          // travels in an HTTP auth header, and redirects are never followed.
          return fetch(`${endpoint}/plugin/fetch`, {
            method: 'POST', headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
            body: JSON.stringify({ model, npm, url: original?.url ?? String(input), method: init.method ?? original?.method ?? 'GET',
              headers: Object.fromEntries(headers), body, session }),
            signal, redirect: 'error',
          })
        },
      }
    },
    async usage(getAuth, _provider, { signal } = {}) {
      return (await catalog(await getAuth(), signal)).usage
    },
  },
  provider: {
    id: ID,
    async models(provider, { auth, signal } = {}) {
      if (!auth) return provider.models ?? {}
      const snapshot = await catalog(auth, signal)
      return Object.fromEntries(snapshot.models.map(native => {
        const model = modelOf(snapshot.account.provider, native)
        return [model.id, model]
      }))
    },
  },
  config(config) {
    config.provider ??= {}
    config.provider[ID] = { ...config.provider[ID], name: 'LoongPass' }
  },
  'chat.headers'(input, output) {
    if (input.model?.providerID !== ID && input.provider?.info?.id !== ID) return
    output.headers[MODEL_HEADER] = input.model.id
    output.headers[NPM_HEADER] = input.model.api.npm
    output.headers[SESSION_HEADER] = input.sessionID ?? ''
  },
})
export default LoongPassPlugin
