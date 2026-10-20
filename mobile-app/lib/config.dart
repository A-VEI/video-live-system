/// 应用配置。服务器地址可用 `--dart-define=BASE_URL=http://host:port` 覆盖。
library;

const String kDefaultBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'http://112.25.181.94:8119',
);

/// 与服务端 VERSION 文件对齐；运行时以 package_info 的 versionName 为准。
const String kFallbackAppVersion = '1.0.4';
