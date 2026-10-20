import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  static late ApiClient _instance;
  late Dio _dio;
  String _baseUrl = 'http://112.25.181.94:8119';
  String? _phone;

  static Future<ApiClient> init({String? baseUrl}) async {
    _instance = ApiClient._();
    if (baseUrl != null) _instance._baseUrl = baseUrl;
    final prefs = await SharedPreferences.getInstance();
    _instance._phone = prefs.getString('auth_phone');
    _instance._setupDio();
    return _instance;
  }

  static ApiClient get instance => _instance;
  ApiClient._();

  void _setupDio() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    // Basic Auth: username=phone, password=phone
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_phone != null) {
          final cred = base64Encode(utf8.encode('$_phone:$_phone'));
          options.headers['Authorization'] = 'Basic $cred';
        }
        handler.next(options);
      },
    ));
  }

  Future<void> setPhone(String phone) async {
    _phone = phone;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_phone', phone);
  }

  Future<void> clearAuth() async {
    _phone = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_phone');
  }

  String? get phone => _phone;
  String get baseUrl => _baseUrl;

  // ── Auth: Basic Auth (phone:phone) ──
  Future<Map<String, dynamic>> login(String phone) async {
    // 验证手机号是否在 htpasswd 中: 尝试访问受保护资源
    final cred = base64Encode(utf8.encode('$phone:$phone'));
    try {
      final r = await Dio().get(
        '$_baseUrl/video.html',
        options: Options(headers: {'Authorization': 'Basic $cred'}),
      );
      if (r.statusCode == 200) {
        await setPhone(phone);
        return {'ok': true, 'phone': phone, 'name': phone, 'role': 'user'};
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return {'ok': false, 'msg': '手机号未授权'};
      }
    }
    return {'ok': false, 'msg': '网络错误'};
  }

  Future<Map<String, dynamic>> me() async {
    return {'ok': true, 'phone': _phone, 'name': _phone, 'role': 'user'};
  }

  // ── Streams: 硬编码 (纯 Nginx 无 API) ──
  Future<List<dynamic>> getStreams() async {
    return [
      {'id': 1, 'name': '警情信息', 'url': 'http://192.168.181.106/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.106/live/0/hls.m3u8', 'sort': 1, 'enabled': 1},
      {'id': 2, 'name': '一体化指挥平台', 'url': 'http://192.168.181.103/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.103/live/0/hls.m3u8', 'sort': 2, 'enabled': 1},
      {'id': 3, 'name': '现场图传', 'url': 'http://192.168.181.105/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.105/live/0/hls.m3u8', 'sort': 3, 'enabled': 1},
      {'id': 4, 'name': '无人机画面', 'url': 'http://192.168.181.104/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.104/live/0/hls.m3u8', 'sort': 4, 'enabled': 1},
      {'id': 5, 'name': '社会面监控', 'url': 'http://192.168.181.101/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.101/live/0/hls.m3u8', 'sort': 5, 'enabled': 1},
      {'id': 6, 'name': '全国应急指挥系统', 'url': 'http://192.168.181.102/live/0/hls.m3u8', 'proxy_url': '/proxy/192.168.181.102/live/0/hls.m3u8', 'sort': 6, 'enabled': 1},
    ];
  }

  // ── Proxy URL (Nginx 直接处理) ──
  String proxyUrl(String streamUrl) {
    final uri = Uri.parse(streamUrl);
    return '$_baseUrl/proxy/${uri.host}${uri.path}';
  }

  // ── 版本检查 ──
  Future<Map<String, dynamic>?> checkVersion() async {
    try {
      final r = await Dio().get('$_baseUrl/api/app/version');
      return r.data;
    } catch (_) {
      return null;
    }
  }

  // ── 管理接口 (设备/用户) — 纯 Nginx 不支持, 返回空 ──
  Future<List<dynamic>> getDevices() async => getStreams();
  Future<List<dynamic>> getUsers() async => [];
  Future<void> addDevice(Map<String, dynamic> d) async {}
  Future<void> updateDevice(int id, Map<String, dynamic> d) async {}
  Future<Map<String, dynamic>> toggleDevice(int id) async => {'ok': true};
  Future<void> deleteDevice(int id) async {}
  Future<void> addUser(Map<String, dynamic> d) async {}
  Future<void> updateUser(int id, Map<String, dynamic> d) async {}
  Future<Map<String, dynamic>> toggleUser(int id) async => {'ok': true};
  Future<void> deleteUser(int id) async {}
}
