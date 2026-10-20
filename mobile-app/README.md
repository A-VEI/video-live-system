# 视频直播系统 - 移动端 App

Flutter 开发，Android APK 优先。

## 功能

- 手机号登录（JWT 认证）
- 6 路 HLS 视频直播（单路播放）
- 设备管理（开关、增删改）
- 用户管理（开关、增删改）

## 构建

### CI 自动构建（推荐）

推送到 `main` 分支后 GitHub Actions 自动构建 APK。

### 本地构建

```bash
cd mobile-app
flutter pub get
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk
```

## 配置服务器地址

修改 `lib/main.dart` 中的 `baseUrl`：

```dart
await ApiClient.init(baseUrl: 'http://你的服务器IP:5000');
```

## 依赖

| 包 | 用途 |
|---|---|
| dio | HTTP 请求 |
| shared_preferences | JWT 本地存储 |
| video_player + chewie | HLS 视频播放 |
