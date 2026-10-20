import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 默认服务器地址, 发布时改成实际地址
  await ApiClient.init(baseUrl: 'http://112.25.181.94:8119');
  runApp(const VideoApp());
}

class VideoApp extends StatelessWidget {
  const VideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '视频直播系统',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2563EB),
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: 'PingFang SC',
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final api = ApiClient.instance;
    if (api.token != null) {
      // 有 token 就直接进, 网络问题也不清 token
      try {
        final me = await api.me();
        if (me['ok'] == true) {
          setState(() { _loggedIn = true; _loading = false; });
          return;
        }
        // 只有明确 401 才清 token
      } catch (_) {
        // 网络错误, 保留 token 仍然进入
      }
      setState(() { _loggedIn = true; _loading = false; });
      return;
    }
    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _loggedIn ? const HomePage() : const LoginPage();
  }
}
