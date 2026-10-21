import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../config.dart';
import '../services/update_service.dart';
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

  Future<void> _pickIsp(BuildContext context) async {
    final cur = matchEndpoint(ApiClient.instance.baseUrl);
    final ep = await showModalBottomSheet<ServerEndpoint>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('网络出口', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('优先自动选优，也可手动锁定'),
            ),
            for (final e in kServerEndpoints)
              RadioListTile<String>(
                title: Text('${e.label}  ${e.host}'),
                value: e.id,
                groupValue: cur?.id,
                onChanged: (_) => Navigator.pop(ctx, e),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (ep == null || !mounted) return;
    await ApiClient.instance.setBaseUrl(ep.baseUrl);
    await ApiClient.instance.clearAuth();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${ep.label}，请重新登录')),
    );
    _gotoLogin();
  }

  Future<void> _manualUpdate() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final update = await UpdateService.checkUpdate();
    if (!mounted) return;
    Navigator.of(context).pop(); // close loading
    if (update == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本')),
      );
      return;
    }
    showUpdateDialog(context, update);
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(_name.isNotEmpty ? _name : '用户'),
              subtitle: Text('$_role · ${ApiClient.instance.baseUrl}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('切换网络出口'),
              subtitle: Text(matchEndpoint(ApiClient.instance.baseUrl)?.label ?? '自定义'),
              onTap: () {
                Navigator.pop(ctx);
                _pickIsp(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              onTap: () {
                Navigator.pop(ctx);
                _manualUpdate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_reset),
              title: const Text('修改口令'),
              onTap: () {
                Navigator.pop(ctx);
                showChangePasswordDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('退出登录', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _logout();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
      const BottomNavigationBarItem(
        icon: Icon(Icons.live_tv),
        activeIcon: Icon(Icons.live_tv),
        label: '直播',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.settings_outlined),
        activeIcon: Icon(Icons.settings),
        label: '设置',
      ),
      if (isAdmin)
        const BottomNavigationBarItem(
          icon: Icon(Icons.router_outlined),
          activeIcon: Icon(Icons.router),
          label: '设备',
        ),
      if (isAdmin)
        const BottomNavigationBarItem(
          icon: Icon(Icons.group_outlined),
          activeIcon: Icon(Icons.group),
          label: '用户',
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: false,
      ),
      body: pages[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          // 中间「设置」不切页，弹出面板
          if (i == 1) {
            _openSettings();
            return;
          }
          // 0=直播, 2=设备, 3=用户  →  页面 0,1,2
          setState(() => _idx = i == 0 ? 0 : i - 1);
        },
        items: items,
      ),
    );
  }
}
