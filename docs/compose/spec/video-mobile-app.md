---
feature: video-mobile-app
status: designed
updated: 2026-10-20
branch: main
commits:
---

# 视频直播移动端 App（Flutter）

## Report

## [S1] Problem

现有 Web 端视频直播系统（Flask + SQLite）只支持浏览器访问。消防现场人员需要在手机/平板上随时查看 6 路 HLS 直播画面，并由管理员在移动端管理设备和用户。需要一个 APK，以现有服务为后端 API。

## [S2] Design

### 技术栈
- **Flutter 3.x**（Android 优先，iOS 可扩展）
- **状态管理**：Riverpod
- **HTTP**：Dio
- **HLS 播放**：`video_player` + `chewie`（Android 自动走 ExoPlayer）
- **本地存储**：`shared_preferences`（JWT token）

### 功能模块

| 模块 | 功能 | 说明 |
|---|---|---|
| 登录 | 手机号登录 | 调 `/api/mobile/login`，返回 JWT |
| 视频 | 频道列表 + 单路播放 | 调 `/api/streams`，HLS 代理播放 |
| 设备管理 | 列表 + 开关 + 增删改 | `/api/devices*`（admin） |
| 用户管理 | 列表 + 开关 + 增删改 | `/api/users*`（admin） |

### API 合同（服务端新增）

服务端新增 `/api/mobile/*` 路由，JWT 认证，不依赖 Session Cookie：

```
POST /api/mobile/login          {phone} → {token, name, role}
GET  /api/mobile/me             → {phone, name, role}
GET  /api/mobile/streams        → [{id, name, url, proxy_url, sort, enabled}]
GET  /api/mobile/devices        → [{id, name, url, sort, enabled}]   (admin)
POST /api/mobile/devices        (admin)
PUT  /api/mobile/devices/:id    (admin)
PUT  /api/mobile/devices/:id/toggle (admin)
DELETE /api/mobile/devices/:id  (admin)
GET  /api/mobile/users          (admin)
POST /api/mobile/users          (admin)
PUT  /api/mobile/users/:id      (admin)
PUT  /api/mobile/users/:id/toggle (admin)
DELETE /api/mobile/users/:id    (admin)
```

JWT 签名：HMAC-SHA256，secret 复用 Flask `app.secret_key`，有效期 12h。
兼容模式：`/api/*` 旧路由保持 Session 认证不变。

### 视频播放流

App 通过 `/proxy/<host>/<path>` 代理拉取 HLS。`proxy_url` 由服务端 API 返回，App 直接用。

### 认证双模式

| 客户端 | 认证头 | 说明 |
|---|---|---|
| Web | `Cookie: session=...` | Flask Session，不变 |
| App | `Authorization: Bearer <jwt>` | 新增 JWT 中间件 |

服务端中间件顺序：JWT → Session，任一通过即可。

## [S3] Out of Scope

- iOS 打包（项目结构支持，但本阶段只出 APK）
- 推送通知
- 视频录制/回放
- 离线缓存
- 多服务器切换

## Tasks

- [ ] T1: 服务端新增 JWT 认证 + `/api/mobile/*` 路由 — acceptance: curl 登录取 token 后可访问 `/api/mobile/streams`，无 token 返回 401 (covers: S2)
- [ ] T2: 创建 Flutter 项目骨架（pubspec、目录结构、路由、主题） — acceptance: `flutter analyze` 无 error (covers: S2; depends: T1)
- [ ] T3: 实现登录页（手机号 + JWT 存储） — acceptance: 输入授权手机号跳转视频页，未授权显示错误 (covers: S2; depends: T2)
- [ ] T4: 实现视频页（频道列表 + HLS 播放器） — acceptance: 点击频道可播放对应 HLS 流 (covers: S2; depends: T3)
- [ ] T5: 实现设备管理页（列表 + 开关 + 增删改） — acceptance: 开关设备后视频列表同步变化 (covers: S2; depends: T3)
- [ ] T6: 实现用户管理页（列表 + 开关 + 增删改） — acceptance: 添加/删除用户后列表刷新 (covers: S2; depends: T3)
- [ ] T7: 配置 GitHub Actions CI（flutter build apk） — acceptance: push 后 CI 产出 APK artifact (covers: S2; depends: T2)
