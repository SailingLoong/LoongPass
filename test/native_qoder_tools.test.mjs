import { expect, test } from 'bun:test'
import { pathToFileURL } from 'node:url'

// Override only for the red/green check against a private copy of the pinned
// package. Normal test runs exercise the shipped plugin through its public API.
const pluginURL = process.env.LOONGPASS_QODER_TEST_MODULE
  ? pathToFileURL(process.env.LOONGPASS_QODER_TEST_MODULE).href
  : new URL('../runtime/vendor/plugins/qoder/index.mjs', import.meta.url).href
const { QoderCNAuthPlugin } = await import(pluginURL)

const TOOLS = [{ type: 'function', function: {
  name: 'echo', parameters: { type: 'object', properties: { value: { type: 'string' } } },
} }]
const JSON_CALL = '<tool_call>{"name":"echo","arguments":{"value":"example"}}</tool_call>'
const XML_CALL = '<tool_call><function=echo><parameter=value>example</parameter></function></tool_call>'
const FUNCTION_CALL = '<function=echo><parameter=value>example</parameter></function>'
const INVOKE_CALL = '<invoke name="echo"><parameter name="value">example</parameter></invoke>'
const MODEL_URL = 'https://gateway.qoder.com.cn/algo/api/v2/model/list?Encode=1'
const CHAT_URL = 'https://gateway.qoder.com.cn/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1'

function frame(value) {
  return `data: ${JSON.stringify({ headers: {}, body: typeof value === 'string' ? value : JSON.stringify(value), statusCodeValue: 200, statusCode: 'OK' })}\n\n`
}

async function reply({ stream, deltas, extra = {}, attempts }) {
  const originalFetch = globalThis.fetch
  const unexpected = []
  let chats = 0
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input)
    if (url === MODEL_URL && (init.method ?? 'GET') === 'GET') {
      return Response.json({ app: [{ key: 'fixture-model', display_name: 'Fixture', enable: true, max_input_tokens: 65536 }] })
    }
    if (url !== CHAT_URL || init.method !== 'POST') {
      unexpected.push(`${init.method ?? 'GET'} ${url}`)
      throw new Error('unexpected network request in Qoder tool test')
    }
    const current = attempts ? attempts[chats++] : chats++ === 0 ? deltas : undefined
    if (!current) {
      unexpected.push('unexpected inference recovery')
      throw new Error('unexpected inference recovery in Qoder tool test')
    }
    const body = current.map(delta => frame({ choices: [{ index: 0, delta }] })).join('')
      + frame({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + frame('[DONE]')
    return new Response(body, { headers: { 'Content-Type': 'text/event-stream' } })
  }
  try {
    const plugin = await QoderCNAuthPlugin({ client: { auth: { set: async () => {
      throw new Error('synthetic credentials must not be refreshed')
    } } } })
    const loader = await plugin.auth.loader(async () => ({
      type: 'oauth', access: 'jt-synthetic-tool-test', uid: 'synthetic-tool-test', machineId: 'synthetic-tool-machine',
      expires: Date.now() + 86400000,
    }))
    const response = await loader.fetch('https://plugin.invalid/v1/chat/completions', {
      method: 'POST', body: JSON.stringify({ model: 'fixture-model', messages: [{ role: 'user', content: 'fixture' }], tools: TOOLS, stream, ...extra }),
    })
    const raw = await response.text()
    expect(unexpected).toEqual([])
    if (!stream || !response.headers.get('content-type')?.includes('text/event-stream')) {
      const body = JSON.parse(raw)
      return { status: response.status, error: body.error, content: body.choices?.[0]?.message.content ?? '',
        calls: body.choices?.[0]?.message.tool_calls ?? [], finish: body.choices?.[0]?.finish_reason, chats }
    }
    let content = '', finish, error
    const calls = new Map()
    for (const line of raw.split('\n')) {
      if (!line.startsWith('data:') || line.slice(5).trim() === '[DONE]') continue
      const body = JSON.parse(line.slice(5))
      if (body.error) error = body.error
      const choice = body.choices?.[0]
      content += choice?.delta?.content ?? ''
      if (choice?.finish_reason) finish = choice.finish_reason
      for (const part of choice?.delta?.tool_calls ?? []) {
        const call = calls.get(part.index) ?? { id: '', type: 'function', function: { name: '', arguments: '' } }
        if (part.id) call.id = part.id
        if (part.function?.name) call.function.name += part.function.name
        call.function.arguments += part.function?.arguments ?? ''
        calls.set(part.index, call)
      }
    }
    return { status: response.status, error, content, calls: [...calls.values()], finish, chats }
  } finally {
    globalThis.fetch = originalFetch
  }
}

function literal(result, text) {
  expect(result.error).toBeUndefined()
  expect(result.status).toBe(200)
  expect(result.calls).toEqual([])
  expect(result.content).toBe(text)
  expect(result.finish).toBe('stop')
}

function invoked(result, content = '') {
  expect(result.error).toBeUndefined()
  expect(result.status).toBe(200)
  expect(result.content).toBe(content)
  expect(result.calls).toHaveLength(1)
  expect(result.calls[0].function).toEqual({ name: 'echo', arguments: '{"value":"example"}' })
  expect(result.finish).toBe('tool_calls')
}

const examples = [
  ['JSON fence', `\`\`\`json\n${JSON_CALL}\n\`\`\`\n`],
  ['XML fence', `\`\`\`xml\n${XML_CALL}\n\`\`\`\n`],
  ['tilde fence', `~~~xml\n${INVOKE_CALL}\n~~~\n`],
  ['indented long fence', `   ~~~~xml\n${INVOKE_CALL}\n   ~~~~~\n`],
  ['shorter inner fence', `\`\`\`\`xml\n\`\`\`\n${JSON_CALL}\n\`\`\`\`\n`],
  ['single code span', `Use \`${JSON_CALL}\` as an example.`],
  ['double code span', `Use \`\`a \` backtick ${INVOKE_CALL}\`\` as an example.`],
  ['triple code span', `Use \`\`\`a \`\` pair ${FUNCTION_CALL}\`\`\` as an example.`],
  ['space indent', `Example:\n\n    ${JSON_CALL}\n`],
  ['tab indent', `Example:\n\n\t${INVOKE_CALL}\n`],
  ['mixed indent', `Example:\n\n   \t${XML_CALL}\n`],
  ['indented delimiters', `    \`\`\`xml\n    ${INVOKE_CALL}\n    \`\`\`\n`],
  ['nonclosing fence line', `\`\`\`xml\n\`\`\` still inside\n${INVOKE_CALL}\n\`\`\`\n`],
]

for (const stream of [false, true]) {
  const mode = stream ? 'stream' : 'nonstream'
  for (const split of [false, true]) {
    const chunking = split ? 'character chunks' : 'whole chunk'
    const deltas = text => (split ? [...text] : [text]).map(content => ({ content }))
    for (const [name, text] of examples) {
      test(`${mode}: ${name} remains exact text (${chunking})`, async () => {
        literal(await reply({ stream, deltas: deltas(text) }), text)
      })
    }
    for (const [name, text] of [['JSON', JSON_CALL], ['wrapped XML', XML_CALL], ['function', FUNCTION_CALL], ['invoke', INVOKE_CALL],
      ['namespaced invoke', '<antml:function_calls><antml:invoke name="echo"><antml:parameter name="value">example</antml:parameter></antml:invoke></antml:function_calls>']]) {
      test(`${mode}: declared ${name} becomes a call (${chunking})`, async () => {
        invoked(await reply({ stream, deltas: deltas(text) }))
      })
    }
    for (const [name, text] of [['JSON', JSON_CALL], ['wrapped XML', XML_CALL], ['function', FUNCTION_CALL], ['invoke', INVOKE_CALL]]) {
      const unknown = text.replaceAll('echo', 'undeclared')
      test(`${mode}: undeclared ${name} stays text (${chunking})`, async () => {
        literal(await reply({ stream, deltas: deltas(unknown) }), unknown)
      })
      test(`${mode}: tool_choice none preserves ${name} as text (${chunking})`, async () => {
        literal(await reply({ stream, deltas: deltas(text), extra: { tool_choice: 'none' } }), text)
      })
    }
    for (const [name, example] of examples.slice(0, 5)) {
      test(`${mode}: real call after ${name} remains executable (${chunking})`, async () => {
        invoked(await reply({ stream, deltas: deltas(example + JSON_CALL) }), example)
      })
    }
    test(`${mode}: line-start inline span closes before real call (${chunking})`, async () => {
      const example = `\`\`\`${INVOKE_CALL}\`\`\` `
      invoked(await reply({ stream, deltas: deltas(example + INVOKE_CALL) }), example)
    })
    test(`${mode}: indented delimiters do not swallow the next real call (${chunking})`, async () => {
      const example = `    \`\`\`xml\n    ${INVOKE_CALL}\n    \`\`\`\n\n`
      invoked(await reply({ stream, deltas: deltas(example + INVOKE_CALL) }), example)
    })
    test(`${mode}: absent tools leave JSON text unchanged (${chunking})`, async () => {
      literal(await reply({ stream, deltas: deltas(JSON_CALL), extra: { tools: [] } }), JSON_CALL)
    })
  }
  const native = [
    { tool_calls: [{ index: 3, id: 'native-call', type: 'function', function: { arguments: '{"value":' } }] },
    { tool_calls: [{ index: 3, function: { name: 'echo', arguments: '"exam' } }] },
    { tool_calls: [{ index: 3, function: { arguments: 'ple"}' } }] },
  ]
  test(`${mode}: native structured fragments preserve id and arguments`, async () => {
    const result = await reply({ stream, deltas: native })
    invoked(result)
    expect(result.calls[0].id).toBe('native-call')
  })
  test(`${mode}: complete declared JSON still recovers its missing closing tag`, async () => {
    invoked(await reply({ stream, deltas: [{ content: JSON_CALL.replace('</tool_call>', '') }] }))
  })
  test(`${mode}: complete undeclared JSON without a closing tag remains text`, async () => {
    const text = JSON_CALL.replace('echo', 'undeclared').replace('</tool_call>', '')
    literal(await reply({ stream, deltas: [{ content: text }] }), text)
  })
  for (const text of ['<tool_call>{broken}</tool_call>', '<tool_call>{"name":"echo","arguments":{"value":']) {
    test(`${mode}: unreadable or truncated call still fails (${text})`, async () => {
      const result = await reply({ stream, deltas: [{ content: text }] })
      expect(result.status).toBe(502)
      expect(result.error).toBeDefined()
      expect(result.calls).toEqual([])
    })
  }
  for (const [name, extra, toolName] of [['undeclared native tool', {}, 'undeclared'], ['tool_choice none native tool', { tool_choice: 'none' }, 'echo']]) {
    test(`${mode}: ${name} is rejected before any tool is emitted`, async () => {
      const result = await reply({ stream, extra, deltas: [{ tool_calls: [{ index: 0, id: 'refused-call', type: 'function', function: { name: toolName, arguments: '{}' } }] }] })
      expect(result.status).toBe(502)
      expect(result.error).toBeDefined()
      expect(result.calls).toEqual([])
    })
  }
  test(`${mode}: nameless native-only reply still recovers once`, async () => {
    const result = await reply({ stream, attempts: [[{ tool_calls: [{ index: 0, id: 'nameless', function: { arguments: '{}' } }] }], native] })
    invoked(result)
    expect(result.chats).toBe(2)
  })
}
