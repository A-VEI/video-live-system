---
feature: download-page-and-web-toggle
status: designed
updated: 2026-10-20
branch: main
commits:
---

# 下载页 + 隐藏管理 + Web 视频开关

## Report

## [S1] Problem

Web 端不应直接进入视频页面，而应作为 APK 下载入口。账号管理需要隐藏。Web 视频观看需要管理员可控开关（主要用安卓 App 看视频）。

## [S2] Design

### 首页改造
- `/` 路由改为 **App 下载页**（登录后也可访问，但默认公开）
- 下载 APK 需输入 **口令：8119**
- 页面极简：只有产品名 + 下载按钮 + 口令输入框，无其他信息
- 验证通过后直接下载 APK 文件（服务端存 `/static/app/video-live.apk`）

### 隐藏账号管理入口
- `/users` 路由保留，但从所有 UI 导航中移除
- 通过 **键盘快捷键 `Ctrl+Shift+U`** 打开（或 URL `/#admin`）
- 下载页和视频页都不显示管理入口

### Web 视频开关
- 新增 `settings` 表：`key TEXT PRIMARY KEY, value TEXT`
- 配置项 `web_video_enabled`：`1` = Web 可看视频，`0` = 仅 App 可看
- 设备管理页（`/devices`）加一个「Web 视频开关」toggle
- 关闭时 `/` 视频页跳转到提示页「请使用 App 观看」
- App（`/api/mobile/*`）不受此开关影响

### 设置 API
- `GET /api/settings` → `{web_video_enabled: 0|1}` （登录后）
- `PUT /api/settings/web_video` （admin）`{value: 0|1}`

## [S3] Out of Scope

- APK 自动更新
- 口令管理界面（口令硬编码 8119）
- App 内下载页

## Tasks

- [ ] T1: 新增 settings 表 + API（GET/PUT web_video_enabled） — acceptance: curl GET /api/settings 返回 JSON，PUT 切换值生效 (covers: S2)
- [ ] T2: 首页改为下载页（口令 8119 验证后下载 APK） — acceptance: 打开 / 显示下载页，输错口令报错，输对触发下载 (covers: S2)
- [ ] T3: 隐藏管理入口（Ctrl+Shift+U / /#admin） — acceptance: 页面无可见管理链接，快捷键可进入 (covers: S2)
- [ ] T4: Web 视频开关（设备管理页 toggle） — acceptance: 开关关后 / 跳提示页，开后正常显示视频 (covers: S2)
- [ ] T5: 推送代码到 GitHub 触发 CI 构建 APK — acceptance: CI 构建成功产出 APK (covers: S2)
