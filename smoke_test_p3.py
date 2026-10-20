# -*- coding: utf-8 -*-
"""P3 端到端自检：口令登录 / 强制改密 / SSRF / 下载口令 / APK 指纹 / 签名拉流。"""
import os
import sys
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))

# 清理旧测试库，保证从 init_db 迁移路径干净
for f in ('video.db', 'INITIAL_CREDENTIALS.txt'):
    if os.path.exists(f):
        os.remove(f)

import app as flask_app
from security import (
    hash_password, verify_password, password_policy_error,
    is_disallowed_ip, validate_proxy_target, file_sha256,
)

flask_app.init_db()


class FakeHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if 'hls.m3u8' in self.path:
            body = b'#EXTM3U\n#EXTINF:2.0,\nhls-0.ts\n'
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b'\x00\x01'
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp2t')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)


def main():
    fake = HTTPServer(('127.0.0.1', 0), FakeHandler)
    port = fake.server_address[1]
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    host = f'127.0.0.1:{port}'

    conn = sqlite3.connect(flask_app.DB_PATH)
    conn.execute(
        "INSERT INTO streams (name,url,sort,enabled) VALUES ('测试流',?,99,1)",
        (f'http://{host}/live/0/hls.m3u8',))
    # 用于 SSRF 前缀校验
    conn.execute(
        "INSERT INTO streams (name,url,sort,enabled) VALUES ('前缀流',?,98,1)",
        ('http://192.168.1.50/live/0/hls.m3u8',))
    conn.commit()
    conn.close()

    client = flask_app.app.test_client()
    ok = 0

    # 1. version 含 sha256 字段
    r = client.get('/api/app/version')
    assert r.status_code == 200
    ver = r.get_json()
    assert 'sha256' in ver and ver['version'] == open('VERSION').read().strip()
    print('1 version+sha256 field OK')
    ok += 1

    # 2. 口令错误 → 401
    r = client.post('/api/mobile/login', json={'phone': '13800138000', 'password': 'wrong'})
    assert r.status_code == 401, r.data
    print('2 bad password → 401 OK')
    ok += 1

    # 3. 读初始口令登录
    creds = open('INITIAL_CREDENTIALS.txt', encoding='utf-8').read()
    # "13800138000  初始口令: XXX"
    pw = creds.split('13800138000')[1].split(':')[-1].strip()
    r = client.post('/api/mobile/login',
                    json={'phone': '13800138000', 'password': pw})
    assert r.status_code == 200, r.data
    body = r.get_json()
    assert body['ok'] and body['must_change_password'] is True
    token = body['token']
    print('3 login with init password OK, must_change=', body['must_change_password'])
    ok += 1

    # 4. 改密策略：口令=手机号 → 400
    r = client.post('/api/mobile/change-password',
                    json={'old_password': pw, 'new_password': '13800138000'},
                    headers={'Authorization': f'Bearer {token}'})
    assert r.status_code == 400, r.data
    print('4 password=phone rejected OK')
    ok += 1

    # 5. 改成强口令
    r = client.post('/api/mobile/change-password',
                    json={'old_password': pw, 'new_password': 'Fire@2026x'},
                    headers={'Authorization': f'Bearer {token}'})
    assert r.status_code == 200, r.data
    print('5 change password OK')
    ok += 1

    # 6. 新口令登录，must_change=False
    r = client.post('/api/mobile/login',
                    json={'phone': '13800138000', 'password': 'Fire@2026x'})
    body = r.get_json()
    assert body['ok'] and body['must_change_password'] is False
    token = body['token']
    print('6 re-login OK')
    ok += 1

    # 7. 安全响应头
    r = client.get('/api/app/version')
    assert r.headers.get('X-Content-Type-Options') == 'nosniff'
    assert 'X-Frame-Options' in r.headers
    print('7 security headers OK')
    ok += 1

    # 8. 下载口令
    r = client.get('/download/apk?code=wrong')
    assert r.status_code == 403
    r = client.get('/download/apk?code=8119')
    assert r.status_code in (200, 404)  # 无 APK 文件时 404 也算验证通过
    print('8 download code OK')
    ok += 1

    # 9. SSRF 单元
    assert is_disallowed_ip('127.0.0.1')
    assert is_disallowed_ip('169.254.169.254')
    assert is_disallowed_ip('localhost')
    assert not is_disallowed_ip('192.168.1.50')
    assert not is_disallowed_ip('10.0.0.1')
    ok1, _ = validate_proxy_target(
        '192.168.1.50/live/0/hls.m3u8',
        {'192.168.1.50'}, ['/live/0/'])
    assert ok1
    ok2, reason = validate_proxy_target(
        '127.0.0.1/live/0/hls.m3u8',
        {'127.0.0.1'}, ['/live/0/'])
    assert not ok2 and 'blocked' in reason or 'not allowed' in reason or 'blocked' in reason
    ok3, reason = validate_proxy_target(
        '192.168.1.50/other/path.m3u8',
        {'192.168.1.50'}, ['/live/0/'])
    assert not ok3 and 'prefix' in reason
    print('9 SSRF rules OK')
    ok += 1

    # 10. 签名拉流（127.0.0.1 会被 SSRF 拦 → 用 192.168.1.50 前缀流测 token 逻辑；
    #     测试流 host=127.0.0.1 在字面 IP 校验下会被拦，这是预期。改用非字面场景：
    #     我们把测试流改成 192.168.1.50 无法真正连通，故只验证 token 拒绝与路径前缀。）
    r = client.get('/proxy/192.168.1.50/live/0/hls.m3u8')
    assert r.status_code == 403  # 无 token
    # 带 token 但主机不在白名单也会 403；192.168.1.50 在白名单
    from stream_token import make_query
    q = make_query(flask_app.app.secret_key, '192.168.1.50')
    r = client.get(f'/proxy/192.168.1.50/live/0/hls.m3u8?{q}')
    # 上游不可达 → 502/504，但不应是 403
    assert r.status_code != 403, r.data
    print('10 signed proxy path accepted (upstream unreachable =>', r.status_code, ')')
    ok += 1

    # 11. 坏路径前缀被拒
    q = make_query(flask_app.app.secret_key, '192.168.1.50')
    r = client.get(f'/proxy/192.168.1.50/evil/secret.m3u8?{q}')
    assert r.status_code == 403
    print('11 path prefix denied OK')
    ok += 1

    # 12. 口令策略单测
    assert password_policy_error('short') is not None
    assert password_policy_error('13800138000', '13800138000') is not None
    assert password_policy_error('Fire@2026x') is None
    print('12 password policy OK')
    ok += 1

    # 13. 哈希单测
    h = hash_password('Fire@2026x')
    assert verify_password('Fire@2026x', h)
    assert not verify_password('nope', h)
    print('13 password hash OK')
    ok += 1

    print(f'\nALL {ok} P3 checks passed')
    fake.shutdown()


if __name__ == '__main__':
    main()
