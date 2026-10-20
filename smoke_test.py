# -*- coding: utf-8 -*-
"""端到端自检：JWT 登录 → 带签名拉流 → 无签名拒绝 → m3u8 改写。"""
import os
import sys
import json
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))

# 隔离数据库 / secret
os.environ.setdefault('PORT', '18119')
os.environ['ALLOW_LOOPBACK_PROXY'] = '1'
import app as flask_app

flask_app.init_db()

# ── 假源站 ──
class FakeHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.endswith('.m3u8') or 'hls.m3u8' in self.path:
            body = b'#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nhls-0.ts\n#EXTINF:2.0,\nhls-1.ts\n'
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b'\x00\x01\x02\x03'
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp2t')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)


def start_fake():
    srv = HTTPServer(('127.0.0.1', 0), FakeHandler)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, port


def main():
    fake, port = start_fake()
    host = f'127.0.0.1:{port}'
    # 写入测试流（直接 SQLite，避免依赖 request context）
    import sqlite3
    conn = sqlite3.connect(flask_app.DB_PATH)
    conn.execute("INSERT INTO streams (name,url,sort,enabled) VALUES ('测试流',?,99,1)",
                 (f'http://{host}/live/0/hls.m3u8',))
    conn.commit()
    conn.close()

    client = flask_app.app.test_client()
    ok = 0

    # 1. version
    r = client.get('/api/app/version')
    assert r.status_code == 200, r.data
    ver = r.get_json()
    print('version', ver)
    assert ver['version'] == open('VERSION').read().strip()
    ok += 1

    # 2. login (password auth)
    creds = open('INITIAL_CREDENTIALS.txt', encoding='utf-8').read()
    pw = creds.split('13800138000')[1].split(':')[-1].strip()
    r = client.post('/api/mobile/login',
                    json={'phone': '13800138000', 'password': pw})
    assert r.status_code == 200, r.data
    body = r.get_json()
    assert body.get('ok') is True and body.get('token'), body
    token = body['token']
    print('login ok, role=', body.get('role'))
    ok += 1

    # 3. streams with signed proxy_url
    r = client.get('/api/mobile/streams', headers={'Authorization': f'Bearer {token}'})
    assert r.status_code == 200
    streams = r.get_json()
    test = [s for s in streams if s.get('sort') == 99]
    assert test, streams
    proxy_url = test[0]['proxy_url']
    print('signed proxy_url', proxy_url)
    assert 'exp=' in proxy_url and 'sig=' in proxy_url
    ok += 1

    # 4. proxy without token → 403
    path_noauth = '/proxy/' + host + '/live/0/hls.m3u8'
    r = client.get(path_noauth)
    assert r.status_code == 403, r.status_code
    print('proxy no token → 403 OK')
    ok += 1

    # 5. proxy with token → m3u8 rewritten
    r = client.get(proxy_url)
    assert r.status_code == 200, (r.status_code, r.data[:200])
    text = r.data.decode()
    print('m3u8 body:\n', text)
    assert 'hls-0.ts' in text
    assert '/proxy/' in text and 'sig=' in text
    assert 'hls-0.ts?exp=' in text or 'hls-0.ts?' in text
    ok += 1

    # 6. fetch rewritten segment
    seg_line = [ln for ln in text.splitlines() if 'hls-0.ts' in ln][0]
    r = client.get(seg_line)
    assert r.status_code == 200, (r.status_code, seg_line)
    print('segment via', seg_line, '→', r.status_code)
    ok += 1

    # 7. bad sig → 403
    r = client.get(path_noauth + '?exp=9999999999&sig=deadbeef')
    assert r.status_code == 403
    print('bad sig → 403 OK')
    ok += 1

    # 8. unauthorized streams
    r = client.get('/api/mobile/streams')
    assert r.status_code == 401
    print('no token streams → 401 OK')
    ok += 1

    print(f'\nALL {ok} checks passed')
    fake.shutdown()


if __name__ == '__main__':
    main()
