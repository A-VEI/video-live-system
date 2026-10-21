#!/bin/bash
# 用法: write_build_meta.sh <build_id>
# build_id 必须与打包时 --dart-define=BUILD_ID 相同（CI 用 github.run_number）
set -e
BUILD_ID=${1:-}
if [ -z "$BUILD_ID" ]; then
  echo "usage: $0 <build_id>" >&2
  echo "build_id must match CI --dart-define=BUILD_ID" >&2
  exit 1
fi
APK=/opt/video-system/static/app/video-live.apk
META=/opt/video-system/static/app/build.json
if [ ! -f "$APK" ]; then
  echo "APK not found: $APK" >&2
  exit 1
fi
SHA=$(sha256sum "$APK" | awk '{print $1}')
SIZE=$(stat -c%s "$APK")
VER=$(cat /opt/video-system/VERSION 2>/dev/null || echo 0.0.0)
cat > "$META" <<EOF
{"build_id": $BUILD_ID, "sha256": "$SHA", "size": $SIZE, "version": "$VER"}
EOF
echo "wrote $META"
cat "$META"
systemctl restart video-app 2>/dev/null || true
