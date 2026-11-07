#!/usr/bin/env python3
"""Acceptance-only MCP tool: echoes a bounded marker; no shell or network."""
import json
from pathlib import Path
import sys
calls = Path(sys.argv[1])
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if 'id' not in request:
        continue
    if method == 'initialize':
        result = {'protocolVersion': request.get('params', {}).get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'loongpass-echo', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'echo_marker', 'description': 'Echo the marker exactly.', 'inputSchema': {'type': 'object', 'properties': {'marker': {'type': 'string'}}, 'required': ['marker']}}]}
    elif method == 'tools/call':
        params = request.get('params', {})
        marker = params.get('arguments', {}).get('marker')
        valid = params.get('name') == 'echo_marker' and isinstance(marker, str) and len(marker) < 128
        if valid:
            with calls.open('a') as target:
                target.write(json.dumps({'marker': marker}) + '\n')
        result = {'content': [{'type': 'text', 'text': marker if valid else 'invalid marker'}], 'isError': not valid}
    elif method == 'ping':
        result = {}
    else:
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'unsupported method'}}), flush=True)
        continue
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
