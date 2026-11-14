// 看护页面：能力控制 → 看护。列出在盯的页面、上次看到什么、有没有变过。
//
// 检查在本机跑（见 state/watch_service.dart）：App 进程在就会按间隔看，
// 变了发一条本机通知。不做全站镜像，也不碰反爬。
import 'package:flutter/material.dart';

import '../../state/watch_service.dart';
import '../common/brief_notice.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

String _when(int ms) {
  if (ms <= 0) return '还没看过';
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  return '${diff.inDays} 天前';
}

String _every(int seconds) {
  if (seconds % 3600 == 0) return '每 ${seconds ~/ 3600} 小时';
  return '每 ${seconds ~/ 60} 分钟';
}

class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.sessionId});

  /// 建看护时记下的会话：通知点开回到这里。
  final String sessionId;

  static Route<void> route(String sessionId) =>
      MaterialPageRoute<void>(builder: (_) => WatchPage(sessionId: sessionId));

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  List<WatchItem> _items = const <WatchItem>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = WatchService.instance;
    await service.load();
    // 页面开着的时候循环就该转起来：看护是“放着不管”的功能。
    service.start();
    if (mounted) setState(() => _items = service.items);
  }

  Future<void> _checkNow(WatchItem item) async {
    setState(() => _busy = true);
    final changed = await WatchService.instance.check(item.id);
    if (!mounted) return;
    setState(() {
      _items = WatchService.instance.items;
      _busy = false;
    });
    showBriefNotice(context, changed ? '有变化，已发通知' : '和上次一样');
  }

  /// 「现在都看一遍」: 立刻检查所有到点的看护。
  Future<void> _checkAll() async {
    setState(() => _busy = true);
    final count = await WatchService.instance.tick();
    if (!mounted) return;
    setState(() {
      _items = WatchService.instance.items;
      _busy = false;
    });
    showBriefNotice(context, count == 0 ? '还没到检查时间' : '看了 $count 条');
  }

  Future<void> _add() async {
    final url = TextEditingController();
    final label = TextEditingController();
    final keyword = TextEditingController();
    var everySeconds = 900;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('看什么'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('watch-url'),
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: '网址',
                    hintText: 'https://…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('watch-label'),
                  controller: label,
                  decoration: const InputDecoration(
                    labelText: '叫什么（随便起）',
                    hintText: '机票价格',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('watch-keyword'),
                  controller: keyword,
                  decoration: const InputDecoration(
                    labelText: '关注什么（可以空着）',
                    hintText: '价格、座位、有货',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('多久看一次', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: everySeconds,
                      onChanged: (value) => setState(() => everySeconds = value ?? 900),
                      items: const [
                        DropdownMenuItem(value: 300, child: Text('5 分钟')),
                        DropdownMenuItem(value: 900, child: Text('15 分钟')),
                        DropdownMenuItem(value: 3600, child: Text('1 小时')),
                        DropdownMenuItem(value: 10800, child: Text('3 小时')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '只在 App 进程活着的时候检查（开着「常驻」最稳）；变了发一条本机通知。',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('开始看')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final target = url.text.trim();
    if (target.isEmpty) {
      showBriefNotice(context, '要填网址');
      return;
    }
    setState(() => _busy = true);
    final item = await WatchService.instance.add(
      url: target,
      label: label.text.trim(),
      keyword: keyword.text.trim(),
      everySeconds: everySeconds,
      sessionId: widget.sessionId,
    );
    // 先看一次：立刻就有一份“当前状态”，之后的变化才有对比。
    await WatchService.instance.check(item.id);
    if (!mounted) return;
    setState(() {
      _items = WatchService.instance.items;
      _busy = false;
    });
    showBriefNotice(context, '开始看「${item.label}」');
  }

  Future<void> _remove(WatchItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('不看了？'),
        content: Text('会删掉「${item.label}」这条看护，已记录的片段一起删。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删掉')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await WatchService.instance.remove(item.id);
    if (!mounted) return;
    setState(() => _items = WatchService.instance.items);
  }

  Future<void> _toggle(WatchItem item, bool active) async {
    await WatchService.instance.setActive(item.id, active);
    if (mounted) setState(() => _items = WatchService.instance.items);
  }

  @override
  Widget build(BuildContext context) {
    final running = _items.where((item) => item.active).length;
    return AppPage.list(
      title: '看护',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '盯着一个页面上的一样东西，变了才告诉你。$running 条在看着，本机跑，不经过别处。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsSection(
          title: '在看的',
          children: [
            if (_items.isEmpty)
              SettingsTile(
                title: '还没有看护',
                subtitle: '点下面的「看一个页面」：填网址、起个名字、写上关注什么',
              ),
            for (final item in _items)
              SettingsTile(
                key: ValueKey('watch-${item.id}'),
                icon: AppIcons.alarmClock,
                title: item.label,
                subtitle: [
                  _every(item.everySeconds),
                  '上次 ${_when(item.lastCheckedAtMs)}',
                  if (item.changes > 0) '变过 ${item.changes} 次',
                  if (item.lastError.isNotEmpty) item.lastError,
                ].join(' · '),
                value: item.active ? null : const Text('已暂停'),
                onTap: _busy ? null : () => _checkNow(item),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: item.active,
                      onChanged: (value) => _toggle(item, value),
                    ),
                    IconButton(
                      tooltip: '不看了',
                      onPressed: () => _remove(item),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
              ),
          ],
        ),
        SettingsSection(
          title: '新的',
          children: [
            SettingsTile(
              key: const ValueKey('watch-add'),
              icon: AppIcons.add,
              title: '看一个页面',
              subtitle: '网址 + 关注什么 + 多久看一次',
              onTap: _busy ? null : _add,
            ),
            SettingsTile(
              key: const ValueKey('watch-check-all'),
              icon: AppIcons.refresh,
              title: '现在都看一遍',
              subtitle: _busy ? '正在看…' : '不用等间隔，立刻检查所有到点的看护',
              onTap: _busy ? null : _checkAll,
            ),
          ],
        ),
        if (_items.isNotEmpty)
          SettingsSection(
            title: '上次看到的',
            children: [
              for (final item in _items)
                SettingsTile(
                  title: item.label,
                  subtitle: item.lastSnippet.isEmpty ? '还没看过内容' : item.lastSnippet,
                ),
            ],
          ),
      ],
    );
  }
}
