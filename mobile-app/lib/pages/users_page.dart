import 'package:flutter/material.dart';
import '../api/api_client.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<dynamic> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ApiClient.instance.getUsers();
      setState(() { _users = data; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _toggle(int id) async {
    try {
      await ApiClient.instance.toggleUser(id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }

  Future<void> _showEdit({Map<String, dynamic>? user}) async {
    final phoneCtrl = TextEditingController(text: user?['phone'] ?? '');
    final nameCtrl = TextEditingController(text: user?['name'] ?? '');
    String role = user?['role'] ?? 'user';

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(user == null ? '添加用户' : '编辑用户'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: phoneCtrl,
                keyboardType: TextInputType.phone, maxLength: 11,
                decoration: const InputDecoration(labelText: '手机号', counterText: ''),
                enabled: user == null),
              const SizedBox(height: 12),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '姓名')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: role,
                decoration: const InputDecoration(labelText: '角色'),
                items: const [
                  DropdownMenuItem(value: 'user', child: Text('用户')),
                  DropdownMenuItem(value: 'admin', child: Text('管理员')),
                ],
                onChanged: (v) => setDialogState(() => role = v ?? 'user'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );

    if (result == true) {
      final data = {
        'phone': phoneCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'role': role,
        'enabled': 1,
      };
      try {
        if (user == null) {
          await ApiClient.instance.addUser(data);
        } else {
          await ApiClient.instance.updateUser(user['id'], data);
        }
        _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  Future<void> _delete(int id, String phone) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除用户 $phone 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await ApiClient.instance.deleteUser(id);
        _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      body: ListView.builder(
        itemCount: _users.length,
        itemBuilder: (_, i) {
          final u = _users[i];
          final enabled = u['enabled'] == 1;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              title: Text(u['phone'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(u['name']?.isNotEmpty == true ? u['name'] : '—',
                style: const TextStyle(fontSize: 13)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(value: enabled, onChanged: (_) => _toggle(u['id'])),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () => _showEdit(user: u),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                    onPressed: () => _delete(u['id'], u['phone'] ?? ''),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEdit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}
