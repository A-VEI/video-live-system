import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../config.dart';
import 'home_page.dart';

/// 登录页：对外不暴露「手机号登录」等提示，避免无关人员猜到用法
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _userCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = _userCtrl.text.trim();
    final secret = _secretCtrl.text;
    if (user.isEmpty || secret.isEmpty) {
      setState(() => _error = '请填写凭据');
      return;
    }
    // 长度校验不提示「11 位手机号」
    if (user.length < 6 || user.length > 32) {
      setState(() => _error = '验证失败');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.instance.login(user, secret);
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
        setState(() => _error = '验证失败');
      }
    } catch (e) {
      // 统一失败文案，不区分「未注册 / 口令错」
      setState(() => _error = '验证失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showLineSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('接入线路', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final e in kServerEndpoints)
              ListTile(
                leading: Icon(
                  matchEndpoint(ApiClient.instance.baseUrl)?.id == e.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(e.label),
                onTap: () async {
                  Navigator.pop(ctx);
                  await ApiClient.instance.setBaseUrl(e.baseUrl);
                  await ApiClient.instance.clearAuth();
                  if (mounted) setState(() {});
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
    final line = matchEndpoint(ApiClient.instance.baseUrl)?.label ?? '默认线路';
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E3A8A), Color(0xFF0F172A)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.play_circle_outline,
                      color: Colors.white, size: 40),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Live',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '授权后可进入',
                  style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: _userCtrl,
                  keyboardType: TextInputType.text,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '标识',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                    prefixIcon:
                        Icon(Icons.perm_identity, color: Colors.white.withOpacity(0.5)),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.08),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _secretCtrl,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '密钥',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                    prefixIcon:
                        Icon(Icons.vpn_key_outlined, color: Colors.white.withOpacity(0.5)),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white.withOpacity(0.45),
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.08),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('进入', style: TextStyle(fontSize: 16)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      style: TextStyle(
                          color: Colors.red.shade300, fontSize: 13)),
                ],
                const SizedBox(height: 28),
                TextButton.icon(
                  onPressed: _showLineSheet,
                  icon: Icon(Icons.cell_tower,
                      size: 16, color: Colors.white.withOpacity(0.45)),
                  label: Text(
                    line,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.45), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 修改凭据对话框
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
        title: Text(force ? '请更新访问密钥' : '修改密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (force)
              const Text(
                '首次进入需要设置新的访问密钥。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            TextField(
              controller: oldCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '当前密钥'),
            ),
            TextField(
              controller: newCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '新密钥（至少8位）'),
            ),
            TextField(
              controller: confirmCtrl,
              obscureText: obscure,
              decoration: const InputDecoration(labelText: '确认新密钥'),
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
