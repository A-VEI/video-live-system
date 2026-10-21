#!/bin/bash
# 用法: write_build_meta.sh <build_id> [build_time]
# 产物约定文件名: video-live_build<id>_<YYYYmmddHHMMSS>.apk
set -e
BUILD_ID=${1:-}
BUILD_TIME=${2:-}
if [ -z "$BUILD_ID" ]; then
  echo "usage: $0 <build_id> [build_time]" >&2
  exit 1
fi
if [ -z "$BUILD_TIME" ]; then
  BUILD_TIME=$(date +%s)
fi
APK=/opt/video-system/static/app/video-live.apk
META=/opt/video-system/static/app/build.json
if [ ! -f "$APK" ]; then
  echo "APK not found: $APK" >&2
  exit 1
fi
SHA=$(sha256sum "$APK" | awk '{print $1}')
SIZE=$(stat -c%s "$APK")
# 同步一份带构建号+时间戳的归档文件名
STAMP=$(date -d @${BUILD_TIME} +%Y%m%d%H%M%S 2>/dev/null || date +%Y%m%d%H%M%S)
cp -f "$APK" "/opt/video-system/static/app/video-live_build${BUILD_ID}_${STAMP}.apk"
chmod 644 "/opt/video-system/static/app/video-live_build${BUILD_ID}_${STAMP}.apk"
cat > "$META" <<EOF
{"build_id": $BUILD_ID, "build_time": $BUILD_TIME, "sha256": "$SHA", "size": $SIZE}
EOF
echo "wrote $META"
cat "$META"
ls -la /opt/video-system/static/app/video-live_build${BUILD_ID}_${STAMP}.apk
systemctl restart video-app 2>/dev/null || true
