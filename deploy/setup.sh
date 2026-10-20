#!/bin/bash
# 统一部署：Flask(业务/API/签名代理) + Nginx(HTTP 静态/反代)
# 明确采用 HTTP，不启用 TLS/HTTPS。
# 用法: bash deploy/setup.sh
# 可选环境变量:
#   LISTEN=8119   PORT_API=8120
set -euo pipefail

APP_ROOT=/opt/video-system
PORT_API=${PORT_API:-8120}
LISTEN=${LISTEN:-8119}

mkdir -p "$APP_ROOT"/{web,static/app,data,logs}

# ── 1. Python 依赖 ──
python3 -m pip install -r "$(dirname "$0")/../requirements.txt"

# ── 2. 同步代码 ──
SRC="$(cd "$(dirname "$0")/.." && pwd)"
rsync -a --exclude 'mobile-app' --exclude 'docs' --exclude '.git' \
  --exclude 'video.db' --exclude 'secret.key' --exclude 'INITIAL_CREDENTIALS.txt' \
  "$SRC/" "$APP_ROOT/"

# ── 3. 首次初始化 secret / DB ──
cd "$APP_ROOT"
if [ ! -f secret.key ]; then
  python3 -c "import os; open('secret.key','wb').write(os.urandom(32))"
  chmod 600 secret.key
fi
python3 -c "from app import init_db; init_db()"
if [ -f INITIAL_CREDENTIALS.txt ]; then
  chmod 600 INITIAL_CREDENTIALS.txt
  echo "!! 首次账号写在 $APP_ROOT/INITIAL_CREDENTIALS.txt，请登录后立即改密并删除该文件"
fi

# ── 4. systemd ──
cat > /etc/systemd/system/video-app.service << EOF
[Unit]
Description=Video Live Flask
After=network.target

[Service]
WorkingDirectory=$APP_ROOT
Environment=PORT=$PORT_API
ExecStart=/usr/bin/python3 $APP_ROOT/app.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now video-app

# ── 5. Nginx (HTTP only) ──
cat > /etc/nginx/conf.d/video-live.conf << EOF
map \$arg_code \$valid_code {
    "8119"  1;
    default 0;
}

upstream video_flask {
    server 127.0.0.1:$PORT_API;
    keepalive 16;
}

server {
    listen $LISTEN;
    server_name _;
    client_max_body_size 20m;

    # 通用安全头（HTTP 部署，不发 HSTS）
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    # 下载页（免登录）
    location = / {
        auth_basic off;
        root $APP_ROOT/web;
        try_files /index.html =404;
    }

    # APK 下载（口令存 settings，可轮换）
    location = /download/apk {
        auth_basic off;
        proxy_pass http://video_flask;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # API / 签名 HLS 代理 → Flask（方案 B: query 校验 exp+sig）
    location /api/ {
        auth_basic off;
        proxy_pass http://video_flask;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
    }

    location /proxy/ {
        auth_basic off;
        proxy_pass http://video_flask;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_read_timeout 60s;
        proxy_set_header Connection "";
        add_header Access-Control-Allow-Origin * always;
    }

    # Web 管理页
    location / {
        proxy_pass http://video_flask;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
    }
}
EOF

nginx -t
systemctl reload nginx

echo "=== smoke ==="
curl -s -o /dev/null -w 'version: %{http_code}\n' "http://127.0.0.1:$PORT_API/api/app/version"
curl -s "http://127.0.0.1:$PORT_API/api/app/version" || true
echo
curl -s -o /dev/null -w 'proxy no token: %{http_code}\n' \
  "http://127.0.0.1:$PORT_API/proxy/192.168.181.106/live/0/hls.m3u8"
echo "done. 入口: http://<主机>:$LISTEN/"
