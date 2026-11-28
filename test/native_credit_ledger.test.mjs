import { test, expect } from 'bun:test'
import { _internal as mini } from '../runtime/vendor/plugins/minimax/index.mjs'
import { _internal as trae } from '../runtime/vendor/plugins/trae/index.mjs'
import { _internal as loomy } from '../runtime/vendor/plugins/loomy/index.mjs'

test('MiniMax distinguishes a reconciled expired amount, zero, incomplete accounting and a future balance', () => {
  const now = Date.UTC(2026, 10, 28), past = now - 3600000
  const batch = (id, spent, left, at = past) => ({ id, credit_type: 2, granted_at_ms: past - 86400000, expire_at_ms: at,
    granted_amount: '1,200.125', consumed_amount: spent, remaining_amount: left })
  const rows = mini.expiryLedger([batch('a','200.0625','1,000.0625'), batch('b','1,200.125','0'),
    batch('c','200','0'), batch('d',null,'25.125',now + 1000)], now)
  expect(rows.map(r => [r.id, r.issued, r.unused, r.remaining])).toEqual([
    ['a',1200.125,1000.0625,undefined],['b',1200.125,0,undefined],
    ['c',1200.125,undefined,undefined],['d',1200.125,undefined,25.125],
  ])
})

test('Loomy reconciles two closed Beijing cycles and keeps daily and permanent model debits in their billing hour', () => {
  const day = h => Date.parse(h+'+08:00') / 1000
  const debit = (id,t,source,before,after) => ({ledgerId:id, createdAt:day(t), dailyCycleDate:source==='daily'?t.slice(0,10):'',
    modelName:'model',direction:'debit',consumeSource:source,pointsActual:before-after,balanceBefore:before,balanceAfter:after})
  const rows=[debit(4,'2030-02-15T10:00:00','daily',1160,1145),
    debit(3,'2030-02-14T10:56:00','permanent',200,160),debit(2,'2030-02-14T10:32:00','daily',1200,200),
    debit(1,'2030-02-13T23:59:21','daily',1200,1125)]
  const wallet={balance:160,dailyBalance:985,availableBalance:1145}
  const now=day('2030-02-15T12:00:00')*1000
  const r=loomy.ledgerFacts(wallet,rows,true,now)
  expect(r.creditBatches.map(b=>[b.at,b.issued,b.unused])).toEqual([
    ['2030-02-14T16:00:00.000Z',1000,0],['2030-02-13T16:00:00.000Z',1000,925]])
  expect(r.creditSpending.hours.find(h=>h.at===day('2030-02-14T10:00:00')*1000)?.amount).toBe(1040)
  expect(loomy.ledgerFacts(wallet,rows,false,now).creditBatches.length).toBe(1)
  expect(loomy.ledgerFacts(wallet,[...rows.slice(0,2),{...rows[2],balanceAfter:250},rows[3]],true,now).creditBatches).toEqual([])
  expect(loomy.ledgerFacts(wallet,[rows[0], ...rows],true,now)).toEqual({})
})

test('TRAE per-turn billing uses the change in precise conversation credits', async () => {
  const previous = globalThis.fetch
  let amount = '0.03125'
  try {
    globalThis.fetch = async () => Response.json({ data: { code: 0, user_usage_group_by_session: {
      credits_by_source: { gift: amount }, extra_info: { input_token: 250, output_token: 15, cache_read_token: 21 },
    } } })
    const account = { token: 'synthetic-token', uid: 'fixture-turn' }
    const site = trae.SITES['trae-cn']
    const options = { usage: { prompt_tokens: 250, completion_tokens: 15 }, wait: 100 }
    const first = await trae.turnBilling(account, site, 'fixture-conversation', options)
    expect(first?.credits).toBe(0.03125)
    amount = '0.15625'
    const second = await trae.turnBilling(account, site, 'fixture-conversation', options)
    expect(second?.credits).toBe(0.125)
  } finally { globalThis.fetch = previous }
})
