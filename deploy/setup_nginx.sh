#!/bin/bash
# 上传 CGI
cp /tmp/cgi-api.py /opt/video-system/cgi-bin/api.py
chmod +x /opt/video-system/cgi-bin/api.py

# Nginx 配置 - 纯 Nginx + CGI
cat > /etc/nginx/conf.d/hls-proxy.conf << 'EOF'
map $arg_code $valid_code {
    "8119"  1;
    default 0;
}

server {
    listen 8119;
    root /opt/video-system/web;

    # APK 下载
    location = /download/apk {
        if ($valid_code = 0) { return 403; }
        alias /opt/video-system/static/app/video-live.apk;
        add_header 'Content-Disposition' 'attachment; filename="video-live.apk"';
    }

    # 自动更新下载
    location = /api/app/download {
        alias /opt/video-system/static/app/video-live.apk;
        add_header 'Content-Disposition' 'attachment; filename="video-live.apk"';
    }

    # HLS 流代理
    location /proxy/ {
        resolver 192.168.181.10 valid=30s;
        location ~ ^/proxy/([^/]+)(/.*)$ {
            set $backend_ip $1;
            set $backend_path $2;
            proxy_pass http://$backend_ip$backend_path$is_args$args;
            proxy_buffering on;
            proxy_buffer_size 128k;
            proxy_buffers 8 128k;
            proxy_busy_buffers_size 256k;
            proxy_connect_timeout 5s;
            proxy_read_timeout 30s;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            add_header 'Access-Control-Allow-Origin' '*' always;
            if ($uri ~* '\.m3u8$') {
                add_header 'Content-Type' 'application/x-mpegURL' always;
            }
            if ($uri ~* '\.ts$') {
                add_header 'Content-Type' 'video/mp2t' always;
                add_header 'Cache-Control' 'max-age=10' always;
            }
        }
    }

    # API - CGI
    location /api/ {
        gzip off;
        include fastcgi_params;
        fastcgi_pass unix:/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME /opt/video-system/cgi-bin/api.py;
        fastcgi_param REQUEST_URI $request_uri;
    }

    # 静态页面
    location / {
        try_files $uri $uri/ /index.html;
        add_header 'Cache-Control' 'no-cache';
    }
}
EOF

# 安装 fcgiwrap (CGI 网关)
apt-get install -y -qq fcgiwrap 2>/dev/null
systemctl restart fcgiwrap

nginx -t 2>&1
systemctl restart nginx

echo "=== test ==="
curl -s -o /dev/null -w 'app: %{http_code}\n' http://127.0.0.1:8119/
curl -s -o /dev/null -w 'login: %{http_code}\n' -X POST -d '{"phone":"13800138000"}' http://127.0.0.1:8119/api/mobile/login
curl -s -X POST -H 'Content-Type: application/json' -d '{"phone":"13800138000"}' http://127.0.0.1:8119/api/mobile/login | head -c 100
echo ""
curl -s -o /dev/null -w 'm3u8: %{http_code}\n' http://127.0.0.1:8119/proxy/192.168.181.106/live/0/hls.m3u8
