#!/usr/bin/env python3
"""Isolated installed-Magpie + Claude Code acceptance; input secrets stay private.

Reads a loopback origin and temporary local grants on stdin. Never edits the
user's Magpie/Claude configuration. Outputs statuses, not prompts or raw errors.
"""
import http.cookiejar
import json
import os
import re
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def main():
    config = json.load(sys.stdin)
    modes = config.get('modes', ['text', 'stream', 'tool', 'normal', 'normal_tool'])
    if not isinstance(modes, list) or not modes or any(
            mode not in ('text', 'stream', 'tool', 'normal', 'normal_tool') for mode in modes):
        raise RuntimeError('invalid_acceptance_modes')
    results = []
    binary = '/Applications/magpie.app/Contents/MacOS/magpie'
    with tempfile.TemporaryDirectory(prefix='loongpass-claude-pool-') as scratch:
        root = Path(scratch)
        env = os.environ.copy()
        for kind in ('CONFIG', 'DATA', 'STATE'):
            env['XDG_' + kind + '_HOME'] = str(root / kind.lower())
        env['MAGPIE_NO_ACCOUNTS'] = '1'
        env['MAGPIE_WEB_KEY'] = secrets.token_urlsafe(24)
        gateway, web = f'http://127.0.0.1:{port()}', f'http://127.0.0.1:{port()}'
        env['MAGPIE_ADDR'] = gateway.removeprefix('http://')

        def cli(*args):
            r = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=30)
            if r.returncode:
                raise RuntimeError('native_cli_failed_' + '_'.join(args[:2]))
            return r.stdout

        process = None
        with tempfile.TemporaryFile() as logs:
            try:
                installs = config['sources']
                if config.get('unified'):
                    installs = [{'id': 'unified', 'protocols': ['messages'],
                                 'bindings': [config['sources'][0]['bindings'][0]],
                                 'models': [b['model'] for s in config['sources'] for b in s['bindings']]}]
                for source in installs:
                    source['native_id'] = 'loongpass-live-' + source['id']
                    args = ['provider', 'add', source['native_id'], 'id=' + source['native_id']]
                    base = config['origin'] if config.get('unified') else config['origin'] + '/providers/' + source['id']
                    if 'messages' in source['protocols']:
                        args.append('anthropic=' + (base if config.get('unified') else base + '/messages'))
                    if 'chat' in source['protocols']:
                        args.append('url=' + base + '/chat/v1')
                    args += ['key=' + source['bindings'][0]['key'], 'routing=rotate', 'errors=pass', 'patience=off']
                    args.append('header.X-LoongPass-Session=${sessionId}:${subagentId}')
                    args.append('models=' + ','.join(source.get('models') or dict.fromkeys(b['model'] for b in source['bindings'])))
                    cli(*args)
                if config.get('unified'):
                    for source in config['sources']:
                        source['native_id'] = installs[0]['native_id']
                process = subprocess.Popen([binary, 'serve', '--web=' + web.removeprefix('http://')], env=env, stdout=logs, stderr=logs)
                control = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
                for _ in range(100):
                    try:
                        with control.open(web + '/?k=' + env['MAGPIE_WEB_KEY'], timeout=1) as r:
                            if r.status == 200:
                                break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise RuntimeError('native_runtime_unavailable')
                for source in config['sources']:
                    for index, binding in enumerate(source['bindings'][1:], 2):
                        request = urllib.request.Request(web + '/api/keys/add', data=json.dumps({'id': source['native_id'], 'name': f'acceptance {index}', 'key': binding['key']}).encode(), headers={'Content-Type': 'application/json', 'Origin': web})
                        with control.open(request, timeout=15) as r:
                            if r.status != 200:
                                raise RuntimeError('native_key_add_failed')
                    cli('provider', 'refresh', source['native_id'])
                    issued = json.loads(cli('gateway-key', 'issue', '--ttl', '10m', '--name', 'LoongPass acceptance', '--models', source['native_id'] + '/*', '--json'))
                    caller = issued.get('key') or issued.get('secret')
                    child_env = env.copy()
                    for name in list(child_env):
                        if name.startswith('ANTHROPIC_') or name.startswith('CLAUDE_CODE_'):
                            child_env.pop(name)
                    child_env.update(ANTHROPIC_BASE_URL=gateway, ANTHROPIC_API_KEY=caller,
                                     CLAUDE_CONFIG_DIR=str(root / 'claude'), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_TELEMETRY='1')
                    child_env['CLAUDE_CODE_MAX_RETRIES'] = '0'
                    child_env['CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK'] = '1'
                    child_env['CLAUDE_CODE_MAX_OUTPUT_TOKENS'] = '1024'
                    work = root / source['id']
                    work.mkdir(mode=0o700)
                    model = source['native_id'] + '/' + source['bindings'][0]['model']
                    base_args = ['/opt/homebrew/bin/claude', '--bare', '-p', '--model', model, '--no-session-persistence',
                                 '--setting-sources', '', '--strict-mcp-config', '--tools', '', '--max-turns', '4',
                                 '--system-prompt', 'You are a protocol acceptance assistant. Follow the requested marker or echo tool exactly.']
                    result = {'source': source['id']}
                    for mode in modes:
                        call_file = work / f'echo-{mode}-calls.jsonl'
                        args = base_args[:]
                        if mode in ('normal', 'normal_tool'):
                            # Keep Claude Code's default prompt, environment
                            # messages and built-in tools in a separate probe.
                            args.remove('--bare')
                            for option in ('--system-prompt', '--tools'):
                                position = args.index(option)
                                del args[position:position + 2]
                            args += ['--permission-mode', 'dontAsk']
                        if mode in ('tool', 'normal_tool'):
                            mcp = {'mcpServers': {'loongpass_echo': {'command': sys.executable,
                                   'args': ['-I', str(Path(__file__).with_name('model_pooling_echo.py')), str(call_file)]}}}
                            prompt = 'Use mcp__loongpass_echo__echo_marker exactly once with marker LOONGPASS_CLAUDE_TOOL. After it returns, reply with its returned marker exactly.'
                            if mode == 'normal_tool':
                                prompt = 'First use ToolSearch to load mcp__loongpass_echo__echo_marker. ' + prompt
                            args += ['--mcp-config', json.dumps(mcp), '--allowedTools', 'ToolSearch,mcp__loongpass_echo__echo_marker',
                                     '--output-format', 'json', prompt]
                            marker = 'LOONGPASS_CLAUDE_TOOL'
                        else:
                            marker = 'LOONGPASS_CLAUDE_' + mode.upper()
                            args += ['--mcp-config', '{"mcpServers":{}}', '--output-format', 'stream-json' if mode == 'stream' else 'json']
                            if mode == 'stream':
                                args += ['--verbose', '--include-partial-messages']
                            args += ['Reply with exactly ' + marker + '.']
                        try:
                            probe_env = child_env.copy()
                            if mode == 'normal_tool':
                                probe_env['ENABLE_TOOL_SEARCH'] = 'true'
                            r = subprocess.run(args, env=probe_env, cwd=work, capture_output=True, text=True, timeout=150)
                            objects = [json.loads(line) for line in r.stdout.splitlines() if line.strip().startswith('{')]
                            final = next((x for x in reversed(objects) if x.get('type') == 'result'), {})
                            ok = r.returncode == 0 and not final.get('is_error') and marker in str(final.get('result', ''))
                            if mode == 'stream':
                                result['partial_events'] = sum(x.get('type') == 'stream_event' for x in objects)
                                ok = ok and result['partial_events'] > 0
                            if mode in ('tool', 'normal_tool'):
                                calls = call_file.read_text().splitlines() if call_file.exists() else []
                                result['normal_tool_echo_calls' if mode == 'normal_tool' else 'echo_calls'] = len(calls)
                                ok = ok and len(calls) == 1
                            result[mode] = 'passed' if ok else 'failed'
                            if not ok:
                                result[mode + '_exit'] = r.returncode
                                # Classify only; raw client/vendor output can contain secrets.
                                details = r.stdout + r.stderr
                                status = re.search(r'(?:API Error:|HTTP)[ :]+([45][0-9]{2})', details)
                                result[mode + '_failure'] = ('http_' + status[1] if status else
                                    'invalid_mcp_config' if 'Invalid MCP configuration' in details else
                                    'marker_or_client_failure')

                        except subprocess.TimeoutExpired:
                            result[mode] = 'timeout'
                        except (ValueError, OSError):
                            result[mode] = 'client_failed'
                        if result.get(mode) != 'passed':
                            for later in modes:
                                result.setdefault(later, 'not_run_after_failure')
                            break
                    results.append(result)
            finally:
                if process is not None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        return {'sources': results, 'temporary_profiles_removed': True}


if __name__ == '__main__':
    try:
        print(json.dumps(main()))
    except Exception as failure:
        code = str(failure) if isinstance(failure, RuntimeError) else type(failure).__name__
        if not code.replace('_', '').isalnum():
            code = 'client_failed'
        print(json.dumps({'status': 'client_integration_unavailable', 'failure': code[:80], 'sources': []}))
        sys.exit(1)
