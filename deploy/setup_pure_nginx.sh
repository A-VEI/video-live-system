#!/bin/bash
# htpasswd 补充用户
htpasswd -b /opt/video-system/.htpasswd 13900139000 13900139000
htpasswd -b /opt/video-system/.htpasswd 13700137000 13700137000

# 纯 Nginx 配置
cat > /etc/nginx/conf.d/hls-proxy.conf << 'EOF'
map $arg_code $valid_code {
    "8119"  1;
    default 0;
}

server {
    listen 8119;
    root /opt/video-system/web;
    auth_basic "请输入手机号";
    auth_basic_user_file /opt/video-system/.htpasswd;

    # 下载页和 APK 不需要登录
    location = / {
        auth_basic off;
        try_files /index.html =404;
    }
    location = /download/apk {
        auth_basic off;
        if ($valid_code = 0) { return 403; }
        alias /opt/video-system/static/app/video-live.apk;
        add_header 'Content-Disposition' 'attachment; filename="video-live.apk"';
    }
    location = /api/app/download {
        auth_basic off;
        alias /opt/video-system/static/app/video-live.apk;
    }
    location = /api/app/version {
        auth_basic off;
        default_type application/json;
        return 200 '{"version":"1.0.2","update_url":"/api/app/download","size":27573247}';
    }

    # HLS 流代理 (认证后)
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
            if ($uri ~* '\.m3u8$') { add_header 'Content-Type' 'application/x-mpegURL' always; }
            if ($uri ~* '\.ts$') { add_header 'Content-Type' 'video/mp2t' always; add_header 'Cache-Control' 'max-age=10' always; }
        }
    }

    # 视频页 (需认证)
    location = /video.html {
        try_files /video.html =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

nginx -t 2>&1
systemctl restart nginx

echo "=== tests ==="
curl -s -o /dev/null -w 'no auth: %{http_code}\n' http://127.0.0.1:8119/video.html
curl -s -o /dev/null -w 'with auth: %{http_code}\n' -u 13800138000:13800138000 http://127.0.0.1:8119/video.html
curl -s -o /dev/null -w 'm3u8: %{http_code}\n' -u 13800138000:13800138000 http://127.0.0.1:8119/proxy/192.168.181.106/live/0/hls.m3u8
curl -s -o /dev/null -w 'download page: %{http_code}\n' http://127.0.0.1:8119/
curl -s -o /dev/null -w 'apk: %{http_code}\n' 'http://127.0.0.1:8119/download/apk?code=8119'
echo "=== pure nginx, no flask ==="
