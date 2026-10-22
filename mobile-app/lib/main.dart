import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiClient.init();
  runApp(const VideoApp());
}

class VideoApp extends StatelessWidget {
  const VideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2563EB),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const AuthGate(),
      routes: {
        '/home': (_) => const HomePage(),
        '/login': (_) => const LoginPage(),
      },
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
    if (api.isLoggedIn) {
      // 校验 token 是否仍有效
      try {
        final me = await api.me();
        final mustChange = me['must_change_password'] == true;
        if (!mounted) return;
        if (mustChange) {
          // 强制改密后再进主页
          setState(() { _loading = false; });
          final changed = await showChangePasswordDialog(context, force: true);
          if (changed == true) {
            setState(() { _loggedIn = true; });
          } else {
            await api.clearAuth();
            setState(() { _loggedIn = false; });
          }
        } else {
          setState(() { _loggedIn = true; _loading = false; });
        }
      } catch (_) {
        // token 失效 → 用记住的口令自动登录
        await api.clearAuth();
        final saved = await api.trySavedLogin();
        if (mounted) {
          setState(() {
            _loggedIn = saved != null && saved['ok'] == true;
            _loading = false;
          });
        }
      }
    } else {
      // 未登录：尝试用记住的账号口令自动登录
      final saved = await api.trySavedLogin();
      if (mounted) {
        setState(() {
          _loggedIn = saved != null && saved['ok'] == true;
          _loading = false;
        });
      }
    }
    _checkAppUpdate();
  }

  // 不再自动弹更新；仅在设置里手动检查（带小红点提示）
  void _checkAppUpdate() {}

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _loggedIn ? const HomePage() : const LoginPage();
  }
}
