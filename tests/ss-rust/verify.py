"""Integration assertions against real ssserver processes and generated files."""
import base64
import json
import os
import signal
import socket
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path('/etc/shadowsocks-rust')


def processes():
    result = []
    for entry in Path('/proc').glob('[0-9]*/exe'):
        try:
            if os.readlink(entry).removesuffix(' (deleted)') == '/usr/local/bin/ssserver':
                result.append(int(entry.parent.name))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return result


action = sys.argv[1]
if action == 'ports':
    for port in map(int, sys.argv[2:]):
        deadline = time.monotonic() + 15
        while True:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=1):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise AssertionError(f'No listener on port {port}')
                time.sleep(0.25)
elif action == 'config':
    expected = list(map(int, sys.argv[2:]))
    servers = json.loads((ROOT / 'config.json').read_text())['servers']
    assert [s['server_port'] for s in servers] == expected
    for server in servers:
        assert len(base64.b64decode(server['password'], validate=True)) == 16
    encoded = (ROOT / 'subscribe/subscribe.txt').read_bytes()
    assert b'\n' not in encoded
    uris = base64.b64decode(encoded, validate=True).decode().split()
    assert len(uris) == len(servers)
    for uri, server in zip(uris, servers):
        parsed = urlsplit(uri)
        assert parsed.scheme == 'ss'
        assert parsed.hostname == '203.0.113.10'
        assert parsed.port == server['server_port']
        credentials = base64.b64decode(parsed.username, validate=True).decode()
        assert credentials == f"{server['method']}:{server['password']}"
    for file in ['surge.conf', 'clash.yaml', 'info.txt']:
        text = (ROOT / 'subscribe' / file).read_text()
        for server in servers:
            assert str(server['server_port']) in text
            assert server['password'] in text
elif action == 'reset':
    before = json.loads(Path(sys.argv[2]).read_text())['servers']
    after = json.loads((ROOT / 'config.json').read_text())['servers']
    assert len(before) == len(after)
    for old, new in zip(before, after):
        assert old['password'] != new['password']
        assert old['server_port'] == new['server_port']
        assert old['method'] == new['method']
elif action == 'crash':
    pids = processes()
    assert pids, 'No ssserver process to terminate'
    for pid in pids:
        os.kill(pid, signal.SIGKILL)
elif action == 'stopped':
    assert not processes(), 'ssserver still running after uninstall'
else:
    raise AssertionError(f'Unknown assertion: {action}')
