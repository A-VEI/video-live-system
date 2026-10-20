"""方案 B：HLS 代理签名 URL（短时 token 进 query）。

播放器无法给 HLS 分片注入 Authorization 头，因此 /proxy/ 不走 Basic Auth，
改为校验 exp+sig；m3u8 在代理层改写，给每个分片URL 续上同一 token。
签名范围 = 主机名（配合 streams 表主机白名单防 SSRF）。
"""
from __future__ import annotations

import hmac
import hashlib
import re
import time
from urllib.parse import urljoin, urlparse, urlunparse

DEFAULT_TTL = 7200  # 2h，覆盖常见值班时段；m3u8 每次拉取都会续签


def _secret_bytes(secret) -> bytes:
    return secret if isinstance(secret, bytes) else str(secret).encode()


def _sign(secret, host: str, exp: int) -> str:
    msg = f"{host}|{exp}".encode()
    return hmac.new(_secret_bytes(secret), msg, hashlib.sha256).hexdigest()[:32]


def make_token(secret, host: str, ttl: int = DEFAULT_TTL) -> dict:
    """返回 {'exp': int, 'sig': str}，可拼成 ?exp=&sig="""
    exp = int(time.time()) + int(ttl)
    return {"exp": exp, "sig": _sign(secret, host, exp)}


def make_query(secret, host: str, ttl: int = DEFAULT_TTL) -> str:
    t = make_token(secret, host, ttl)
    return f"exp={t['exp']}&sig={t['sig']}"


def verify_token(secret, host: str, exp, sig) -> bool:
    if not exp or not sig:
        return False
    try:
        exp_i = int(exp)
    except (TypeError, ValueError):
        return False
    if exp_i < int(time.time()):
        return False
    expected = _sign(secret, host, exp_i)
    return hmac.compare_digest(str(sig), expected)


def stream_scope(stream_url: str) -> tuple[str, str]:
    """由源站 URL 得到 (host, path_prefix)。"""
    parsed = urlparse(stream_url)
    path = parsed.path or "/"
    prefix = path.rsplit("/", 1)[0] + "/" if "/" in path else "/"
    return parsed.netloc, prefix


def signed_proxy_path(secret, stream_url: str, ttl: int = DEFAULT_TTL) -> str:
    """生成可直接给播放器的代理路径：/proxy/host/path?exp=&sig="""
    parsed = urlparse(stream_url)
    host = parsed.netloc
    path = parsed.path or "/"
    q = make_query(secret, host, ttl)
    return f"/proxy/{host}{path}?{q}"


_URI_ATTR = re.compile(r'URI="([^"]+)"')
_BARE_URI_LINE = re.compile(r"^(?!#)(\S+)\s*$")


def rewrite_m3u8(content: str, host: str, dir_path: str, query: str) -> str:
    """把 m3u8 里的分片/子清单 URI 改写成带签名的 /proxy/ 绝对路径。

    dir_path: 当前 m3u8 所在目录，如 /live/0/
    query:    exp=...&sig=...
    """
    base = f"http://{host}{dir_path}"
    out_lines = []

    def rewrite_one(uri: str) -> str:
        uri = uri.strip()
        if not uri:
            return uri
        if uri.startswith("/"):
            abs_url = f"http://{host}{uri}"
        elif uri.startswith("http://") or uri.startswith("https://"):
            abs_url = uri
        else:
            abs_url = urljoin(base, uri)
        parsed = urlparse(abs_url)
        # 只代理到白名单主机；源站绝对地址也收编进 /proxy/
        target_host = parsed.netloc or host
        target_path = parsed.path or "/"
        return f"/proxy/{target_host}{target_path}?{query}"

    for raw in content.splitlines():
        line = raw.rstrip("\r")
        if not line:
            out_lines.append(line)
            continue
        if line.lstrip().startswith("#"):
            if "URI=" in line:
                line = _URI_ATTR.sub(lambda m: f'URI="{rewrite_one(m.group(1))}"', line)
            out_lines.append(line)
            continue
        # 普通 URI 行（分片 / 子播放列表）
        m = _BARE_URI_LINE.match(line)
        if m:
            out_lines.append(rewrite_one(m.group(1)))
        else:
            out_lines.append(line)

    text = "\n".join(out_lines)
    if content.endswith("\n"):
        text += "\n"
    return text


def strip_token_args(query_string: str) -> str:
    """从 query_string 移除 exp/sig，剩下的转发给源站。"""
    if not query_string:
        return ""
    if isinstance(query_string, bytes):
        query_string = query_string.decode("utf-8", "replace")
    parts = []
    for kv in query_string.split("&"):
        if not kv:
            continue
        k = kv.split("=", 1)[0].lower()
        if k in ("exp", "sig", "token"):
            continue
        parts.append(kv)
    return "&".join(parts)
