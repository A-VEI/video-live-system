import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../config.dart';
import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _serverCtrl = TextEditingController(text: ApiClient.instance.baseUrl);
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = ApiClient.instance.baseUrl;
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (phone.length != 11) {
      setState(() => _error = '请输入11位手机号');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入口令');
      return;
    }
    final server = _serverCtrl.text.trim();
    if (server.isEmpty || !server.startsWith('http://')) {
      setState(() => _error = '服务器地址须以 http:// 开头（本项目使用 HTTP）');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiClient.instance.setBaseUrl(server);
      final data = await ApiClient.instance.login(phone, password);
      if (data['ok'] == true && mounted) {
        if (data['must_change_password'] == true) {
          final changed = await showChangePasswordDialog(context, force: true);
          if (changed != true) {
            await ApiClient.instance.clearAuth();
            return;
          }
        }
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
          );
        }
      } else {
        setState(() => _error = data['msg']?.toString() ?? '登录失败');
      }
    } catch (e) {
      setState(() => _error = e is ApiException ? e.message : '登录失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showServerSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务器地址',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('默认: $kDefaultBaseUrl',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 16),
            TextField(
              controller: _serverCtrl,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'http://主机:端口',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.dns),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {});
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child:
                    const Icon(Icons.play_arrow, color: Colors.white, size: 32),
              ),
              const SizedBox(height: 24),
              Text(
                '视频直播系统',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('手机号 + 口令登录',
                  style: TextStyle(color: Colors.grey[600], fontSize: 14)),
              const SizedBox(height: 32),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                decoration: InputDecoration(
                  labelText: '手机号',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.phone),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '口令',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => _login(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _loading ? null : _login,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('登录', style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _showServerSheet,
                icon: const Icon(Icons.settings_ethernet, size: 18),
                label: Text(
                  '服务器: ${_serverCtrl.text}',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.red[700], fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 修改口令对话框。force=true 时不允许取消。
/// 返回 true 表示已成功改密。
Future<bool?> showChangePasswordDialog(BuildContext context,
    {bool force = false}) async {
  final oldCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  String? error;
  bool loading = false;
  bool obscure = true;

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: !force,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(force ? '请修改初始口令' : '修改口令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (force)
              const Text(
                '为了安全，首次登录必须修改口令。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            TextField(
              controller: oldCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '原口令'),
            ),
            TextField(
              controller: newCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '新口令（至少8位）'),
            ),
            TextField(
              controller: confirmCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '确认新口令'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
        actions: [
          if (!force)
            TextButton(
              onPressed: loading ? null : () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
          FilledButton(
            onPressed: loading
                ? null
                : () async {
                    if (newCtrl.text != confirmCtrl.text) {
                      setLocal(() => error = '两次输入不一致');
                      return;
                    }
                    setLocal(() {
                      loading = true;
                      error = null;
                    });
                    try {
                      await ApiClient.instance
                          .changePassword(oldCtrl.text, newCtrl.text);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setLocal(() {
                        loading = false;
                        error = e is ApiException ? e.message : '修改失败';
                      });
                    }
                  },
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ],
      ),
    ),
  );
  return result;
}
