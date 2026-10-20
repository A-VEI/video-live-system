# 视频直播系统 — 项目文档

> 更新时间：2026-10-20  
> 状态：**方案 B（签名 URL）+ Flask 唯一后端** 已落地，详见 `README.md`  
> （下文「纯 Nginx」章节为历史方案，已废弃，以 README 为准）

---

## 一、项目概述

为消防现场人员提供手机/平板 App + 网页端视频直播观看能力，接入 6 路 HLS 视频流。

| 项 | 值 |
|---|---|
| **服务端** | 192.168.181.11（Live-App） |
| **外部访问** | `http://112.25.181.94:8119` |
| **架构** | 纯 Nginx（无 Flask/Python 后端） |
| **认证** | HTTP Basic Auth（手机号:手机号） |
| **App** | Flutter（Android APK） |
| **GitHub** | https://github.com/A-VEI/video-live-system |

---

## 二、6 路视频流

| ID | 名称 | 流地址 | 设备 |
|---|---|---|---|
| 1 | 警情信息 | `http://192.168.181.106/live/0/hls.m3u8` | MagicPlayer 编码器 |
| 2 | 一体化指挥平台 | `http://192.168.181.103/live/0/hls.m3u8` | 同上 |
| 3 | 现场图传 | `http://192.168.181.105/live/0/hls.m3u8` | 同上 |
| 4 | 无人机画面 | `http://192.168.181.104/live/0/hls.m3u8` | 同上 |
| 5 | 社会面监控 | `http://192.168.181.101/live/0/hls.m3u8` | 同上 |
| 6 | 全国应急指挥系统 | `http://192.168.181.102/live/0/hls.m3u8` | 同上 |

**流格式：** HLS（`/live/0/hls.m3u8`）
**码率：** ~3.3 Mbps（833KB/2秒）
**分片：** 2秒一个 `.ts` 分片

### 视频流设备（192.168.181.101 等）

| 项 | 值 |
|---|---|
| 设备类型 | MagicPlayer 视频编码器/流媒体网关 |
| Web 管理 | `http://IP:80`（admin/admin） |
| 支持协议 | HLS、RTSP(554)、RTMP(1935)、WebRTC、GB28181 |
| 推荐格式 | **HLS**（兼容性最好、部署最简单） |

---

## 三、服务器架构

### 端口分配

| 端口 | 服务 | 说明 |
|---|---|---|
| **8119** | Nginx | 唯一对外端口（外部映射 112.25.181.94:8119） |
| 8120 | Flask（备用） | 已停用，纯 Nginx 模式不需要 |

### Nginx 配置（`/etc/nginx/conf.d/hls-proxy.conf`）

```
server {
    listen 8119;
    root /opt/video-system/web;

    # 下载页（免登录）
    location = / { ... }

    # APK 下载（口令 8119）
    location = /download/apk { ... }

    # HLS 流代理（Basic Auth，无缓冲）
    location /proxy/ {
        auth_basic "请输入手机号";
        auth_basic_user_file /opt/video-system/.htpasswd;
        location ~ ^/proxy/([^/]+)(/.*)$ {
            proxy_pass http://$backend_ip$backend_path$is_args$args;
            proxy_buffering off;
        }
    }

    # 视频页（Basic Auth）
    location = /video.html { ... }

    # API（走 Flask，无 Basic Auth）
    location /api/ {
        auth_basic off;
        proxy_pass http://127.0.0.1:8120;
    }
}
```

### 文件结构

```
/opt/video-system/
├── web/                    # Nginx 静态文件
│   ├── index.html          # 下载页（口令 8119）
│   └── video.html          # 视频播放页（Basic Auth）
├── static/
│   ├── hls.min.js          # HLS.js 播放器
│   └── app/
│       └── video-live.apk  # App 安装包
├── .htpasswd               # Basic Auth 密码文件
├── cgi-bin/                # CGI 脚本（备用）
├── data/                   # JSON 数据文件（备用）
└── app.py                  # Flask 程序（备用，已停用）
```

---

## 四、认证体系

### Basic Auth（当前方案）

| 手机号 | 密码 | 角色 |
|---|---|---|
| `13800138000` | `13800138000` | 管理员 |
| `13900139000` | `13900139000` | 用户 |
| `13700137000` | `13700137000` | 用户 |

**添加用户：**
```bash
htpasswd -b /opt/video-system/.htpasswd 手机号 手机号
```

**删除用户：**
```bash
htpasswd -D /opt/video-system/.htpasswd 手机号
```

### 网页下载口令

- 下载页口令：**8119**
- 修改口令：改 Nginx `map $arg_code` 和 `index.html`

---

## 五、App（Flutter）

### 功能

| 功能 | 说明 |
|---|---|
| 手机号登录 | Basic Auth 验证 |
| 6 路视频直播 | HLS 播放，单路点击播放 |
| 全屏播放 | 独立沉浸式全屏页面 |
| 自动更新 | 启动时检测版本，下载安装新版 |
| Token 持久化 | 退出不丢登录状态 |

### 构建

```bash
cd mobile-app
flutter pub get
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk
```

### CI 自动构建（GitHub Actions）

推送到 `main` 分支 → 自动构建 → 产出 APK artifact。

**Workflow：** `.github/workflows/build.yml`
- Flutter 3.24.5
- `flutter create` 生成 Android 骨架 → 覆盖 `lib/` 代码 → 构建

### 版本管理

| 位置 | 常量 | 当前值 |
|---|---|---|
| App | `kAppVersion`（`update_service.dart`） | `1.0.2` |
| 服务器 | `APP_VERSION`（`app.py`） | `1.0.2` |

**发新版流程：**
1. 改 App 的 `kAppVersion = '1.0.3'`
2. CI 构建 APK
3. 上传 APK 到服务器 `/opt/video-system/static/app/video-live.apk`
4. 改服务器 `APP_VERSION = '1.0.3'`
5. App 启动自动检测更新

### 自动更新 API

| 端点 | 说明 |
|---|---|
| `GET /api/app/version` | 返回最新版本号 |
| `GET /api/app/download` | 下载 APK（Nginx 直接提供） |

---

## 六、Web 端页面

| 页面 | 地址 | 认证 |
|---|---|---|
| 下载页 | `http://112.25.181.94:8119/` | 口令 8119 |
| 视频页 | `http://112.25.181.94:8119/video.html` | Basic Auth |
| 管理入口 | `Ctrl+Shift+U`（隐藏） | Basic Auth |

### 视频页功能

- 左侧频道列表（6 路）
- 点击播放 HLS 流
- 全屏按钮
- 播放/暂停/进度条
- 使用 HLS.js 播放器

---

## 七、服务器管理

### 系统信息

| 项 | 值 |
|---|---|
| 主机名 | Live-App |
| 系统 | Ubuntu/Debian |
| Python | 3.13.5 |
| Nginx | 1.26.3 |
| SSH | `root@192.168.181.11` |

### 服务管理

```bash
# Nginx
systemctl reload nginx        # 重载配置
nginx -t                       # 测试配置

# Flask（备用）
systemctl restart video-app    # 重启
systemctl stop video-app       # 停止
```

### 日志

```bash
tail -f /var/log/nginx/error.log   # Nginx 错误
journalctl -u video-app -f         # Flask 日志
```

---

## 八、网络拓扑

```
外网用户
    │
    ▼
112.25.181.94:8119  (端口映射)
    │
    ▼
192.168.181.11:8119  (Nginx)
    ├── /              下载页
    ├── /video.html    视频页 (Basic Auth)
    ├── /proxy/        HLS 流代理 (Basic Auth, 无缓冲)
    │       │
    │       ├──▶ 192.168.181.101  社会面监控
    │       ├──▶ 192.168.181.102  全国应急指挥
    │       ├──▶ 192.168.181.103  一体化指挥
    │       ├──▶ 192.168.181.104  无人机画面
    │       ├──▶ 192.168.181.105  现场图传
    │       └──▶ 192.168.181.106  警情信息
    │
    └── /api/          Flask API (备用)
```

---

## 九、历史原系统（苏州消防现场图像融合平台）

### 概述

克隆自生产系统，用于分析视频流接入方式。

| 项 | 值 |
|---|---|
| 系统 | 若依 (RuoYi) Spring Boot + MySQL |
| 数据库 | `shuzhou_xiaofang`（151 张表） |
| 前端 | Vue SPA（`/data/web/dist`） |
| 视频配置 | `dis_video` 表（6 条记录） |
| 用户 | 1,354 人 / 170 部门 |
| 警情 | 3,061 起火灾 / 82,664 条文书 |

### 视频流配置（原系统）

配置在 `shuzhou_xiaofang.dis_video` 表，与新系统完全一致的 6 路流。

代理方式也一致：Nginx `/proxy/` 透明代理到内网流媒体服务器。

### 原系统 vs 新系统对比

| | 原系统 | 新系统 |
|---|---|---|
| 框架 | RuoYi (Spring Boot) + Vue | 纯 Nginx + 静态 HTML |
| 数据库 | MySQL (151 表) | 无（htpasswd + 硬编码） |
| 认证 | Session + JWT | Basic Auth |
| 视频代理 | Nginx（有缓冲） | Nginx（无缓冲） |
| App | 无 | Flutter APK |
| 部署复杂度 | 高（Java+MySQL+Redis） | **极低（仅 Nginx）** |

---

## 十、已知问题与注意事项

### 已解决

| 问题 | 根因 | 修复 |
|---|---|---|
| 视频加载失败 | SSRF 白名单误杀 .ts 分片 | 放宽为仅校验内网 IP |
| 下载卡 100% | APK 在临时目录，FileProvider 不认 | 改外部存储 + FileProvider |
| 无限重复更新 | App 版本号 ≠ 服务器版本号 | 同步为 1.0.2 |
| 登录 401 | API 被 Basic Auth 拦截 | API 路径 `auth_basic off` |
| 构建失败 | 方法名不匹配 | 修正 `setPhone`/`clearAuth` |

### 注意事项

1. **发新版必须同时改两个版本号**（App + 服务器），否则会无限更新
2. **代理不缓冲**（`proxy_buffering off`），与原系统一致
3. **口令 8119** 是下载页口令，不是登录密码
4. **登录密码 = 手机号**，在 `/opt/video-system/.htpasswd` 中管理
5. **App 端视频地址硬编码**，改流需要重新构建 APK

---

## 十一、开发环境

| 工具 | 用途 |
|---|---|
| GitHub Actions | CI 自动构建 APK |
| ADB | 安装 APK 到平板/模拟器 |
| 雷电模拟器 | 本地测试（`emulator-5554`） |
| MIMO_PYTHON | 本地 Python 3.13 |

### 本地文件

```
video-system/
├── app.py                    # Flask 程序（备用）
├── requirements.txt
├── templates/                # Flask 模板（备用）
│   ├── login.html
│   ├── download.html
│   ├── dashboard.html
│   ├── video_disabled.html
│   ├── users.html
│   └── devices.html
├── static/
│   └── hls.min.js
├── mobile-app/               # Flutter App
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── api/api_client.dart
│   │   ├── pages/
│   │   │   ├── login_page.dart
│   │   │   ├── home_page.dart
│   │   │   ├── video_page.dart
│   │   │   ├── devices_page.dart
│   │   │   └── users_page.dart
│   │   └── services/
│   │       └── update_service.dart
│   └── .github/workflows/build.yml
├── video.html                # 纯 Nginx 视频页
├── cgi-api.py                # CGI API（备用）
└── docs/compose/spec/        # 设计文档
```

---

## 十二、联系与支持

- **GitHub 仓库：** https://github.com/A-VEI/video-live-system
- **CI 构建：** https://github.com/A-VEI/video-live-system/actions
- **服务器 SSH：** `root@192.168.181.11`
- **外部访问：** `http://112.25.181.94:8119`
