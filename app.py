"""
消防视频直播查看系统 - 轻量版
Flask + SQLite, 手机号登录, 6路HLS直播(点击播放)
"""
import os
import time
import hmac
import hashlib
import base64
import json as json_mod
import sqlite3
import requests
from datetime import timedelta
from functools import wraps
from urllib.parse import urlparse
from flask import (Flask, render_template, request, redirect, send_file,
                   url_for, session, jsonify, g, Response, stream_with_context)

app = Flask(__name__)
app.secret_key = os.urandom(24)
app.permanent_session_lifetime = timedelta(hours=12)

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'video.db')

DEFAULT_STREAMS = [
    {'name': '警情信息',        'url': 'http://192.168.181.106/live/0/hls.m3u8', 'sort': 1},
    {'name': '一体化指挥平台',  'url': 'http://192.168.181.103/live/0/hls.m3u8', 'sort': 2},
    {'name': '现场图传',        'url': 'http://192.168.181.105/live/0/hls.m3u8', 'sort': 3},
    {'name': '无人机画面',      'url': 'http://192.168.181.104/live/0/hls.m3u8', 'sort': 4},
    {'name': '社会面监控',      'url': 'http://192.168.181.101/live/0/hls.m3u8', 'sort': 5},
    {'name': '全国应急指挥系统', 'url': 'http://192.168.181.102/live/0/hls.m3u8', 'sort': 6},
]

# ── 登录频率限制 ──────────────────────────────────────────────
_login_attempts = {}  # {phone: [timestamp, ...]}
LOGIN_MAX_ATTEMPTS = 5
LOGIN_WINDOW = 300  # 5 分钟


def is_rate_limited(phone):
    now = time.time()
    attempts = _login_attempts.get(phone, [])
    # 清理过期记录
    attempts = [t for t in attempts if now - t < LOGIN_WINDOW]
    _login_attempts[phone] = attempts
    return len(attempts) >= LOGIN_MAX_ATTEMPTS


def record_attempt(phone):
    _login_attempts.setdefault(phone, []).append(time.time())


# ── JWT (标准库实现, 无第三方依赖) ─────────────────────────
def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def jwt_encode(payload: dict, secret, expires_in: int = 43200) -> str:
    secret_bytes = secret if isinstance(secret, bytes) else secret.encode()
    header = _b64url(json_mod.dumps({"alg":"HS256","typ":"JWT"}).encode())
    payload = {**payload, "exp": int(time.time()) + expires_in}
    body = _b64url(json_mod.dumps(payload).encode())
    sig = _b64url(hmac.new(secret_bytes, f"{header}.{body}".encode(), hashlib.sha256).digest())
    return f"{header}.{body}.{sig}"

def jwt_decode(token: str, secret):
    try:
        secret_bytes = secret if isinstance(secret, bytes) else secret.encode()
        header, body, sig = token.split(".")
        expected = _b64url(hmac.new(secret_bytes, f"{header}.{body}".encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, expected):
            return None
        payload = json_mod.loads(base64.urlsafe_b64decode(body + "=="))
        if payload.get("exp", 0) < time.time():
            return None
        return payload
    except Exception:
        return None


# ── 双模式认证装饰器 (JWT 或 Session) ───────────────────────
def any_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # 1. 先试 JWT
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            payload = jwt_decode(auth[7:], app.secret_key)
            if payload:
                g.current_user = payload
                return f(*args, **kwargs)
        # 2. 再试 Session
        if "phone" in session:
            g.current_user = {"phone": session["phone"], "name": session.get("name",""), "role": session.get("role","user")}
            return f(*args, **kwargs)
        return jsonify(ok=False, msg="unauthorized"), 401
    return decorated


def any_admin(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            payload = jwt_decode(auth[7:], app.secret_key)
            if payload and payload.get("role") == "admin":
                g.current_user = payload
                return f(*args, **kwargs)
        if "phone" in session and session.get("role") == "admin":
            g.current_user = {"phone": session["phone"], "name": session.get("name",""), "role": "admin"}
            return f(*args, **kwargs)
        return jsonify(ok=False, msg="forbidden"), 403
    return decorated


# ── 视频流白名单 (防 SSRF) ──────────────────────────────────
def get_allowed_hosts():
    """从数据库读取允许代理的主机+路径前缀"""
    try:
        db = sqlite3.connect(DB_PATH)
        rows = db.execute('SELECT url FROM streams WHERE enabled=1').fetchall()
        db.close()
        allowed = []
        for (url,) in rows:
            parsed = urlparse(url)
            # 取路径目录作为前缀, 如 /live/0/hls.m3u8 -> /live/0/
            path_prefix = parsed.path.rsplit('/', 1)[0] + '/'
            allowed.append((parsed.netloc, path_prefix))
        return allowed
    except Exception:
        return []


# ── 数据库 ──────────────────────────────────────────────────
def get_db():
    if 'db' not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(_):
    db = g.pop('db', None)
    if db:
        db.close()


def init_db():
    db = sqlite3.connect(DB_PATH)
    db.executescript('''
        CREATE TABLE IF NOT EXISTS users (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            phone    TEXT UNIQUE NOT NULL,
            name     TEXT DEFAULT '',
            role     TEXT DEFAULT 'user',
            enabled  INTEGER DEFAULT 1,
            created  TEXT DEFAULT (datetime('now','localtime'))
        );
        CREATE TABLE IF NOT EXISTS streams (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            name     TEXT NOT NULL,
            url      TEXT NOT NULL,
            sort     INTEGER DEFAULT 0,
            enabled  INTEGER DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS login_log (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            phone    TEXT,
            ip       TEXT,
            time     TEXT DEFAULT (datetime('now','localtime'))
        );
        CREATE TABLE IF NOT EXISTS settings (
            key      TEXT PRIMARY KEY,
            value    TEXT NOT NULL
        );
    ''')
    # 默认设置
    if db.execute("SELECT COUNT(*) FROM settings WHERE key='web_video_enabled'").fetchone()[0] == 0:
        db.execute("INSERT INTO settings (key,value) VALUES ('web_video_enabled','1')")
    if db.execute('SELECT COUNT(*) FROM streams').fetchone()[0] == 0:
        for s in DEFAULT_STREAMS:
            db.execute('INSERT INTO streams (name,url,sort) VALUES (?,?,?)',
                       (s['name'], s['url'], s['sort']))
    if db.execute('SELECT COUNT(*) FROM users').fetchone()[0] == 0:
        db.execute("INSERT INTO users (phone,name,role) VALUES ('13800138000','管理员','admin')")
        db.execute("INSERT INTO users (phone,name,role) VALUES ('13900139000','张三','user')")
        db.execute("INSERT INTO users (phone,name,role) VALUES ('13700137000','李四','user')")
    db.commit()
    db.close()


# ── 装饰器 ──────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'phone' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated


def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'phone' not in session:
            return redirect(url_for('login'))
        if session.get('role') != 'admin':
            return redirect(url_for('dashboard'))
        return f(*args, **kwargs)
    return decorated


def csrf_protect(f):
    """API 接口要求 X-Requested-With 头 (简单 CSRF 防护)"""
    @wraps(f)
    def decorated(*args, **kwargs):
        if request.method in ('POST', 'PUT', 'DELETE'):
            if request.headers.get('X-Requested-With') != 'XMLHttpRequest':
                return jsonify(ok=False, msg='forbidden'), 403
        return f(*args, **kwargs)
    return decorated


# ── 页面 ──────────────────────────────────────────────────────
# ── 首页: App 下载页 ──
@app.route('/')
def download_page():
    # 如果已登录且 web 视频开启, 直接跳视频页
    if 'phone' in session:
        if _get_setting('web_video_enabled') == '1':
            return redirect(url_for('video_page'))
    return render_template('download.html')


@app.route('/download/apk')
def download_apk():
    """口令验证后下载 APK"""
    code = request.args.get('code', '')
    if code != '8119':
        return '口令错误', 403
    apk_path = os.path.join(app.root_path, 'static', 'app', 'video-live.apk')
    if not os.path.exists(apk_path):
        return 'APK 文件不存在', 404
    return send_file(apk_path, as_attachment=True, download_name='video-live.apk')


@app.route('/video')
@login_required
def video_page():
    """视频页 (受 web_video_enabled 控制)"""
    if _get_setting('web_video_enabled') != '1':
        return render_template('video_disabled.html')
    db = get_db()
    streams = db.execute('SELECT * FROM streams WHERE enabled=1 ORDER BY sort').fetchall()
    return render_template('dashboard.html', streams=streams,
                           name=session.get('name'), role=session.get('role'))


# ── 设置辅助 ──
def _get_setting(key, default='1'):
    try:
        db = get_db()
        row = db.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
        return row['value'] if row else default
    except Exception:
        return default


# ── 设置 API ──
@app.route('/api/settings')
@any_auth
def api_get_settings():
    return jsonify(web_video_enabled=int(_get_setting('web_video_enabled', '1')))


@app.route('/api/settings/web_video', methods=['PUT'])
@any_admin
@csrf_protect
def api_toggle_web_video():
    data = request.get_json(force=True, silent=True) or request.form.to_dict() or {}
    raw = data.get('value', data.get('enabled', 1))
    val = str(int(raw))
    db = get_db()
    db.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('web_video_enabled',?)", (val,))
    db.commit()
    return jsonify(ok=True, web_video_enabled=int(val))


@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        phone = request.form.get('phone', '').strip()
        if not phone:
            return render_template('login.html', error='请输入手机号')

        # 频率限制
        if is_rate_limited(phone):
            return render_template('login.html', error='尝试次数过多，请5分钟后再试')
        record_attempt(phone)

        db = get_db()
        user = db.execute('SELECT * FROM users WHERE phone=? AND enabled=1',
                          (phone,)).fetchone()
        if not user:
            return render_template('login.html', error='该手机号未授权或已禁用')

        # 登录成功, 清除该手机号的失败记录
        _login_attempts.pop(phone, None)
        session.permanent = True
        session['phone'] = user['phone']
        session['name'] = user['name']
        session['role'] = user['role']
        db.execute('INSERT INTO login_log (phone,ip) VALUES (?,?)',
                   (phone, request.remote_addr))
        db.commit()
        return redirect(url_for('dashboard'))
    return render_template('login.html', error=None)


@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


# (dashboard 已改为 video_page, 见上方)


@app.route('/users')
@admin_required
def users_page():
    db = get_db()
    users = db.execute('SELECT * FROM users ORDER BY id').fetchall()
    return render_template('users.html', users=users, name=session.get('name'))


@app.route('/devices')
@admin_required
def devices_page():
    db = get_db()
    streams = db.execute('SELECT * FROM streams ORDER BY sort').fetchall()
    return render_template('devices.html', streams=streams, name=session.get('name'))


# ── HLS 代理 (白名单防 SSRF) ─────────────────────────────────
@app.route('/proxy/<path:stream_path>')
@login_required
def proxy_stream(stream_path):
    """
    代理内网 HLS 流。安全限制:
    - 必须登录
    - 只能代理数据库 streams 表中配置的地址
    - 路径必须精确匹配 (防止任意 SSRF)
    """
    target = 'http://' + stream_path
    if request.query_string:
        target += '?' + request.query_string.decode()

    parsed = urlparse(target)
    allowed = get_allowed_hosts()

    # 前缀匹配: 主机 + 路径前缀 必须在白名单中 (允许 m3u8 和 ts 分片)
    ok = False
    for netloc, path_prefix in allowed:
        if parsed.netloc == netloc and parsed.path.startswith(path_prefix):
            ok = True
            break
    if not ok:
        return Response('forbidden', status=403)

    try:
        resp = requests.get(target, stream=True, timeout=15,
                            headers={'User-Agent': 'Mozilla/5.0'})
        # 修正 Content-Type: m3u8 不带 charset, ts 用 video/mp2t
        ct = resp.headers.get('Content-Type', 'application/octet-stream')
        if '.m3u8' in target:
            ct = 'application/x-mpegURL'
        elif '.ts' in target:
            ct = 'video/mp2t'
        else:
            ct = ct.split(';')[0]  # 去掉 charset 等参数

        headers = {
            'Content-Type': ct,
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Access-Control-Allow-Origin': '*',
            'Pragma': 'no-cache',
        }
        return Response(stream_with_context(resp.iter_content(chunk_size=16384)),
                        status=resp.status_code, headers=headers)
    except requests.exceptions.ConnectionError:
        return Response('stream offline', status=502)
    except requests.exceptions.Timeout:
        return Response('stream timeout', status=504)
    except Exception:
        return Response('stream error', status=502)


# ── API ──────────────────────────────────────────────────────
@app.route('/api/streams')
@login_required
def api_streams():
    db = get_db()
    rows = db.execute('SELECT * FROM streams WHERE enabled=1 ORDER BY sort').fetchall()
    result = []
    for r in rows:
        d = dict(r)
        parsed = urlparse(d['url'])
        d['proxy_url'] = '/proxy/' + parsed.netloc + parsed.path
        result.append(d)
    return jsonify(result)


@app.route('/api/devices', methods=['POST'])
@admin_required
@csrf_protect
def api_add_device():
    name = request.form.get('name', '').strip()
    url = request.form.get('url', '').strip()
    sort = request.form.get('sort', '0')
    if not name or not url:
        return jsonify(ok=False, msg='名称和地址不能为空')
    if not url.startswith('http://') and not url.startswith('https://'):
        return jsonify(ok=False, msg='地址必须以 http:// 或 https:// 开头')
    db = get_db()
    db.execute('INSERT INTO streams (name,url,sort) VALUES (?,?,?)', (name, url, int(sort)))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/devices/<int:did>', methods=['PUT'])
@admin_required
@csrf_protect
def api_update_device(did):
    name = request.form.get('name', '').strip()
    url = request.form.get('url', '').strip()
    sort = request.form.get('sort', '0')
    enabled = request.form.get('enabled', '1')
    db = get_db()
    db.execute('UPDATE streams SET name=?, url=?, sort=?, enabled=? WHERE id=?',
               (name, url, int(sort), int(enabled), did))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/devices/<int:did>/toggle', methods=['PUT'])
@admin_required
@csrf_protect
def api_toggle_device(did):
    db = get_db()
    row = db.execute('SELECT enabled FROM streams WHERE id=?', (did,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='设备不存在')
    new_val = 0 if row['enabled'] else 1
    db.execute('UPDATE streams SET enabled=? WHERE id=?', (new_val, did))
    db.commit()
    return jsonify(ok=True, enabled=new_val)


@app.route('/api/devices/<int:did>', methods=['DELETE'])
@admin_required
@csrf_protect
def api_delete_device(did):
    db = get_db()
    db.execute('DELETE FROM streams WHERE id=?', (did,))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/users', methods=['POST'])
@admin_required
@csrf_protect
def api_add_user():
    phone = request.form.get('phone', '').strip()
    name = request.form.get('name', '').strip()
    role = request.form.get('role', 'user')
    if not phone or len(phone) != 11 or not phone.isdigit():
        return jsonify(ok=False, msg='手机号必须是11位数字')
    if role not in ('user', 'admin'):
        role = 'user'
    db = get_db()
    try:
        db.execute('INSERT INTO users (phone,name,role) VALUES (?,?,?)',
                   (phone, name, role))
        db.commit()
        return jsonify(ok=True)
    except sqlite3.IntegrityError:
        return jsonify(ok=False, msg='手机号已存在')


@app.route('/api/users/<int:uid>', methods=['PUT'])
@admin_required
@csrf_protect
def api_update_user(uid):
    role = request.form.get('role', 'user')
    if role not in ('user', 'admin'):
        role = 'user'
    db = get_db()
    db.execute('UPDATE users SET name=?,role=?,enabled=? WHERE id=?',
               (request.form.get('name', '')[:50], role,
                int(request.form.get('enabled', '1')), uid))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/users/<int:uid>/toggle', methods=['PUT'])
@admin_required
@csrf_protect
def api_toggle_user(uid):
    db = get_db()
    row = db.execute('SELECT enabled FROM users WHERE id=?', (uid,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='用户不存在')
    new_val = 0 if row['enabled'] else 1
    db.execute('UPDATE users SET enabled=? WHERE id=?', (new_val, uid))
    db.commit()
    return jsonify(ok=True, enabled=new_val)


@app.route('/api/users/<int:uid>', methods=['DELETE'])
@admin_required
@csrf_protect
def api_delete_user(uid):
    if session.get('phone'):
        db = get_db()
        user = db.execute('SELECT phone FROM users WHERE id=?', (uid,)).fetchone()
        if user and user['phone'] == session['phone']:
            return jsonify(ok=False, msg='不能删除自己')
        db.execute('DELETE FROM users WHERE id=?', (uid,))
        db.commit()
    return jsonify(ok=True)



# ════════════════════════════════════════════════════════════
#  Mobile API (JWT 认证, App 专用)
# ════════════════════════════════════════════════════════════

@app.route('/api/mobile/login', methods=['POST'])
def mobile_login():
    data = request.get_json(force=True, silent=True) or {}
    phone = (data.get('phone') or '').strip()
    if not phone:
        return jsonify(ok=False, msg='请输入手机号'), 400
    if is_rate_limited(phone):
        return jsonify(ok=False, msg='尝试次数过多，请5分钟后再试'), 429
    record_attempt(phone)
    db = get_db()
    user = db.execute('SELECT * FROM users WHERE phone=? AND enabled=1', (phone,)).fetchone()
    if not user:
        return jsonify(ok=False, msg='该手机号未授权或已禁用'), 401
    _login_attempts.pop(phone, None)
    token = jwt_encode({'phone': user['phone'], 'name': user['name'], 'role': user['role']}, app.secret_key)
    db.execute('INSERT INTO login_log (phone,ip) VALUES (?,?)', (phone, request.remote_addr))
    db.commit()
    return jsonify(ok=True, token=token, phone=user['phone'], name=user['name'], role=user['role'])


@app.route('/api/mobile/me')
@any_auth
def mobile_me():
    u = g.current_user
    return jsonify(ok=True, phone=u.get('phone'), name=u.get('name'), role=u.get('role'))


@app.route('/api/mobile/streams')
@any_auth
def mobile_streams():
    db = get_db()
    rows = db.execute('SELECT * FROM streams WHERE enabled=1 ORDER BY sort').fetchall()
    result = []
    for r in rows:
        d = dict(r)
        parsed = urlparse(d['url'])
        d['proxy_url'] = '/proxy/' + parsed.netloc + parsed.path
        result.append(d)
    return jsonify(result)


# ── Mobile 设备管理 ──
@app.route('/api/mobile/devices')
@any_admin
def mobile_devices():
    db = get_db()
    rows = db.execute('SELECT * FROM streams ORDER BY sort').fetchall()
    return jsonify([dict(r) for r in rows])


@app.route('/api/mobile/devices', methods=['POST'])
@any_admin
def mobile_add_device():
    data = request.get_json(force=True, silent=True) or {}
    name = (data.get('name') or '').strip()
    url = (data.get('url') or '').strip()
    sort = int(data.get('sort') or 0)
    if not name or not url:
        return jsonify(ok=False, msg='名称和地址不能为空'), 400
    db = get_db()
    db.execute('INSERT INTO streams (name,url,sort) VALUES (?,?,?)', (name, url, sort))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/mobile/devices/<int:did>', methods=['PUT'])
@any_admin
def mobile_update_device(did):
    data = request.get_json(force=True, silent=True) or {}
    db = get_db()
    db.execute('UPDATE streams SET name=?, url=?, sort=?, enabled=? WHERE id=?',
               (data.get('name',''), data.get('url',''), int(data.get('sort') or 0),
                int(data.get('enabled', 1)), did))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/mobile/devices/<int:did>/toggle', methods=['PUT'])
@any_admin
def mobile_toggle_device(did):
    db = get_db()
    row = db.execute('SELECT enabled FROM streams WHERE id=?', (did,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='设备不存在'), 404
    val = 0 if row['enabled'] else 1
    db.execute('UPDATE streams SET enabled=? WHERE id=?', (val, did))
    db.commit()
    return jsonify(ok=True, enabled=val)


@app.route('/api/mobile/devices/<int:did>', methods=['DELETE'])
@any_admin
def mobile_delete_device(did):
    db = get_db()
    db.execute('DELETE FROM streams WHERE id=?', (did,))
    db.commit()
    return jsonify(ok=True)


# ── Mobile 用户管理 ──
@app.route('/api/mobile/users')
@any_admin
def mobile_users():
    db = get_db()
    rows = db.execute('SELECT * FROM users ORDER BY id').fetchall()
    return jsonify([dict(r) for r in rows])


@app.route('/api/mobile/users', methods=['POST'])
@any_admin
def mobile_add_user():
    data = request.get_json(force=True, silent=True) or {}
    phone = (data.get('phone') or '').strip()
    name = (data.get('name') or '').strip()
    role = data.get('role', 'user')
    if not phone or len(phone) != 11 or not phone.isdigit():
        return jsonify(ok=False, msg='手机号必须是11位数字'), 400
    if role not in ('user', 'admin'):
        role = 'user'
    db = get_db()
    try:
        db.execute('INSERT INTO users (phone,name,role) VALUES (?,?,?)', (phone, name, role))
        db.commit()
        return jsonify(ok=True)
    except sqlite3.IntegrityError:
        return jsonify(ok=False, msg='手机号已存在'), 409


@app.route('/api/mobile/users/<int:uid>', methods=['PUT'])
@any_admin
def mobile_update_user(uid):
    data = request.get_json(force=True, silent=True) or {}
    role = data.get('role', 'user')
    if role not in ('user', 'admin'):
        role = 'user'
    db = get_db()
    db.execute('UPDATE users SET name=?, role=?, enabled=? WHERE id=?',
               (data.get('name','')[:50], role, int(data.get('enabled', 1)), uid))
    db.commit()
    return jsonify(ok=True)


@app.route('/api/mobile/users/<int:uid>/toggle', methods=['PUT'])
@any_admin
def mobile_toggle_user(uid):
    db = get_db()
    row = db.execute('SELECT enabled FROM users WHERE id=?', (uid,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='用户不存在'), 404
    val = 0 if row['enabled'] else 1
    db.execute('UPDATE users SET enabled=? WHERE id=?', (val, uid))
    db.commit()
    return jsonify(ok=True, enabled=val)


@app.route('/api/mobile/users/<int:uid>', methods=['DELETE'])
@any_admin
def mobile_delete_user(uid):
    u = g.current_user
    if u.get('phone'):
        db = get_db()
        row = db.execute('SELECT phone FROM users WHERE id=?', (uid,)).fetchone()
        if row and row['phone'] == u['phone']:
            return jsonify(ok=False, msg='不能删除自己'), 400
        db.execute('DELETE FROM users WHERE id=?', (uid,))
        db.commit()
    return jsonify(ok=True)

# ── 启动 ──────────────────────────────────────────────────────
if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
