/// 应用配置。可用 `--dart-define=BASE_URL=http://host:port` 覆盖默认地址。
library;

const String kDefaultBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'http://112.25.181.94:8119',
);

/// 与服务端 VERSION 文件对齐；运行时以 package_info 的 versionName 为准。
const String kFallbackAppVersion = '1.0.5';

/// 服务器双出口：移动 / 电信。端口固定 8119。
class ServerEndpoint {
  final String id;
  final String label;
  final String host;
  final int port;
  const ServerEndpoint(this.id, this.label, this.host, {this.port = 8119});

  String get baseUrl => 'http://$host:$port';
}

const List<ServerEndpoint> kServerEndpoints = [
  ServerEndpoint('cmcc', '移动', '112.25.181.94'),
  ServerEndpoint('ctcc', '电信', '222.92.63.222'),
];

ServerEndpoint? findEndpointById(String? id) {
  if (id == null) return null;
  for (final e in kServerEndpoints) {
    if (e.id == id) return e;
  }
  return null;
}

ServerEndpoint? matchEndpoint(String baseUrl) {
  final b = baseUrl.toLowerCase();
  for (final e in kServerEndpoints) {
    if (b.contains(e.host)) return e;
  }
  return null;
}
