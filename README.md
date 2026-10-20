# 消防视频直播系统

手机号 + **独立口令**登录 · 6 路 HLS 直播 · Flutter App · 用户/设备管理 · P3 安全加固。

## 架构（方案 B：签名 URL 拉流）

```
App / Web
   │  JWT (Authorization: Bearer) + 手机号/口令
   ▼
Nginx :8119  ──静态页/APK──►  web/   （HTTP）
   │
   ├── /api/*     ──反代──►  Flask :8120  ──SQLite
   └── /proxy/*   ──反代──►  Flask 签名校验 + m3u8 改写 ──► 内网编码器
```

播放器（ExoPlayer / hls.js）**无法注入 Authorization 头**，因此 `/proxy/` 不走 Basic Auth，改为短时签名：

1. 登录 `POST /api/mobile/login` `{phone,password}` → JWT  
2. `GET /api/mobile/streams` → `proxy_url` 形如  
   `/proxy/192.168.181.106/live/0/hls.m3u8?exp=…&sig=…`  
3. 代理校验 `exp+sig`（HMAC，范围=主机名），并把 m3u8 里分片 URI 改写成带同一 token 的 `/proxy/...`  
4. 主机白名单 + 路径前缀来自 `streams` 表，拒绝环回/链路本地/云元数据地址  

## P3 安全

| 能力 | 说明 |
|---|---|
| 独立口令 | PBKDF2-SHA256（24 万轮）；**禁止口令=手机号** |
| 初始口令 | 首次 `init_db` 生成随机口令写入 `INITIAL_CREDENTIALS.txt`（0600），登录后**强制改密** |
| 口令策略 | ≥8 位，两类字符，禁弱口令 |
| 下载口令 | 存 `settings.download_code`，管理员可 `PUT /api/admin/download-code` 轮换 |
| SSRF | 拒绝 `127/8` `169.254/16` `localhost` 等；路径必须落在配置流目录前缀 |
| APK 完整性 | `/api/app/version` 返回 `sha256`，App 下载后校验，失败即丢弃 |
| 安全响应头 | `X-Content-Type-Options` / `X-Frame-Options` / `Referrer-Policy` / 页面 CSP |
| 审计日志 | 登录成功/失败、改密、用户增删、代理拒绝 → `audit_log`，`GET /api/admin/audit` |
| 传输 | **HTTP**（按项目要求不启用 HTTPS/TLS） |

## 快速启动

```bash
pip install -r requirements.txt
python app.py          # 默认 :8120，可用 PORT=8119
# 首次会生成 INITIAL_CREDENTIALS.txt —— 用里面的口令登录并立即改密
```

生产部署（HTTP）：

```bash
bash deploy/setup.sh
# 入口: http://112.25.181.94:8119/
```

> 本项目明确采用 HTTP，不配置 TLS/HTTPS。请通过内网/专网或端口映射访问。

## 自检

```bash
python smoke_test.py      # 方案 B 签名拉流 8 项
python smoke_test_p3.py   # P3 安全 13 项
```

## API 摘要

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/mobile/login` | `{phone,password}` → `{token,name,role,must_change_password}` |
| GET | `/api/mobile/me` | 当前用户 |
| POST | `/api/mobile/change-password` | `{old_password,new_password}` |
| GET | `/api/mobile/streams` | 频道 + 签名 `proxy_url` |
| GET/POST/PUT/DELETE | `/api/mobile/devices*` | 设备管理（admin） |
| GET/POST/PUT/DELETE | `/api/mobile/users*` | 用户管理（admin，支持 password） |
| PUT | `/api/admin/download-code` | 轮换下载口令（admin） |
| GET | `/api/admin/audit` | 审计日志（admin） |
| GET | `/api/app/version` | 版本 + APK `sha256` |
| GET | `/proxy/<host>/<path>?exp=&sig=` | 签名 HLS 代理 |

## 目录

```
video-system/
├── app.py                 # Flask：口令登录 + JWT + 签名代理 + 审计
├── security.py            # P3：哈希/策略/SSRF/APK 指纹/安全头
├── stream_token.py        # 方案 B：HMAC 签名 / m3u8 改写
├── VERSION                # 服务端版本号
├── secret.key             # 自动生成（勿提交）
├── INITIAL_CREDENTIALS.txt# 仅首次（勿提交，改密后删除）
├── smoke_test.py / smoke_test_p3.py
├── deploy/setup.sh        # Nginx + systemd（HTTP）
├── templates/             # Web 页（含改密）
└── mobile-app/            # Flutter App
```

## 发版

1. 改 `mobile-app/pubspec.yaml` 的 `version`（如 `1.0.5+5`）  
2. 同步 `VERSION` 文件为同一主版本号  
3. CI 构建 APK → 上传 `/opt/video-system/static/app/video-live.apk`  
4. App 启动比对 `sha256` 后安装  

> 旧习惯「口令=手机号」已废弃。若从旧库迁移，无 `password_hash` 的用户会被标记 `must_change_password=1`，临时口令=手机号，**登录后强制改密**。
