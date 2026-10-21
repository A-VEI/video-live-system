import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../config.dart';
import '../services/endpoint_probe.dart';
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _idx = 0;
  String _name = '';
  String _role = 'user';
  bool _loadingMe = true;
  bool _switchingIsp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _name = ApiClient.instance.displayName ?? '';
    _role = ApiClient.instance.role;
    _loadMe();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台再回来刷新，避免白屏
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
    }
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

  Future<void> _quickSwitchIsp() async {
    if (_switchingIsp) return;
    final cur = matchEndpoint(ApiClient.instance.baseUrl);
    final ep = await showModalBottomSheet<ServerEndpoint>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('网络出口',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('切换后需重新登录'),
            ),
            for (final e in kServerEndpoints)
              RadioListTile<String>(
                title: Text('${e.label}  ${e.host}'),
                subtitle: e == cur ? const Text('当前') : null,
                value: e.id,
                groupValue: cur?.id,
                onChanged: (_) => Navigator.pop(ctx, e),
              ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _autoPickIsp();
              },
              child: const Text('自动测速选优'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (ep == null || !mounted) return;
    if (ep.baseUrl == ApiClient.instance.baseUrl) return;
    setState(() => _switchingIsp = true);
    await ApiClient.instance.setBaseUrl(ep.baseUrl);
    await ApiClient.instance.clearAuth();
    if (!mounted) return;
    setState(() => _switchingIsp = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${ep.label}，请重新登录')),
    );
    _gotoLogin();
  }

  Future<void> _autoPickIsp() async {
    if (!mounted) return;
    setState(() => _switchingIsp = true);
    final best = await EndpointProbe.bestForLive();
    if (!mounted) return;
    setState(() => _switchingIsp = false);
    if (best == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('测速失败，出口均不可用')),
      );
      return;
    }
    if (best.baseUrl == ApiClient.instance.baseUrl) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前已是更优出口：${best.label}')),
      );
      return;
    }
    await ApiClient.instance.setBaseUrl(best.baseUrl);
    await ApiClient.instance.clearAuth();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已自动切换到 ${best.label}，请重新登录')),
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
    Navigator.of(context).pop();
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
              title: const Text('网络出口'),
              subtitle: Text(
                matchEndpoint(ApiClient.instance.baseUrl)?.label ?? '自定义',
              ),
              onTap: () {
                Navigator.pop(ctx);
                _quickSwitchIsp();
              },
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              subtitle: const Text('手动检查并安装新版本'),
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

  Widget _ispChip() {
    final cur = matchEndpoint(ApiClient.instance.baseUrl);
    return TextButton.icon(
      onPressed: _switchingIsp ? null : _quickSwitchIsp,
      icon: _switchingIsp
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.swap_horiz, size: 18),
      label: Text(
        cur?.label ?? '出口',
        style: const TextStyle(fontSize: 13),
      ),
      style: TextButton.styleFrom(
        foregroundColor: Colors.black87,
        backgroundColor: Colors.black.withOpacity(0.06),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
        titleSpacing: 8,
        title: Row(
          children: [
            const Text('Live', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            _ispChip(),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: pages[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          if (i < pages.length) setState(() => _idx = i);
        },
        items: items,
      ),
    );
  }
}
