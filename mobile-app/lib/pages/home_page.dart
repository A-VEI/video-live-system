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
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  List<EndpointHealth> _health = [];
  int _idx = 0;
  String _name = '';
  String _role = 'user';
  bool _loadingMe = true;
  bool _switchingIsp = false;
  bool _webVideo = true;
  bool _hasUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _name = ApiClient.instance.displayName ?? '';
    _role = ApiClient.instance.role;
    _loadMe();
    _loadWebVideo();
    _checkUpdateSilently();
    _probeLines();
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

  Future<void> _loadWebVideo() async {
    if (!ApiClient.instance.isAdmin) return;
    try {
      final v = await ApiClient.instance.getWebVideoEnabled();
      if (mounted) setState(() => _webVideo = v);
    } catch (_) {}
  }

  bool _webVideoSaving = false;

  /// 点开关 → 转圈等服务器 → 成功后才改 UI
  Future<void> _toggleWebVideo(bool v) async {
    if (_webVideoSaving) return;
    setState(() => _webVideoSaving = true);
    try {
      await ApiClient.instance.setWebVideoEnabled(v);
      if (!mounted) return;
      setState(() {
        _webVideo = v;
        _webVideoSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(v ? '已允许网页观看' : '已关闭网页观看，请用 App')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _webVideoSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '设置失败')),
      );
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
                title: Text(e.label),
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
    // 用记住的账号自动登录
    final ok = await ApiClient.instance.trySavedLogin();
    if (!mounted) return;
    setState(() => _switchingIsp = false);
    if (ok != null && ok['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 ${ep.label}，自动登录成功')),
      );
      setState(() {
        _name = ok['name']?.toString() ?? _name;
        _role = ok['role']?.toString() ?? _role;
        _idx = 0;
      });
      return;
    }
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
    final ok = await ApiClient.instance.trySavedLogin();
    if (!mounted) return;
    if (ok != null && ok['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已自动切换到 ${best.label}，自动登录成功')),
      );
      setState(() {
        _name = ok['name']?.toString() ?? _name;
        _role = ok['role']?.toString() ?? _role;
        _idx = 0;
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已自动切换到 ${best.label}，请重新登录')),
    );
    _gotoLogin();
  }

  Future<void> _checkUpdateSilently() async {
    try {
      final r = await UpdateService.check();
      if (mounted) setState(() => _hasUpdate = r.hasUpdate);
    } catch (_) {}
  }

  Future<void> _manualUpdate() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final r = await UpdateService.check();
    if (!mounted) return;
    Navigator.of(context).pop();
    setState(() => _hasUpdate = r.hasUpdate);
    if (!r.hasUpdate) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已是最新 · ${r.reason}')),
      );
      return;
    }
    showUpdateDialog(context, {
      'update_url': r.updateUrl,
      'sha256': r.sha256,
      'notes': r.notes,
      'reason': r.reason,
      'label': r.serverBuildTime > 0
          ? r.serverBuildTime.toString()
          : r.serverBuildId.toString(),
    });
  }

  Future<void> _probeLines() async {
    try {
      final list = await EndpointProbe.probeAll();
      if (mounted) setState(() => _health = list);
    } catch (_) {}
  }

  String _buildLabel() {
    if (kBuildTime > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(kBuildTime * 1000);
      String p2(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
    }
    return kBuildId > 0 ? '#$kBuildId' : '—';
  }

  /// 分享：展示下载二维码
  void _showShareQr() {
    final qrUrl = '${ApiClient.instance.baseUrl}/qr.png';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('分享下载',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  qrUrl,
                  width: 220,
                  height: 220,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(child: Text('二维码加载失败')),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('扫码安装客户端',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右侧抽屉：设置
  Widget _buildSettingsDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const DrawerHeader(
              margin: EdgeInsets.zero,
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.settings, size: 32),
                  SizedBox(height: 8),
                  Text('设置',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(_name.isNotEmpty ? _name : '用户'),
              subtitle: Text(
                  '$_role · ${matchEndpoint(ApiClient.instance.baseUrl)?.label ?? '自定义线路'}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('网络出口'),
              subtitle: Text(
                matchEndpoint(ApiClient.instance.baseUrl)?.label ?? '自定义',
              ),
              onTap: () {
                Navigator.pop(context);
                _quickSwitchIsp();
              },
            ),
            if (_role == 'admin')
              SwitchListTile(
                secondary: _webVideoSaving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.public),
                title: const Text('网页观看'),
                subtitle: _webVideoSaving
                    ? const Text('正在保存…')
                    : Text(_webVideo ? 'Web 端可播放' : '仅 App 可观看'),
                value: _webVideo,
                onChanged: _webVideoSaving ? null : _toggleWebVideo,
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('构建信息'),
              subtitle: Text(_buildLabel()),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: const Text('分享下载'),
              onTap: () {
                Navigator.pop(context);
                _showShareQr();
              },
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: Row(
                children: [
                  const Text('检查更新'),
                  if (_hasUpdate) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              onTap: () {
                Navigator.pop(context);
                _manualUpdate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_reset),
              title: const Text('修改密钥'),
              onTap: () {
                Navigator.pop(context);
                showChangePasswordDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('退出登录', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _logout();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _SpeedStrip() {
    if (_health.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('测速中…', style: TextStyle(fontSize: 11, color: Colors.grey[700])),
        ],
      );
    }
    final best = _health.isNotEmpty ? _health.first : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final h in _health)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: h.ok
                    ? (h.keepsUp ? Colors.green.shade50 : Colors.orange.shade50)
                    : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: h.ok
                      ? (h.keepsUp
                          ? Colors.green.shade300
                          : Colors.orange.shade300)
                      : Colors.red.shade200,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    h.ok ? Icons.speed : Icons.wifi_off,
                    size: 12,
                    color: h.ok
                        ? (h.keepsUp ? Colors.green : Colors.orange)
                        : Colors.red,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    h.ok
                        ? '${h.endpoint.label} ${h.segMs ?? h.apiMs}ms'
                        : '${h.endpoint.label} 不可用',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey[800],
                    ),
                  ),
                  if (best != null && h.endpoint.id == best.endpoint.id && h.ok)
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade600,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '推荐',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
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
      key: _scaffoldKey,
      endDrawer: _buildSettingsDrawer(),
      appBar: AppBar(
        titleSpacing: 8,
        title: Row(
          children: [
            const Text('Live', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Expanded(child: _SpeedStrip()),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.qr_code_2),
            onPressed: _showShareQr,
          ),
          Stack(
            children: [
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
              if (_hasUpdate)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
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
