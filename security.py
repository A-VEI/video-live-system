"""P3 安全组件：口令哈希 / 策略 / SSRF 校验 / APK 指纹 / 响应头。"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import os
import re
import secrets
from urllib.parse import urlparse

# ── 口令 ──────────────────────────────────────────────────────
# pbkdf2_hmac 标准库，避免 bcrypt 原生依赖
_PBKDF2_ITERS = 240_000
_PHONE_RE = re.compile(r"^1\d{10}$")
_MIN_PW_LEN = 8


def hash_password(password: str, salt: bytes | None = None) -> str:
    if salt is None:
        salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, _PBKDF2_ITERS
    )
    return f"pbkdf2_sha256${_PBKDF2_ITERS}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored:
        return False
    try:
        algo, iters_s, salt_h, dk_h = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        iters = int(iters_s)
        salt = bytes.fromhex(salt_h)
        expected = bytes.fromhex(dk_h)
    except (ValueError, TypeError):
        return False
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iters
    )
    return hmac.compare_digest(dk, expected)


def password_policy_error(password: str, phone: str = "") -> str | None:
    """返回 None 表示通过；否则返回中文错误。"""
    if not password or len(password) < _MIN_PW_LEN:
        return f"口令至少 {_MIN_PW_LEN} 位"
    if len(password) > 128:
        return "口令过长"
    if phone and password == phone:
        return "口令不能与手机号相同"
    if password.lower() in ("password", "12345678", "admin123", "88888888"):
        return "口令过于简单"
    # 至少两类字符
    classes = sum(
        [
            bool(re.search(r"[a-z]", password)),
            bool(re.search(r"[A-Z]", password)),
            bool(re.search(r"\d", password)),
            bool(re.search(r"[^A-Za-z0-9]", password)),
        ]
    )
    if classes < 2:
        return "口令需至少包含字母、数字或符号中的两类"
    return None


def is_valid_phone(phone: str) -> bool:
    return bool(phone and _PHONE_RE.match(phone))


def generate_password(length: int = 12) -> str:
    """生成易转达的强口令（去掉了易混淆字符）。"""
    alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


# ── SSRF / 拉流目标校验 ─────────────────────────────────────
# 禁止代理到环回/链路本地/云元数据/组播/保留地址；内网 10/172.16/192.168 允许
_BLOCKED_NETWORKS = [
    ipaddress.ip_network(n)
    for n in (
        "0.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",   # 链路本地 + 云元数据 169.254.169.254
        "224.0.0.0/4",
        "240.0.0.0/4",
        "::1/128",
        "fe80::/10",
        "ff00::/8",
    )
]


def is_disallowed_ip(host_or_ip: str) -> bool:
    """True = 拒绝。hostname 非 IP 时不做 DNS（由运维保证源站为内网 IP）。"""
    # 仅测试逃生口：ALLOW_LOOPBACK_PROXY=1 时允许 127.0.0.1（smoke_test 本地假源站）
    if os.environ.get('ALLOW_LOOPBACK_PROXY') == '1':
        host = host_or_ip.split(":")[0].strip("[]")
        try:
            ip = ipaddress.ip_address(host)
            if ip.is_loopback:
                return False
        except ValueError:
            pass
    host = host_or_ip.split(":")[0].strip("[]")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        # 非字面 IP：禁止明显本机名
        lowered = host.lower()
        if lowered in ("localhost", "localhost.localdomain") or lowered.endswith(
            ".local"
        ):
            return True
        return False
    return any(ip in net for net in _BLOCKED_NETWORKS)


def path_prefix_allowed(request_path: str, allowed_prefixes: list[str]) -> bool:
    """请求路径必须落在某条配置流的目录前缀下。"""
    if not allowed_prefixes:
        return False
    p = request_path if request_path.startswith("/") else "/" + request_path
    for prefix in allowed_prefixes:
        if not prefix.startswith("/"):
            prefix = "/" + prefix
        if not prefix.endswith("/"):
            prefix += "/"
        if p.startswith(prefix) or p == prefix.rstrip("/"):
            return True
    return False


def validate_proxy_target(stream_path: str, allowed_netlocs: set[str],
                          allowed_prefixes: list[str]) -> tuple[bool, str]:
    """stream_path 形如 'host:port/live/0/hls.m3u8'（/proxy/ 之后的部分）。"""
    if "/" not in stream_path:
        return False, "bad path"
    netloc, rest = stream_path.split("/", 1)
    request_path = "/" + rest
    if netloc not in allowed_netlocs:
        return False, "host not allowed"
    if is_disallowed_ip(netloc):
        return False, "blocked address"
    if not path_prefix_allowed(request_path, allowed_prefixes):
        return False, "path prefix not allowed"
    return True, "ok"


# ── 下载口令 ─────────────────────────────────────────────────
def check_download_code(provided: str, expected: str | None) -> bool:
    if not expected:
        return False
    return hmac.compare_digest(str(provided or ""), str(expected))


# ── APK 指纹 ─────────────────────────────────────────────────
def file_sha256(path: str) -> str | None:
    if not path or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


# ── HTTP 安全响应头 ──────────────────────────────────────────
def apply_security_headers(headers) -> None:
    headers["X-Content-Type-Options"] = "nosniff"
    headers["X-Frame-Options"] = "SAMEORIGIN"
    headers["Referrer-Policy"] = "no-referrer"
    headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    # API/代理禁用缓存由各路由自行设置；此处加通用 CSP（页面用）
    # 注意：hls 播放需要 connect-src 到同源 /proxy/


def page_csp() -> str:
    return (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; "
        "media-src 'self' blob:; "
        "connect-src 'self'; "
        "frame-ancestors 'self'"
    )
