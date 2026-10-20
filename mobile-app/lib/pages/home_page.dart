import 'package:flutter/material.dart';
import '../api/api_client.dart';
import 'login_page.dart';
import 'video_page.dart';
import 'devices_page.dart';
import 'users_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _idx = 0;
  String _name = '';
  String _role = 'user';

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    try {
      final me = await ApiClient.instance.me();
      setState(() { _name = me['name'] ?? ''; _role = me['role'] ?? 'user'; });
    } catch (_) {}
  }

  Future<void> _logout() async {
    await ApiClient.instance.clearToken();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    }
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
      if (isAdmin) const BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设备'),
      if (isAdmin) const BottomNavigationBarItem(icon: Icon(Icons.people), label: '用户'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('视频直播系统', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'logout') _logout(); },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'profile',
                enabled: false,
                child: Text(_name.isNotEmpty ? _name : '用户', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Text(_name.isNotEmpty ? _name[0] : 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
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
