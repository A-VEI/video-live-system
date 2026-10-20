import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';
import 'services/update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    if (api.phone != null) {
      setState(() { _loggedIn = true; _loading = false; });
      _checkAppUpdate();
      return;
    }
    setState(() { _loading = false; });
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
