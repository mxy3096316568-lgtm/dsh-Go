// 授权记录：谁被「总是允许」了、什么时候、能不能撤销。
//
// 记录只在本机：删掉一条，下一次同样的动作就会重新问。手机操控的「免确认」不在这
// 张表里，它归手机操控自己的确认方式管，这一页放一个跳过去的入口。
import 'package:flutter/material.dart';

import '../../state/consent_store.dart';
import '../phone/phone_control_screen.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

String _when(int ms) {
  if (ms <= 0) return '';
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.month}月${at.day}日 ${two(at.hour)}:${two(at.minute)}';
}

class ConsentPage extends StatefulWidget {
  const ConsentPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const ConsentPage());

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  List<ConsentGrant> _grants = const <ConsentGrant>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConsentStore.instance.load();
    if (mounted) setState(() => _grants = ConsentStore.instance.grants);
  }

  Future<void> _revoke(ConsentGrant grant) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这条授权？'),
        content: Text('撤销后，下一次「${grant.label}」会重新问你。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ConsentStore.instance.revoke(grant.id);
    await _load();
  }

  Future<void> _revokeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除全部授权？'),
        content: const Text('所有「总是允许」都会失效，之后每个动作都会重新问一次。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('全部清除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ConsentStore.instance.revokeAll();
    await _load();
  }

  /// `工具审批 · 11月14日 21:20 · 依赖：files`；能力开关关掉时补一句已失效。
  String _lineFor(ConsentGrant grant) {
    return [
      grant.kind == 'tool' ? '工具审批' : (grant.kind == 'upload' ? '上传到站点' : grant.kind),
      if (_when(grant.createdAtMs).isNotEmpty) _when(grant.createdAtMs),
      if (grant.requires.isNotEmpty) '依赖：${grant.requires.join('/')}',
      if (!ConsentStore.instance.live(grant)) '已失效（能力已关）',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final sensitive = _grants.where((grant) => grant.sensitive).toList();
    final normal = _grants.where((grant) => !grant.sensitive).toList();
    return AppPage.list(
      title: '授权记录',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '「总是允许」都记在这里，只在这个手机上有效。关掉对应的能力开关（浏览器/文件/云盘/通知），'
            '相关授权会一起失效；撤销一条，下一次同样的动作会重新问你。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsSection(
          title: '授权',
          children: [
            if (_grants.isEmpty)
              SettingsTile(
                title: '还没有永久授权',
                subtitle: '审批卡和上传确认里点「总是允许」才会出现在这里',
              ),
            for (final grant in normal)
              SettingsTile(
                key: ValueKey('consent-${grant.id}'),
                title: grant.label,
                subtitle: _lineFor(grant),
                trailing: TextButton(
                  onPressed: () => _revoke(grant),
                  child: const Text('撤销'),
                ),
              ),
          ],
        ),
        if (sensitive.isNotEmpty)
          SettingsSection(
            title: '对外发送（建议用完就撤）',
            children: [
              for (final grant in sensitive)
                SettingsTile(
                  key: ValueKey('consent-${grant.id}'),
                  icon: AppIcons.share,
                  title: grant.label,
                  subtitle: _lineFor(grant),
                  danger: true,
                  trailing: TextButton(
                    onPressed: () => _revoke(grant),
                    child: const Text('撤销'),
                  ),
                ),
            ],
          ),
        SettingsSection(
          title: '手机操控',
          children: [
            SettingsTile(
              key: const ValueKey('consent-phone'),
              icon: AppIcons.phoneControl,
              title: '手机操控的免确认',
              subtitle: '它有自己的确认方式（每次询问 / 本任务 / 始终免确认），点这里去改',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PhoneControlScreen()),
              ),
            ),
          ],
        ),
        if (_grants.isNotEmpty)
          SettingsSection(
            title: '全部',
            children: [
              SettingsTile(
                key: const ValueKey('consent-revoke-all'),
                title: '全部清除',
                subtitle: '一次清掉所有「总是允许」，之后每个动作都会重新问',
                onTap: _revokeAll,
              ),
            ],
          ),
      ],
    );
  }
}
