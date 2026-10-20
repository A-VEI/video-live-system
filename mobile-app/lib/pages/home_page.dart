import 'package:flutter/material.dart';
import '../api/api_client.dart';
import 'login_page.dart';
import 'video_page.dart';
import 'devices_page.dart';
import 'users_page.dart';

// showChangePasswordDialog 定义于 login_page.dart

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _idx = 0;
  String _name = '';
  String _role = 'user';
  bool _loadingMe = true;

  @override
  void initState() {
    super.initState();
    _name = ApiClient.instance.displayName ?? '';
    _role = ApiClient.instance.role;
    _loadMe();
  }

  Future<void> _loadMe() async {
    try {
      final me = await ApiClient.instance.me();
      if (!mounted) return;
      setState(() {
        _name = me['name']?.toString() ?? _name;
        _role = me['role']?.toString() ?? _role;
        _loadingMe = false;
      });
    } catch (e) {
      if (!mounted) return;
      // token 失效则回登录页
      if (e is ApiException && e.statusCode == 401) {
        _gotoLogin();
        return;
      }
      setState(() => _loadingMe = false);
    }
  }

  void _gotoLogin() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  Future<void> _logout() async {
    await ApiClient.instance.clearAuth();
    _gotoLogin();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _role == 'admin';
    final pages = [
      const VideoPage(),
      if (isAdmin) const DevicesPage(),
      if (isAdmin) const UsersPage(),
    ];
    final items = [
      const BottomNavigationBarItem(icon: Icon(Icons.videocam), label: '视频'),
      if (isAdmin)
        const BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设备'),
      if (isAdmin)
        const BottomNavigationBarItem(icon: Icon(Icons.people), label: '用户'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('视频直播系统',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_loadingMe)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'logout') {
                  await _logout();
                } else if (v == 'password') {
                  await showChangePasswordDialog(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'profile',
                  enabled: false,
                  child: Text(
                    _name.isNotEmpty ? '$_name（$_role）' : '用户',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                PopupMenuItem(
                  value: 'server',
                  enabled: false,
                  child: Text(
                    '服务器: ${ApiClient.instance.baseUrl}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                const PopupMenuItem(
                    value: 'password', child: Text('修改口令')),
                const PopupMenuItem(value: 'logout', child: Text('退出登录')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    _name.isNotEmpty ? _name[0] : 'U',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: pages[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
        items: items,
      ),
    );
  }
}
