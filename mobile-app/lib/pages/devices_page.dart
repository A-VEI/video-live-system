import 'package:flutter/material.dart';
import '../api/api_client.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<dynamic> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ApiClient.instance.getDevices();
      setState(() { _devices = data; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '加载失败')),
      );
    }
  }

  Future<void> _toggle(int id) async {
    try {
      await ApiClient.instance.toggleDevice(id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }

  Future<void> _showEdit({Map<String, dynamic>? device}) async {
    final nameCtrl = TextEditingController(text: device?['name'] ?? '');
    final urlCtrl = TextEditingController(text: device?['url'] ?? '');
    final sortCtrl = TextEditingController(text: '${device?['sort'] ?? 0}');

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(device == null ? '添加设备' : '编辑设备'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '设备名称')),
            const SizedBox(height: 12),
            TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: '流地址')),
            const SizedBox(height: 12),
            TextField(controller: sortCtrl, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '排序')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );

    if (result == true) {
      final data = {
        'name': nameCtrl.text.trim(),
        'url': urlCtrl.text.trim(),
        'sort': int.tryParse(sortCtrl.text) ?? 0,
        'enabled': 1,
      };
      try {
        if (device == null) {
          await ApiClient.instance.addDevice(data);
        } else {
          await ApiClient.instance.updateDevice(device['id'], data);
        }
        _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  Future<void> _delete(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除「$name」吗？'),
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
        await ApiClient.instance.deleteDevice(id);
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
        itemCount: _devices.length,
        itemBuilder: (_, i) {
          final d = _devices[i];
          final enabled = d['enabled'] == 1;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              title: Text(d['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(d['url'] ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(value: enabled, onChanged: (_) => _toggle(d['id'])),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () => _showEdit(device: d),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                    onPressed: () => _delete(d['id'], d['name'] ?? ''),
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
