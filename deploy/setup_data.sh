#!/bin/bash
mkdir -p /opt/video-system/cgi-bin /opt/video-system/data

cat > /opt/video-system/data/users.json << 'JSONEOF'
[
  {"id":1,"phone":"13800138000","name":"admin","role":"admin","enabled":1},
  {"id":2,"phone":"13900139000","name":"user1","role":"user","enabled":1},
  {"id":3,"phone":"13700137000","name":"user2","role":"user","enabled":1}
]
JSONEOF

cat > /opt/video-system/data/devices.json << 'JSONEOF'
[
  {"id":1,"name":"camera1","url":"http://192.168.181.106/live/0/hls.m3u8","sort":1,"enabled":1},
  {"id":2,"name":"camera2","url":"http://192.168.181.103/live/0/hls.m3u8","sort":2,"enabled":1},
  {"id":3,"name":"camera3","url":"http://192.168.181.105/live/0/hls.m3u8","sort":3,"enabled":1},
  {"id":4,"name":"camera4","url":"http://192.168.181.104/live/0/hls.m3u8","sort":4,"enabled":1},
  {"id":5,"name":"camera5","url":"http://192.168.181.101/live/0/hls.m3u8","sort":5,"enabled":1},
  {"id":6,"name":"camera6","url":"http://192.168.181.102/live/0/hls.m3u8","sort":6,"enabled":1}
]
JSONEOF

echo '{"web_video_enabled": 1, "app_version": "1.0.2"}' > /opt/video-system/data/settings.json

echo "=== data ==="
ls -la /opt/video-system/data/
cat /opt/video-system/data/settings.json
