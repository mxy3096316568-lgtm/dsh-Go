import 'package:flutter/material.dart';

import '../browser/webdav_client.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 云盘: the WebDAV account the assistant uses to browse, upload and download
/// the person's own cloud drive (坚果云 / Nextcloud / NAS…).
///
/// The password is kept in the platform keystore, never in preferences.
class WebdavPage extends StatefulWidget {
  const WebdavPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const WebdavPage());

  @override
  State<WebdavPage> createState() => _WebdavPageState();
}

class _WebdavPageState extends State<WebdavPage> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await WebdavConfig.load(force: true);
    if (!mounted) return;
    setState(() {
      _address.text = WebdavConfig.address;
      _user.text = WebdavConfig.user;
      _password.text = '';
    });
    // The stored password is filled in (hidden behind dots), so a test or a
    // re-save works without typing it again.
    final stored = await WebdavConfig.password();
    if (!mounted) return;
    setState(() {
      if (stored.isNotEmpty) _password.text = stored;
    });
  }

  void _say(String text, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _failed = failed;
    });
  }

  Future<bool> _save() async {
    final address = _address.text.trim();
    if (!address.startsWith('http://') && !address.startsWith('https://')) {
      _say('地址要以 https:// 或 http:// 开头', failed: true);
      return false;
    }
    if (_password.text.isEmpty) {
      _say('填一下密码（或应用专用密码）', failed: true);
      return false;
    }
    await WebdavConfig.save(address: address, user: _user.text, password: _password.text);
    _say('已保存');
    return true;
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      if (!await _save()) return;
      final result = await WebdavClient.list('/');
      if (result is Map && result['error'] != null) {
        _say('${result['message'] ?? result['error']}', failed: true);
        return;
      }
      final entries = (result as Map)['entries'] as List? ?? const [];
      final names = entries.take(3).map((e) => '${(e as Map)['name']}').join('、');
      _say(entries.isEmpty
          ? '连上了，这个目录是空的'
          : '连上了：${entries.length} 项${names.isEmpty ? '' : '（$names…）'}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除云盘账号'),
        content: const Text('会从这台手机上删掉地址、账号和密码，云端的文件不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await WebdavConfig.clear();
    if (!mounted) return;
    setState(() {
      _address.clear();
      _user.clear();
      _password.clear();
      _message = '已删除';
      _failed = false;
    });
  }

  Widget _field(String label, TextEditingController controller, {bool secret = false, String? hint}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: TextField(
        controller: controller,
        obscureText: secret,
        autocorrect: false,
        enableSuggestions: !secret,
        keyboardType: secret ? TextInputType.visiblePassword : TextInputType.url,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppPage.list(
      title: '云盘',
      subtitle: const Text('连接自己的 WebDAV 网盘，让助手帮忙整理文件'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '支持坚果云、Nextcloud、群晖 NAS 等 WebDAV 服务。地址填到目录一级，例如 https://dav.jianguoyun.com/dav/。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        SettingsSection(
          title: '地址',
          children: [
            _field('WebDAV 地址', _address, hint: 'https://dav.example.com/dav/'),
            _field('账号', _user, hint: '邮箱或用户名'),
            _field('密码', _password, secret: true, hint: '坚果云用「应用密码」'),
          ],
        ),
        SettingsSection(
          title: '连接',
          children: [
            SettingsTile(
              key: const ValueKey('dav-save'),
              icon: Icons.check,
              title: '保存',
              subtitle: '只存在这台手机上，密码进系统钥匙串',
              onTap: _busy ? null : () => _save(),
            ),
            SettingsTile(
              key: const ValueKey('dav-test'),
              icon: Icons.wifi_tethering,
              title: _busy ? '正在连接…' : '测试连接',
              subtitle: '保存并发一次目录请求，确认账号能用',
              onTap: _busy ? null : _test,
            ),
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              _message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _failed ? theme.colorScheme.error : theme.colorScheme.primary,
              ),
            ),
          ),
        SettingsSection(
          title: '账号',
          children: [
            SettingsTile(
              key: const ValueKey('dav-forget'),
              icon: Icons.link_off,
              title: '删除账号',
              danger: true,
              subtitle: '只删本机保存的登录信息',
              onTap: _forget,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
            '给助手的工具：webdav_ls（浏览）、webdav_upload（上传）、webdav_download（下载）、webdav_search（搜索）。下载的文件放在 下载/DSH-Go/webdav。',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
