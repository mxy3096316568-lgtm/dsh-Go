import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_state.dart';
import '../../state/capabilities_state.dart';
import '../browser/browser_page.dart';
import '../keepalive/keepalive_bridge.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';
import 'webdav_page.dart';

/// 能力控制: one page for every capability this build adds. The switches are
/// what the rest of the app reads before it uses a capability, so 全部暂停
/// stops them all at once.
class CapabilitiesPage extends ConsumerWidget {
  const CapabilitiesPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const CapabilitiesPage());

  static const _labels = <String, (String, String)>{
    'browser': ('浏览器', '让助手在 App 内打开网页、读页面、点按'),
    'cloud': ('云盘', '连接自己的 WebDAV 云盘，浏览、上传、下载、搜索'),
    'keepalive': ('常驻', '后台保持引擎运行，被杀后自己回来'),
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
            SettingsTile(
              key: const ValueKey('cap-open-cloud'),
              title: '云盘',
              subtitle: 'WebDAV 网盘：地址、账号和密码',
              onTap: () => Navigator.of(context).push(WebdavPage.route()),
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
        const KeepAliveSection(),
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

/// 常驻: the foreground service, the battery whitelist and 开机自启 — the
/// three things that decide whether the assistant is still there tomorrow.
class KeepAliveSection extends ConsumerStatefulWidget {
  const KeepAliveSection({super.key});

  @override
  ConsumerState<KeepAliveSection> createState() => _KeepAliveSectionState();
}

class _KeepAliveSectionState extends ConsumerState<KeepAliveSection> {
  KeepAliveStatus _status = const KeepAliveStatus();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await KeepAliveBridge.status();
    final exempt = await ref.read(runtimeBridgeProvider).batteryExempt();
    if (!mounted) return;
    setState(() {
      _status = status;
      _ready = true;
      if (exempt != null && exempt != status.batteryExempt) {
        _status = KeepAliveStatus(
          boot: status.boot,
          service: status.service,
          batteryExempt: exempt,
          replayable: status.replayable,
        );
      }
    });
  }

  Future<void> _setBoot(bool value) async {
    final status = await KeepAliveBridge.setBoot(value);
    if (!mounted) return;
    setState(() => _status = status);
    if (value && !status.service) {
      // 开机自启 without a running engine has nothing to replay next time.
      final started = await KeepAliveBridge.ensureService();
      if (mounted) setState(() => _status = started);
    }
  }

  Future<void> _battery() async {
    await ref.read(runtimeBridgeProvider).requestBatteryExempt();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _refresh();
  }

  Future<void> _vendor() async {
    await ref.read(runtimeBridgeProvider).openVendorSettings('autostart');
  }

  Future<void> _ensure() async {
    final status = await KeepAliveBridge.ensureService();
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final service = _status.service;
    final exempt = _status.batteryExempt;
    return SettingsSection(
      title: '常驻',
      children: [
        SettingsTile(
          key: const ValueKey('keep-service'),
          title: '后台服务',
          subtitle: !_ready
              ? '正在检查…'
              : service
              ? '引擎正在后台运行'
              : '没有在运行，锁屏后可能被系统收走',
          value: Text(service ? '运行中' : '已停止'),
          onTap: service ? null : _ensure,
        ),
        SettingsTile(
          key: const ValueKey('keep-battery'),
          title: '电池白名单',
          subtitle: exempt ? '系统不会因为省电杀掉它' : '系统可能因为省电把它清掉，点一下去开启',
          value: Text(exempt ? '已豁免' : '未设置'),
          onTap: _battery,
        ),
        SettingsTile(
          key: const ValueKey('keep-vendor'),
          title: '系统自启动与后台限制',
          subtitle: '国产系统自己的开关，点一下跳到对应的设置页',
          onTap: _vendor,
        ),
        SettingsSwitchTile(
          key: const ValueKey('keep-boot'),
          title: '开机后自动运行',
          subtitle: _status.replayable
              ? '重启手机、或被系统杀掉后，自动在后台把引擎拉回来'
              : '先正常启动一次引擎，之后才能开机自启',
          value: _status.boot,
          onChanged: _setBoot,
        ),
      ],
    );
  }
}
