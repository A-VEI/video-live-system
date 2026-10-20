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

from stream_token import (
    make_token, make_query, verify_token, signed_proxy_path,
    rewrite_m3u8, strip_token_args,
)
from security import (
    hash_password, verify_password, password_policy_error, is_valid_phone,
    generate_password, is_disallowed_ip, validate_proxy_target,
    check_download_code, file_sha256, apply_security_headers, page_csp,
)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__)
app.permanent_session_lifetime = timedelta(hours=12)

DB_PATH = os.path.join(BASE_DIR, 'video.db')


def _load_secret() -> bytes:
    """持久化 secret：重启后 JWT / 签名 URL 不失效。"""
    secret_path = os.path.join(BASE_DIR, 'secret.key')
    if os.path.exists(secret_path):
        with open(secret_path, 'rb') as f:
            data = f.read().strip()
        if data:
            return data
    secret = os.urandom(32)
    with open(secret_path, 'wb') as f:
        f.write(secret)
    try:
        os.chmod(secret_path, 0o600)
    except OSError:
        pass
    return secret


app.secret_key = _load_secret()


def _load_app_version() -> str:
    """版本号单一来源：VERSION 文件（与 App pubspec.version 对齐）。"""
    try:
        with open(os.path.join(BASE_DIR, 'VERSION'), encoding='utf-8') as f:
            return f.read().strip() or '0.0.0'
    except OSError:
        return '0.0.0'

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
            password_hash TEXT DEFAULT '',
            must_change_password INTEGER DEFAULT 0,
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
        CREATE TABLE IF NOT EXISTS audit_log (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            actor    TEXT,
            action   TEXT,
            detail   TEXT,
            ip       TEXT,
            time     TEXT DEFAULT (datetime('now','localtime'))
        );
    ''')
    # 旧库迁移：补 password_hash / must_change_password
    cols = {r[1] for r in db.execute('PRAGMA table_info(users)').fetchall()}
    if 'password_hash' not in cols:
        db.execute("ALTER TABLE users ADD COLUMN password_hash TEXT DEFAULT ''")
    if 'must_change_password' not in cols:
        db.execute(
            "ALTER TABLE users ADD COLUMN must_change_password INTEGER DEFAULT 0")

    # 默认设置（下载口令可轮换，存在 settings）
    def _ensure_setting(key, value):
        if db.execute(
                "SELECT COUNT(*) FROM settings WHERE key=?", (key,)
        ).fetchone()[0] == 0:
            db.execute("INSERT INTO settings (key,value) VALUES (?,?)",
                       (key, value))

    _ensure_setting('web_video_enabled', '1')
    _ensure_setting('download_code', '8119')
    _ensure_setting('apk_sha256', '')

    if db.execute('SELECT COUNT(*) FROM streams').fetchone()[0] == 0:
        for s in DEFAULT_STREAMS:
            db.execute('INSERT INTO streams (name,url,sort) VALUES (?,?,?)',
                       (s['name'], s['url'], s['sort']))

    if db.execute('SELECT COUNT(*) FROM users').fetchone()[0] == 0:
        # 初始口令随机生成并强制改密；不再「口令=手机号」
        init_pw = generate_password(12)
        for phone, name, role in (
            ('13800138000', '管理员', 'admin'),
            ('13900139000', '张三', 'user'),
            ('13700137000', '李四', 'user'),
        ):
            db.execute(
                'INSERT INTO users (phone,name,role,password_hash,must_change_password) '
                'VALUES (?,?,?,?,1)',
                (phone, name, role, hash_password(init_pw)))
        # 写入首次启动说明（只写一次）
        notice = os.path.join(BASE_DIR, 'INITIAL_CREDENTIALS.txt')
        if not os.path.exists(notice):
            with open(notice, 'w', encoding='utf-8') as f:
                f.write(
                    '初始账号（请登录后立即修改口令）:\n'
                    '  13800138000  初始口令: %s\n'
                    '  13900139000  初始口令: %s\n'
                    '  13700137000  初始口令: %s\n'
                    % (init_pw, init_pw, init_pw))
            try:
                os.chmod(notice, 0o600)
            except OSError:
                pass
    else:
        # 旧用户：口令仍等于手机号的，强制改密（迁移标记）
        rows = db.execute('SELECT id, phone, password_hash FROM users').fetchall()
        for row in rows:
            phone = row[1]
            ph = row[2] or ''
            # 未设口令的旧账号：先置为「必须改密」+ 临时口令=手机号哈希（仅迁移兼容）
            if not ph:
                db.execute(
                    'UPDATE users SET password_hash=?, must_change_password=1 WHERE id=?',
                    (hash_password(phone), row[0]))

    db.commit()
    db.close()


def _audit(actor, action, detail=''):
    try:
        db = get_db()
        db.execute(
            'INSERT INTO audit_log (actor,action,detail,ip) VALUES (?,?,?,?)',
            (actor or '-', action, detail[:500], request.remote_addr))
        db.commit()
    except Exception:
        pass


def _get_setting(key, default='1'):
    try:
        db = get_db()
        row = db.execute('SELECT value FROM settings WHERE key=?',
                         (key,)).fetchone()
        return row['value'] if row else default
    except Exception:
        return default


def _set_setting(key, value):
    db = get_db()
    db.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)',
               (key, str(value)))
    db.commit()


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
            return redirect(url_for('video_page'))
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
    """口令验证后下载 APK（口令存 settings，可轮换）"""
    code = request.args.get('code', '')
    expected = _get_setting('download_code', '')
    if not check_download_code(code, expected):
        _audit('-', 'apk_download_denied', 'bad code')
        return '口令错误', 403
    apk_path = os.path.join(app.root_path, 'static', 'app', 'video-live.apk')
    if not os.path.exists(apk_path):
        return 'APK 文件不存在', 404
    _audit('-', 'apk_download', request.args.get('code', '')[:0])
    return send_file(apk_path, as_attachment=True, download_name='video-live.apk')


@app.route('/video')
@login_required
def video_page():
    """视频页 (受 web_video_enabled 控制)"""
    if _get_setting('web_video_enabled') != '1':
        return render_template('video_disabled.html')
    db = get_db()
    rows = db.execute('SELECT * FROM streams WHERE enabled=1 ORDER BY sort').fetchall()
    streams = []
    for r in rows:
        d = dict(r)
        d['proxy_url'] = _build_signed_proxy_url(d['url'])
        streams.append(d)
    return render_template('dashboard.html', streams=streams,
                           name=session.get('name'), role=session.get('role'))


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
        phone = (request.form.get('phone') or '').strip()
        password = request.form.get('password') or ''
        if not phone or not password:
            return render_template('login.html', error='请输入手机号和口令')

        # 频率限制
        if is_rate_limited(phone):
            _audit(phone, 'login_ratelimited')
            return render_template('login.html', error='尝试次数过多，请5分钟后再试')
        record_attempt(phone)

        db = get_db()
        user = db.execute('SELECT * FROM users WHERE phone=? AND enabled=1',
                          (phone,)).fetchone()
        if not user or not verify_password(password, user['password_hash']):
            _audit(phone, 'login_failed', request.remote_addr)
            return render_template('login.html', error='手机号或口令错误')

        # 登录成功, 清除该手机号的失败记录
        _login_attempts.pop(phone, None)
        session.permanent = True
        session['phone'] = user['phone']
        session['name'] = user['name']
        session['role'] = user['role']
        db.execute('INSERT INTO login_log (phone,ip) VALUES (?,?)',
                   (phone, request.remote_addr))
        db.commit()
        _audit(phone, 'login_ok')
        if user['must_change_password']:
            return redirect('/change-password')
        return redirect(url_for('video_page'))
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


# ── HLS 代理（方案 B：签名 URL，播放器无需带 Header）─────────
def _proxy_path_host(stream_path: str) -> str:
    return (stream_path.split('/', 1) or [''])[0]


def _build_signed_proxy_url(stream_url: str, ttl: int = 7200) -> str:
    return signed_proxy_path(app.secret_key, stream_url, ttl=ttl)


def _proxy_allowlist():
    """返回 (hosts set, path prefixes list)。"""
    allowed = get_allowed_hosts()
    hosts = {netloc for netloc, _ in allowed}
    prefixes = [prefix for _, prefix in allowed]
    return hosts, prefixes


@app.route('/proxy/<path:stream_path>')
def proxy_stream(stream_path):
    """代理内网 HLS。安全：
    - 主机必须在 streams 白名单（防 SSRF）
    - 禁止环回/链路本地/元数据地址
    - 路径必须落在配置流的目录前缀下
    - 必须携带合法 exp+sig（方案 B，短时签名）
    - m3u8 代理时改写分片 URI，续签进 query
    """
    host = _proxy_path_host(stream_path)
    exp = request.args.get('exp', '')
    sig = request.args.get('sig', '')
    if not verify_token(app.secret_key, host, exp, sig):
        _audit('-', 'proxy_bad_token', stream_path[:80])
        return Response('forbidden: bad stream token', status=403)

    allowed_hosts, allowed_prefixes = _proxy_allowlist()
    ok, reason = validate_proxy_target(stream_path, allowed_hosts, allowed_prefixes)
    if not ok:
        _audit('-', 'proxy_ssrf_blocked', f'{reason} {stream_path[:80]}')
        return Response(f'forbidden: {reason}', status=403)

    rest = stream_path[len(host):] if stream_path.startswith(host) else '/' + stream_path.split('/', 1)[-1]
    if not rest.startswith('/'):
        rest = '/' + rest
    upstream_qs = strip_token_args(request.query_string.decode('utf-8', 'replace'))
    target = f'http://{host}{rest}'
    if upstream_qs:
        target += '?' + upstream_qs

    is_m3u8 = '.m3u8' in rest.lower()
    is_ts = rest.lower().endswith('.ts') or '.ts?' in rest.lower()

    try:
        if is_m3u8:
            resp = requests.get(target, timeout=15, headers={'User-Agent': 'Mozilla/5.0'})
            body = resp.text
            if resp.status_code == 200 and body:
                dir_path = rest.rsplit('/', 1)[0] + '/'
                token_q = f'exp={exp}&sig={sig}' if exp and sig else make_query(app.secret_key, host)
                body = rewrite_m3u8(body, host, dir_path, token_q)
            headers = {
                'Content-Type': 'application/x-mpegURL',
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Access-Control-Allow-Origin': '*',
                'Pragma': 'no-cache',
            }
            return Response(body, status=resp.status_code, headers=headers)

        # ts/分片：整段缓冲后返回，避免 2s 边界流式卡顿
        resp = requests.get(target, timeout=15, headers={'User-Agent': 'Mozilla/5.0'})
        if is_ts:
            body = resp.content
            headers = {
                'Content-Type': 'video/mp2t',
                # 直播分片不可长缓存，但短缓存可抹平 2s 边界抖动
                'Cache-Control': 'public, max-age=2',
                'Access-Control-Allow-Origin': '*',
                'Content-Length': str(len(body)),
            }
            return Response(body, status=resp.status_code, headers=headers)

        ct = resp.headers.get('Content-Type', 'application/octet-stream')
        body = resp.content
        headers = {
            'Content-Type': ct.split(';')[0],
            'Cache-Control': 'public, max-age=2',
            'Access-Control-Allow-Origin': '*',
            'Content-Length': str(len(body)),
        }
        return Response(body, status=resp.status_code, headers=headers)
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
        d['proxy_url'] = _build_signed_proxy_url(d['url'])
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
    password = request.form.get('password') or ''
    if not is_valid_phone(phone):
        return jsonify(ok=False, msg='手机号必须是11位数字')
    if role not in ('user', 'admin'):
        role = 'user'
    err = password_policy_error(password, phone) if password else None
    if password and err:
        return jsonify(ok=False, msg=err)
    # 未提供口令则生成随机初始口令
    temp_pw = password or generate_password(12)
    db = get_db()
    try:
        db.execute(
            'INSERT INTO users (phone,name,role,password_hash,must_change_password) '
            'VALUES (?,?,?,?,?)',
            (phone, name, role, hash_password(temp_pw), 1 if not password else 0))
        db.commit()
        _audit(session.get('phone'), 'add_user', phone)
        out = {'ok': True}
        if not password:
            out['temp_password'] = temp_pw  # 仅创建时返回一次
        return jsonify(**out)
    except sqlite3.IntegrityError:
        return jsonify(ok=False, msg='手机号已存在')


@app.route('/api/users/<int:uid>', methods=['PUT'])
@admin_required
@csrf_protect
def api_update_user(uid):
    role = request.form.get('role', 'user')
    if role not in ('user', 'admin'):
        role = 'user'
    name = request.form.get('name', '')[:50]
    enabled = int(request.form.get('enabled', '1'))
    new_password = request.form.get('password', '')
    db = get_db()
    if new_password:
        err = password_policy_error(new_password)
        if err:
            return jsonify(ok=False, msg=err)
        row = db.execute('SELECT phone FROM users WHERE id=?', (uid,)).fetchone()
        if not row:
            return jsonify(ok=False, msg='用户不存在')
        err = password_policy_error(new_password, row['phone'])
        if err:
            return jsonify(ok=False, msg=err)
        db.execute(
            'UPDATE users SET name=?,role=?,enabled=?,password_hash=?,must_change_password=1 '
            'WHERE id=?',
            (name, role, enabled, hash_password(new_password), uid))
    else:
        db.execute('UPDATE users SET name=?,role=?,enabled=? WHERE id=?',
                   (name, role, enabled, uid))
    db.commit()
    _audit(session.get('phone'), 'update_user', str(uid))
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




# ── 自动更新 ──
import json as _json

APP_VERSION = _load_app_version()  # 读 VERSION 文件，勿在此处写死


def _apk_path():
    return os.path.join(app.root_path, 'static', 'app', 'video-live.apk')


@app.route('/api/app/version')
def app_version():
    """返回最新版本信息 + APK SHA256（客户端校验完整性）"""
    apk = _apk_path()
    size = os.path.getsize(apk) if os.path.exists(apk) else 0
    sha = file_sha256(apk)
    if sha:
        _set_setting('apk_sha256', sha)
    return jsonify(
        version=APP_VERSION,
        update_url='/api/app/download',
        size=size,
        sha256=sha or '',
        notes='P3 安全加固：独立口令 / SSRF 收紧 / APK 校验'
    )


@app.route('/api/app/download')
def app_download():
    """下载最新 APK。App 自动更新免口令；页面下载走 /download/apk?code= """
    apk = _apk_path()
    if not os.path.exists(apk):
        return 'APK not found', 404
    return send_file(apk, as_attachment=True, download_name='video-live.apk')


# ── 安全响应头 ───────────────────────────────────────────────
@app.after_request
def _security_headers(resp):
    apply_security_headers(resp.headers)
    if request.path.startswith('/api/') or request.path.startswith('/proxy/'):
        resp.headers.setdefault('Cache-Control', 'no-store')
    elif request.path in ('/', '/login', '/video', '/users', '/devices',
                          '/change-password'):
        resp.headers['Content-Security-Policy'] = page_csp()
    return resp


# ── 改密（Web）───────────────────────────────────────────────
@app.route('/change-password', methods=['GET', 'POST'])
@login_required
def change_password_page():
    phone = session.get('phone')
    if request.method == 'POST':
        old_pw = request.form.get('old_password') or ''
        new_pw = request.form.get('new_password') or ''
        confirm = request.form.get('confirm_password') or ''
        if new_pw != confirm:
            return render_template('change_password.html',
                                   error='两次输入的新口令不一致')
        db = get_db()
        user = db.execute('SELECT * FROM users WHERE phone=?',
                          (phone,)).fetchone()
        if not user or not verify_password(old_pw, user['password_hash']):
            _audit(phone, 'web_change_pw_bad_old')
            return render_template('change_password.html', error='原口令错误')
        err = password_policy_error(new_pw, phone)
        if err:
            return render_template('change_password.html', error=err)
        db.execute(
            'UPDATE users SET password_hash=?, must_change_password=0 WHERE phone=?',
            (hash_password(new_pw), phone))
        db.commit()
        _audit(phone, 'web_change_password')
        return redirect(url_for('video_page'))
    return render_template('change_password.html', error=None,
                           must=True if _user_must_change(phone) else False)


def _user_must_change(phone):
    try:
        db = get_db()
        row = db.execute(
            'SELECT must_change_password FROM users WHERE phone=?',
            (phone,)).fetchone()
        return bool(row and row['must_change_password'])
    except Exception:
        return False


@app.route('/api/admin/download-code', methods=['PUT'])
@any_admin
@csrf_protect
def api_rotate_download_code():
    data = request.get_json(force=True, silent=True) or request.form.to_dict() or {}
    new_code = (data.get('code') or '').strip()
    if not new_code or len(new_code) < 4 or len(new_code) > 32:
        return jsonify(ok=False, msg='口令长度须为 4–32 位'), 400
    _set_setting('download_code', new_code)
    _audit(g.current_user.get('phone'), 'rotate_download_code')
    return jsonify(ok=True)


@app.route('/api/admin/audit')
@any_admin
def api_audit_log():
    db = get_db()
    rows = db.execute(
        'SELECT * FROM audit_log ORDER BY id DESC LIMIT 200').fetchall()
    return jsonify([dict(r) for r in rows])

# ════════════════════════════════════════════════════════════
#  Mobile API (JWT 认证, App 专用)
# ════════════════════════════════════════════════════════════

@app.route('/api/mobile/login', methods=['POST'])
def mobile_login():
    data = request.get_json(force=True, silent=True) or {}
    phone = (data.get('phone') or '').strip()
    password = data.get('password') or ''
    if not phone or not password:
        return jsonify(ok=False, msg='请输入手机号和口令'), 400
    if is_rate_limited(phone):
        return jsonify(ok=False, msg='尝试次数过多，请5分钟后再试'), 429
    record_attempt(phone)
    db = get_db()
    user = db.execute('SELECT * FROM users WHERE phone=? AND enabled=1',
                      (phone,)).fetchone()
    if not user or not verify_password(password, user['password_hash']):
        _audit(phone, 'mobile_login_failed')
        return jsonify(ok=False, msg='手机号或口令错误'), 401
    _login_attempts.pop(phone, None)
    token = jwt_encode(
        {'phone': user['phone'], 'name': user['name'], 'role': user['role']},
        app.secret_key)
    db.execute('INSERT INTO login_log (phone,ip) VALUES (?,?)',
               (phone, request.remote_addr))
    db.commit()
    _audit(phone, 'mobile_login_ok')
    return jsonify(
        ok=True, token=token, phone=user['phone'], name=user['name'],
        role=user['role'],
        must_change_password=bool(user['must_change_password']))


@app.route('/api/mobile/me')
@any_auth
def mobile_me():
    u = g.current_user
    db = get_db()
    row = db.execute(
        'SELECT phone,name,role,must_change_password FROM users WHERE phone=?',
        (u.get('phone'),)).fetchone()
    if not row:
        return jsonify(ok=False, msg='用户不存在'), 404
    return jsonify(
        ok=True, phone=row['phone'], name=row['name'], role=row['role'],
        must_change_password=bool(row['must_change_password']))


@app.route('/api/mobile/change-password', methods=['POST'])
@any_auth
def mobile_change_password():
    data = request.get_json(force=True, silent=True) or {}
    old_pw = data.get('old_password') or ''
    new_pw = data.get('new_password') or ''
    phone = g.current_user.get('phone')
    db = get_db()
    user = db.execute('SELECT * FROM users WHERE phone=?', (phone,)).fetchone()
    if not user:
        return jsonify(ok=False, msg='用户不存在'), 404
    if not verify_password(old_pw, user['password_hash']):
        _audit(phone, 'change_pw_bad_old')
        return jsonify(ok=False, msg='原口令错误'), 403
    err = password_policy_error(new_pw, phone)
    if err:
        return jsonify(ok=False, msg=err), 400
    db.execute(
        'UPDATE users SET password_hash=?, must_change_password=0 WHERE phone=?',
        (hash_password(new_pw), phone))
    db.commit()
    _audit(phone, 'change_password')
    return jsonify(ok=True)


@app.route('/api/mobile/streams')
@any_auth
def mobile_streams():
    db = get_db()
    rows = db.execute('SELECT * FROM streams WHERE enabled=1 ORDER BY sort').fetchall()
    result = []
    for r in rows:
        d = dict(r)
        d['proxy_url'] = _build_signed_proxy_url(d['url'])
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
    password = data.get('password') or ''
    if not is_valid_phone(phone):
        return jsonify(ok=False, msg='手机号必须是11位数字'), 400
    if role not in ('user', 'admin'):
        role = 'user'
    if password:
        err = password_policy_error(password, phone)
        if err:
            return jsonify(ok=False, msg=err), 400
    temp_pw = password or generate_password(12)
    db = get_db()
    try:
        db.execute(
            'INSERT INTO users (phone,name,role,password_hash,must_change_password) '
            'VALUES (?,?,?,?,?)',
            (phone, name, role, hash_password(temp_pw), 1 if not password else 0))
        db.commit()
        _audit(g.current_user.get('phone'), 'mobile_add_user', phone)
        out = {'ok': True}
        if not password:
            out['temp_password'] = temp_pw
        return jsonify(**out)
    except sqlite3.IntegrityError:
        return jsonify(ok=False, msg='手机号已存在'), 409


@app.route('/api/mobile/users/<int:uid>', methods=['PUT'])
@any_admin
def mobile_update_user(uid):
    data = request.get_json(force=True, silent=True) or {}
    role = data.get('role', 'user')
    if role not in ('user', 'admin'):
        role = 'user'
    name = (data.get('name') or '')[:50]
    enabled = int(data.get('enabled', 1))
    new_password = data.get('password') or ''
    db = get_db()
    row = db.execute('SELECT phone FROM users WHERE id=?', (uid,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='用户不存在'), 404
    if new_password:
        err = password_policy_error(new_password, row['phone'])
        if err:
            return jsonify(ok=False, msg=err), 400
        db.execute(
            'UPDATE users SET name=?, role=?, enabled=?, password_hash=?, '
            'must_change_password=1 WHERE id=?',
            (name, role, enabled, hash_password(new_password), uid))
    else:
        db.execute('UPDATE users SET name=?, role=?, enabled=? WHERE id=?',
                   (name, role, enabled, uid))
    db.commit()
    _audit(g.current_user.get('phone'), 'mobile_update_user', str(uid))
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
    db = get_db()
    row = db.execute('SELECT phone FROM users WHERE id=?', (uid,)).fetchone()
    if not row:
        return jsonify(ok=False, msg='用户不存在'), 404
    if u.get('phone') and row['phone'] == u.get('phone'):
        return jsonify(ok=False, msg='不能删除自己'), 400
    db.execute('DELETE FROM users WHERE id=?', (uid,))
    db.commit()
    return jsonify(ok=True)

# ── 启动 ──────────────────────────────────────────────────────
if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('PORT', '8120'))
    app.run(host='0.0.0.0', port=port, debug=False, threaded=True)
