import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  static late ApiClient _instance;
  late Dio _dio;
  String _baseUrl = 'http://10.0.2.2:5000'; // Android emulator default
  String? _token;

  static Future<ApiClient> init({String? baseUrl}) async {
    _instance = ApiClient._();
    if (baseUrl != null) _instance._baseUrl = baseUrl;
    final prefs = await SharedPreferences.getInstance();
    _instance._token = prefs.getString('jwt_token');
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
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer $_token';
        }
        handler.next(options);
      },
    ));
  }

  Future<void> setToken(String token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jwt_token', token);
  }

  Future<void> clearToken() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
  }

  String? get token => _token;
  String get baseUrl => _baseUrl;

  // ── Auth ──
  Future<Map<String, dynamic>> login(String phone) async {
    final r = await _dio.post('/api/mobile/login', data: {'phone': phone});
    return r.data;
  }

  Future<Map<String, dynamic>> me() async {
    final r = await _dio.get('/api/mobile/me');
    return r.data;
  }

  // ── Streams ──
  Future<List<dynamic>> getStreams() async {
    final r = await _dio.get('/api/mobile/streams');
    return r.data;
  }

  // ── Devices ──
  Future<List<dynamic>> getDevices() async {
    final r = await _dio.get('/api/mobile/devices');
    return r.data;
  }

  Future<void> addDevice(Map<String, dynamic> data) async {
    await _dio.post('/api/mobile/devices', data: data);
  }

  Future<void> updateDevice(int id, Map<String, dynamic> data) async {
    await _dio.put('/api/mobile/devices/$id', data: data);
  }

  Future<Map<String, dynamic>> toggleDevice(int id) async {
    final r = await _dio.put('/api/mobile/devices/$id/toggle');
    return r.data;
  }

  Future<void> deleteDevice(int id) async {
    await _dio.delete('/api/mobile/devices/$id');
  }

  // ── Users ──
  Future<List<dynamic>> getUsers() async {
    final r = await _dio.get('/api/mobile/users');
    return r.data;
  }

  Future<void> addUser(Map<String, dynamic> data) async {
    await _dio.post('/api/mobile/users', data: data);
  }

  Future<void> updateUser(int id, Map<String, dynamic> data) async {
    await _dio.put('/api/mobile/users/$id', data: data);
  }

  Future<Map<String, dynamic>> toggleUser(int id) async {
    final r = await _dio.put('/api/mobile/users/$id/toggle');
    return r.data;
  }

  Future<void> deleteUser(int id) async {
    await _dio.delete('/api/mobile/users/$id');
  }

  // ── Proxy URL helper (Nginx HLS 代理, 更快) ──
  String proxyUrl(String streamUrl) {
    final uri = Uri.parse(streamUrl);
    // Nginx 8119 直接处理 HLS 代理, 不需要换端口
    return '$_baseUrl/proxy/${uri.host}${uri.path}';
  }
}
