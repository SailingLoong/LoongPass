import { expect, test } from 'bun:test'
import { onRequest } from '../runtime/bridge/routing.mjs'

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
