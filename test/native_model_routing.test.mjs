import { expect, test } from 'bun:test'
import { onRequest, strategies } from '../runtime/bridge/routing.mjs'

test('routes public model IDs before native protocol conversion without changing the request', () => {
  const options = { routes: {
    'loongpass/auto': 'group/loongpass-auto',
    'loongpass/deepseek-flash': 'group/loongpass-flash',
  } }
  const body = { model: 'loongpass/deepseek-flash', messages: [{ role: 'user', content: 'synthetic' }], temperature: 0.7 }
  expect(onRequest(body, { options })).toEqual({ ...body, model: 'group/loongpass-flash' })
  expect(body.model).toBe('loongpass/deepseek-flash')
  expect(onRequest({ ...body, model: 'loongpass/auto' }, { options }).model).toBe('group/loongpass-auto')
  expect(onRequest({ ...body, model: 'loongpass/deepseek-flash:high' }, { options }).model).toBe('group/loongpass-flash:high')
  expect(onRequest({ ...body, model: 'another/model' }, { options })).toBeUndefined()
})

test('exact remaining-quota expiry outranks percentage use and reset time', () => {
  const at = Date.now()
  const options = { defaultAccount: 'first', pools: { 'group/flash': {
    first: { expires: [at + 60_000], available: true },
    later: { expires: [at + 70_000], available: true },
    unknown: { expires: [], available: true },
    spent: { expires: [at + 1_000], available: false },
  } } }
  const seats = [
    { key: 'loongpass@unknown', known: true, used: 0, soon: [at + 1] },
    { key: 'loongpass@later', known: true, used: 5 },
    { key: 'loongpass', known: true, used: 80 },
    { key: 'loongpass@spent', known: true, used: 100 },
  ]
  expect(strategies.quota('group/flash', seats, options)).toEqual([2, 1, 0, 3])
  seats[2].resting = true
  expect(strategies.quota('group/flash', seats, options)).toEqual([1, 0, 3, 2])
})

test('expired batches cannot win the ordering and another model uses its own quota', () => {
  const at = Date.now()
  const options = { pools: {
    'group/flash': { a: { expires: [at - 1, at + 1000], available: true }, b: { expires: [at + 500], available: true } },
    'group/pro': { a: { expires: [at + 100], available: true }, b: { expires: [at + 5000], available: true } },
  } }
  const seats = [{ key: 'loongpass@a' }, { key: 'loongpass@b' }]
  expect(strategies.quota('group/flash', seats, options)).toEqual([1, 0])
  expect(strategies.quota('group/pro', seats, options)).toEqual([0, 1])
})
