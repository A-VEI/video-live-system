import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'services/update_service.dart';

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
      title: '视频直播系统',
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
        await api.clearAuth();
        if (mounted) setState(() { _loggedIn = false; _loading = false; });
      }
    } else {
      if (mounted) setState(() { _loading = false; });
    }
    _checkAppUpdate();
  }

  void _checkAppUpdate() {
    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      final update = await UpdateService.checkUpdate();
      if (update != null && mounted) {
        showUpdateDialog(context, update);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _loggedIn ? const HomePage() : const LoginPage();
  }
}
