let aborted = 0;
export const FixturePlugin = async () => ({
  auth: {
    provider: "fixture",
    methods: [],
    refreshLead: 0,
    refresh: async () => {
      await new Promise((resolve) => setTimeout(resolve, 80));
      return {access: 'fake-renewed', refresh: 'fake-next', expires: Date.now() + 3600000};
    },
    loader: async (getAuth) => ({
      baseURL: "https://fixture.invalid/v1",
      apiKey: (await getAuth()).access,
      fetch: async (url, init) => {
        if (url.endsWith('/large')) {
          let count = 0;
          return new Response(new ReadableStream({
            pull(c) {
              if (count++ === 40) return c.close();
              c.enqueue(new Uint8Array(65536).fill(97));
            },
          }));
        }
        if (url.endsWith('/hang')) {
          return new Response(new ReadableStream({
            start(c) {
              init.signal.addEventListener('abort', () => { aborted++; c.error(new Error('aborted')); }, {once: true});
            },
          }));
        }
        if (url.endsWith('/stats')) return Response.json({aborted});
        if (url.endsWith('/exit')) process.exit(17);
        if (url.endsWith('/refused')) return new Response('{"error":{"code":11128,"message":"vendor detail"}}', {
          status: 429, headers: {'retry-after': '7', 'x-magpie-sign-in': 'kept'},
        });
        return new Response(JSON.stringify({
        access: (await getAuth()).access,
        authorization: new Headers(init.headers).get("authorization"),
        session: new Headers(init.headers).get("x-fixture-session"),
        body: init.body && JSON.parse(init.body),
      }), {headers: {"content-type": "application/json"}});
      },
    }),
  },
  "provider.models": async () => ({
    "fixture-model": {id: "fixture-model", name: "Fixture", api: {npm: "@ai-sdk/openai-compatible"}},
  }),
  "chat.headers": async (input, output) => { output.headers['x-fixture-session'] = input.sessionID; },
});
