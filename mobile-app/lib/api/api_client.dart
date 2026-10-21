import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';

/// 业务异常：带可展示的中文 message 与 HTTP 状态码。
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class ApiClient {
  static late ApiClient _instance;
  late Dio _dio;
  String _baseUrl = kDefaultBaseUrl;
  String? _phone;
  String? _token;
  String? _name;
  String? _role;

  static Future<ApiClient> init({String? baseUrl}) async {
    _instance = ApiClient._();
    final prefs = await SharedPreferences.getInstance();
    _instance._baseUrl =
        baseUrl ?? prefs.getString('base_url') ?? kDefaultBaseUrl;
    _instance._phone = prefs.getString('auth_phone');
    _instance._token = prefs.getString('auth_token');
    _instance._name = prefs.getString('auth_name');
    _instance._role = prefs.getString('auth_role') ?? 'user';
    _instance._setupDio();
    return _instance;
  }

  static ApiClient get instance => _instance;
  ApiClient._();

  void _setupDio() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Accept': 'application/json'},
      validateStatus: (s) => s != null && s < 500,
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer $_token';
        }
        // 兼容 Web 端 CSRF 装饰器
        if (options.method != 'GET') {
          options.headers['X-Requested-With'] = 'XMLHttpRequest';
        }
        handler.next(options);
      },
    ));
  }

  // ── 持久化 ──
  Future<void> _saveSession({
    required String phone,
    required String token,
    String? name,
    String? role,
  }) async {
    _phone = phone;
    _token = token;
    _name = name ?? phone;
    _role = role ?? 'user';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_phone', phone);
    await prefs.setString('auth_token', token);
    await prefs.setString('auth_name', _name!);
    await prefs.setString('auth_role', _role!);
  }

  Future<void> clearAuth() async {
    _phone = null;
    _token = null;
    _name = null;
    _role = 'user';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_phone');
    await prefs.remove('auth_token');
    await prefs.remove('auth_name');
    await prefs.remove('auth_role');
    // 保留 saved_phone + saved_token（JWT）自动登录，不存口令
  }

  // ── 记住账号口令（换线路自动登录）──
  String? _savedPhone;

  Future<void> _saveCredentials(String phone, String password) async {
    // 不存口令明文；换线路用 JWT 自动登录
    _savedPhone = phone;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_phone', phone);
    await prefs.remove('saved_password');
    if (_token != null) {
      await prefs.setString('saved_token', _token!);
    }
  }

  Future<Map<String, dynamic>?> trySavedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString('saved_phone');
    final token = prefs.getString('saved_token');
    if (phone == null || token == null) return null;
    _phone = phone;
    _token = token;
    _setupDio();
    try {
      final me = await this.me();
      return {
        'ok': true,
        'phone': phone,
        'name': me['name'] ?? phone,
        'role': me['role'] ?? 'user',
      };
    } catch (_) {
      // token 失效则需重新输入口令
      await clearAuth();
      return null;
    }
  }

  Future<void> setBaseUrl(String url) async {
    final normalized = url.endsWith('/')
        ? url.substring(0, url.length - 1)
        : url;
    _baseUrl = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', normalized);
    _setupDio();
  }

  String? get phone => _phone;
  String? get token => _token;
  String? get displayName => _name;
  String get role => _role ?? 'user';
  bool get isAdmin => role == 'admin';
  bool get isLoggedIn => _token != null && _phone != null;
  String get baseUrl => _baseUrl;

  Dio get dio => _dio;

  Never _throwApiError(Response r, {String fallback = '请求失败'}) {
    final data = r.data;
    String msg = fallback;
    if (data is Map && data['msg'] is String) {
      msg = data['msg'] as String;
    } else if (r.statusMessage != null && r.statusMessage!.isNotEmpty) {
      msg = r.statusMessage!;
    }
    throw ApiException(msg, statusCode: r.statusCode);
  }

  // ── Auth ──
  Future<Map<String, dynamic>> login(String phone, String password) async {
    try {
      final r = await _dio.post('/api/mobile/login',
          data: {'phone': phone, 'password': password});
      final data = r.data;
      if (r.statusCode == 200 && data is Map && data['ok'] == true) {
        await _saveSession(
          phone: data['phone'] ?? phone,
          token: data['token'] as String,
          name: data['name'],
          role: data['role'],
        );
        await _saveCredentials(phone, password);
        return {
          'ok': true,
          'phone': data['phone'] ?? phone,
          'name': data['name'] ?? phone,
          'role': data['role'] ?? 'user',
          'must_change_password': data['must_change_password'] == true,
        };
      }
      _throwApiError(r, fallback: '登录失败');
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '登录失败');
    }
    return {'ok': false, 'msg': '登录失败'};
  }

  Future<Map<String, dynamic>> me() async {
    try {
      final r = await _dio.get('/api/mobile/me');
      final data = r.data;
      if (r.statusCode == 200 && data is Map && data['ok'] == true) {
        _name = data['name'] ?? _name;
        _role = data['role'] ?? _role;
        final prefs = await SharedPreferences.getInstance();
        if (_name != null) await prefs.setString('auth_name', _name!);
        if (_role != null) await prefs.setString('auth_role', _role!);
        return {
          'ok': true,
          'phone': data['phone'] ?? _phone,
          'name': _name,
          'role': _role,
          'must_change_password': data['must_change_password'] == true,
        };
      }
      if (r.statusCode == 401) {
        await clearAuth();
        throw ApiException('登录已过期，请重新登录', statusCode: 401);
      }
      _throwApiError(r, fallback: '获取用户信息失败');
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '获取用户信息失败');
    }
    return {'ok': false};
  }

  // ── Streams / Devices ──
  Future<List<dynamic>> getStreams() async {
    try {
      final r = await _dio.get('/api/mobile/streams');
      if (r.statusCode == 200 && r.data is List) {
        return r.data as List;
      }
      if (r.statusCode == 401) {
        await clearAuth();
        throw ApiException('登录已过期，请重新登录', statusCode: 401);
      }
      _throwApiError(r, fallback: '获取频道失败');
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '获取频道失败');
    }
    return [];
  }

  Future<List<dynamic>> getDevices() async {
    try {
      final r = await _dio.get('/api/mobile/devices');
      if (r.statusCode == 200 && r.data is List) return r.data as List;
      if (r.statusCode == 403) throw ApiException('需要管理员权限', statusCode: 403);
      _throwApiError(r, fallback: '获取设备失败');
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '获取设备失败');
    }
    return [];
  }

  Future<void> addDevice(Map<String, dynamic> d) =>
      _mutate('/api/mobile/devices', method: 'POST', data: d);

  Future<void> updateDevice(int id, Map<String, dynamic> d) =>
      _mutate('/api/mobile/devices/$id', method: 'PUT', data: d);

  Future<Map<String, dynamic>> toggleDevice(int id) async {
    final r = await _raw('/api/mobile/devices/$id/toggle', method: 'PUT');
    return r.data is Map ? Map<String, dynamic>.from(r.data as Map) : {'ok': true};
  }

  Future<void> deleteDevice(int id) =>
      _mutate('/api/mobile/devices/$id', method: 'DELETE');

  // ── Users ──
  Future<List<dynamic>> getUsers() async {
    try {
      final r = await _dio.get('/api/mobile/users');
      if (r.statusCode == 200 && r.data is List) return r.data as List;
      if (r.statusCode == 403) throw ApiException('需要管理员权限', statusCode: 403);
      _throwApiError(r, fallback: '获取用户失败');
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '获取用户失败');
    }
    return [];
  }

  Future<Map<String, dynamic>> addUser(Map<String, dynamic> d) async {
    final r = await _raw('/api/mobile/users', method: 'POST', data: d);
    final body = r.data;
    if (body is Map && body['ok'] == false) {
      throw ApiException(body['msg']?.toString() ?? '操作失败',
          statusCode: r.statusCode);
    }
    return body is Map ? Map<String, dynamic>.from(body as Map) : {'ok': true};
  }

  Future<void> updateUser(int id, Map<String, dynamic> d) =>
      _mutate('/api/mobile/users/$id', method: 'PUT', data: d);

  Future<Map<String, dynamic>> toggleUser(int id) async {
    final r = await _raw('/api/mobile/users/$id/toggle', method: 'PUT');
    return r.data is Map ? Map<String, dynamic>.from(r.data as Map) : {'ok': true};
  }

  Future<void> deleteUser(int id) =>
      _mutate('/api/mobile/users/$id', method: 'DELETE');

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _mutate('/api/mobile/change-password',
        method: 'POST',
        data: {'old_password': oldPassword, 'new_password': newPassword});
  }


  // ── 网页观看开关 ──
  Future<bool> getWebVideoEnabled() async {
    try {
      final r = await _dio.get('/api/settings');
      if (r.statusCode == 200 && r.data is Map) {
        return (r.data as Map)['web_video_enabled'] == 1 ||
            (r.data as Map)['web_video_enabled'] == true;
      }
    } on DioException catch (e) {
      throw _mapDio(e, fallback: '获取设置失败');
    }
    return true;
  }

  Future<bool> setWebVideoEnabled(bool enabled) async {
    await _mutate('/api/settings/web_video',
        method: 'PUT', data: {'value': enabled ? 1 : 0});
    return enabled;
  }

  // ── 版本 ──
  Future<Map<String, dynamic>?> checkVersion() async {
    try {
      final r = await Dio(BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      )).get('/api/app/version');
      if (r.statusCode == 200 && r.data is Map) {
        return Map<String, dynamic>.from(r.data as Map);
      }
    } catch (_) {}
    return null;
  }

  /// 把相对的 /proxy/... 补成绝对地址。
  String absoluteUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('/')) return '$_baseUrl$path';
    return '$_baseUrl/$path';
  }

  // ── internals ──
  Future<Response> _raw(String path, {String method = 'GET', data}) async {
    try {
      final r = await _dio.request<dynamic>(
        path,
        data: data,
        options: Options(method: method),
      );
      if (r.statusCode == 401) {
        await clearAuth();
        throw ApiException('登录已过期，请重新登录', statusCode: 401);
      }
      if (r.statusCode == 403) {
        throw ApiException('没有权限执行该操作', statusCode: 403);
      }
      if (r.statusCode != null && r.statusCode! >= 400) {
        _throwApiError(r);
      }
      return r;
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  Future<void> _mutate(String path, {String method = 'GET', data}) async {
    final r = await _raw(path, method: method, data: data);
    final body = r.data;
    if (body is Map && body['ok'] == false) {
      throw ApiException(body['msg']?.toString() ?? '操作失败',
          statusCode: r.statusCode);
    }
  }

  ApiException _mapDio(DioException e, {String fallback = '网络错误'}) {
    if (e.error is ApiException) return e.error as ApiException;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException('网络超时，请检查网络或服务器地址', statusCode: e.response?.statusCode);
      case DioExceptionType.connectionError:
        return ApiException('无法连接服务器，请检查网络和服务器地址', statusCode: null);
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 401) return ApiException('登录已过期，请重新登录', statusCode: 401);
        if (code == 403) return ApiException('没有权限或签名已过期', statusCode: 403);
        if (code == 404) return ApiException('接口不存在，请确认服务器版本', statusCode: 404);
        final data = e.response?.data;
        if (data is Map && data['msg'] is String) {
          return ApiException(data['msg'] as String, statusCode: code);
        }
        return ApiException('$fallback (HTTP $code)', statusCode: code);
      default:
        return ApiException(fallback, statusCode: e.response?.statusCode);
    }
  }
}

/// HLS / 通用 HTTP 错误的用户可读描述（video_player 失败时用）。
String describePlayError(Object error) {
  final text = error.toString();
  if (text.contains('401') || text.contains('Unauthorized')) {
    return '认证失败，请重新登录';
  }
  if (text.contains('403') || text.contains('forbidden') || text.contains('bad stream token')) {
    return '播放凭证无效或已过期，请重试';
  }
  if (text.contains('502') || text.contains('stream offline')) {
    return '视频源离线，请检查编码器或线路';
  }
  if (text.contains('504') || text.contains('stream timeout') || text.contains('Timeout')) {
    return '拉流超时，请检查网络';
  }
  if (text.contains('SocketException') || text.contains('Connection')) {
    return '网络连接失败';
  }
  return '视频加载失败';
}
