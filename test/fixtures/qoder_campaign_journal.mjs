import { appendFileSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

// Isolate the real Qoder reward hooks and the host from the desktop and network.
// Other hooks supply only the model/usage facts needed to open the test account.
export const QoderCampaignJournal = async (client, options) => {
  process.env.QODERCN_RUNTIME_INFO = resolve('missing-runtime')
  const { QoderCNAuthPlugin } = await import(pathToFileURL(options.qoderPlugin))
  const native = await QoderCNAuthPlugin(client)
  let writing = false
  globalThis.fetch = async (input, init) => {
    const control = JSON.parse(readFileSync('control.json', 'utf8'))
    const path = new URL(input).pathname
    const method = init?.method ?? 'GET'
    const base = '/sash/api/v1/me/campaigns'
    if (method === 'GET' && path === base) {
      return Response.json({campaigns: writing ? control.dispatchCampaigns ?? control.campaigns : control.campaigns})
    }
    if (method === 'POST' && control.campaigns.some(c => path === base + '/' + c.campaignId + '/claim')) {
      appendFileSync('hooks.jsonl', JSON.stringify({path}) + '\n')
      if (!control.receipt) throw Error('Synthetic transport lost the claim reply')
      return Response.json(control.receipt)
    }
    throw Error('Unexpected synthetic Qoder request')
  }
  const hook = method => async (getAuth, provider, context) => {
    writing = method === 'checkin'
    try {
      return await native.auth[method](async () => ({
        ...await getAuth(), patAuth: true, expires: 4102444800000,
      }), provider, context)
    } finally {
      writing = false
    }
  }
  return {
    config: async cfg => { cfg.provider = {[options.provider]: {name: 'Synthetic Qoder', models: {synthetic: {name: 'Synthetic'}}}} },
    auth: {
      provider: options.provider, methods: [],
      loader: async () => ({baseURL: 'https://fixture.invalid/v1', apiKey: 'fake'}),
      usage: async () => ({windows: [{name: 'Credits', amount: 900, limit: 1000, unit: 'credits'}]}),
      checkinStatus: hook('checkinStatus'), checkin: hook('checkin'),
    },
  }
}
