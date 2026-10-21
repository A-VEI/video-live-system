#!/bin/bash
# 安装 APK 后写 build.json，供 /api/app/version 返回 build_id
set -e
APK=/opt/video-system/static/app/video-live.apk
META=/opt/video-system/static/app/build.json
BUILD_ID=${1:-$(date +%Y%m%d%H%M)}
SHA=$(sha256sum "$APK" | awk '{print $1}')
SIZE=$(stat -c%s "$APK")
VER=$(cat /opt/video-system/VERSION 2>/dev/null || echo 0.0.0)
cat > "$META" <<EOF
{"build_id": $BUILD_ID, "sha256": "$SHA", "size": $SIZE, "version": "$VER"}
EOF
cat "$META"
systemctl restart video-app 2>/dev/null || true
