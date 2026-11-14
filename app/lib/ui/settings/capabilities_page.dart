import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/capabilities_state.dart';
import '../browser/browser_page.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 能力控制: one page for every capability this build adds. The switches are
/// what the rest of the app reads before it uses a capability, so 全部暂停
/// stops them all at once.
class CapabilitiesPage extends ConsumerWidget {
  const CapabilitiesPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const CapabilitiesPage());

  static const _labels = <String, (String, String)>{
    'browser': ('浏览器', '让助手在 App 内打开网页、读页面、点按'),
    'notify': ('通知', '读取通知、摘要、按规则处理'),
    'automation': ('自动化', '定时任务和状态触发'),
    'screen': ('屏幕控制', '连续读屏、受控点击'),
    'files': ('文件', '选择文件、批量整理、归档'),
    'voice': ('语音', '唤醒词、朗读、免提'),
    'memory': ('记忆', '记住偏好和常用文件'),
    'plugins': ('插件权限', '允许插件调用上面的能力'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    return AppPage.list(
      title: '能力控制',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '这里集中管理新增的能力。关掉一项，用到它的功能就会停下。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsSection(
          title: '打开',
          children: [
            SettingsTile(
              key: const ValueKey('cap-open-browser'),
              title: '内置浏览器',
              subtitle: 'App 自己的浏览器，登录态与手机浏览器分开',
              onTap: () => Navigator.of(context).push(BrowserPage.route()),
            ),
          ],
        ),
        SettingsSection(
          title: '能力',
          children: [
            for (final key in CapabilitiesController.keys)
              SettingsSwitchTile(
                key: ValueKey('cap-$key'),
                title: _labels[key]?.$1 ?? key,
                subtitle: _labels[key]?.$2,
                value: caps[key] ?? true,
                onChanged: (v) => unawaited(ref.read(capabilitiesProvider.notifier).set(key, v)),
              ),
          ],
        ),
        SettingsSection(
          title: '全部',
          children: [
            SettingsTile(
              key: const ValueKey('cap-pause-all'),
              title: '全部暂停',
              subtitle: '一次性关掉上面所有能力',
              onTap: () => unawaited(ref.read(capabilitiesProvider.notifier).pauseAll()),
            ),
          ],
        ),
      ],
    );
  }
}
