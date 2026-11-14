import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'browser_session.dart';
import 'site_store.dart';

/// 内置浏览器: a WebView of the app's own — its cookies are separate from the
/// phone's browser, so signing in here is signing in only for this app.
///
/// The page can also be left: the assistant keeps driving the same WebView
/// (and the same tabs) while this screen is closed.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.initialUrl});

  static Route<void> route({String? initialUrl}) =>
      MaterialPageRoute<void>(builder: (_) => BrowserPage(initialUrl: initialUrl));

  final String? initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  static const _sites = <(String, String)>[
    ('百度', 'https://www.baidu.com'),
    ('必应', 'https://cn.bing.com'),
    ('知乎', 'https://www.zhihu.com'),
    ('淘宝', 'https://www.taobao.com'),
    ('GitHub', 'https://github.com'),
  ];

  final _address = TextEditingController();
  List<BrowserSite> _recent = const [];

  BrowserSession get _session => BrowserSession.instance;

  @override
  void initState() {
    super.initState();
    _session.visible.value = true;
    _address.text = _session.url.value;
    _session.url.addListener(_syncAddress);
    SiteStore.load().then((sites) {
      if (mounted) setState(() => _recent = sites);
    });
    final initial = widget.initialUrl;
    if (initial != null && initial.isNotEmpty) {
      _open(initial);
    }
  }

  @override
  void dispose() {
    _session.url.removeListener(_syncAddress);
    _session.visible.value = false;
    _address.dispose();
    super.dispose();
  }

  /// The assistant may navigate while this screen is up: follow it.
  void _syncAddress() {
    final next = _session.url.value;
    if (_address.text == next) return;
    _address.text = next;
  }

  String _normalize(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 'https://www.baidu.com';
    if (text.startsWith('http://') || text.startsWith('https://')) return text;
    if (text.contains(' ') || !text.contains('.')) {
      return 'https://www.baidu.com/s?wd=${Uri.encodeComponent(text)}';
    }
    return 'https://$text';
  }

  void _open(String raw) {
    final url = _normalize(raw);
    _address.text = url;
    _session.open(url);
    FocusScope.of(context).unfocus();
  }

  Future<void> _closeTab() async {
    await _session.closeTab(null);
    if (!_session.opened && mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_session.url, _session.tabsRevision, _session.activeTab]),
          builder: (context, _) {
            final tabs = _session.tabs;
            final loaded = tabs.isNotEmpty;
            final active = _session.currentTab;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '关闭（浏览器留在后台）',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('browser-address'),
                          controller: _address,
                          textInputAction: TextInputAction.go,
                          decoration: const InputDecoration(
                            hintText: '输入网址或搜索词',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: _open,
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _session.controller.reload(),
                      ),
                    ],
                  ),
                ),
                if (loaded)
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Expanded(
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            itemCount: tabs.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 6),
                            itemBuilder: (context, index) {
                              final tab = tabs[index];
                              final selected = tab.id == active?.id;
                              return InputChip(
                                key: ValueKey('browser-tab-${tab.id}'),
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 130),
                                  child: Text(tab.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                                labelStyle: TextStyle(
                                  fontSize: 12,
                                  color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
                                ),
                                selected: selected,
                                showCheckmark: false,
                                backgroundColor: colors.surfaceContainerHighest,
                                selectedColor: colors.secondaryContainer,
                                side: BorderSide.none,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                onPressed: () => _session.switchTo(index),
                                onDeleted: tabs.length > 1 || index == _session.activeTab.value
                                    ? () => _session.closeTab(index)
                                    : null,
                              );
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: '新标签',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add, size: 20),
                          onPressed: tabs.length >= BrowserSession.maxTabs
                              ? null
                              : () => _session.newTab(),
                        ),
                        IconButton(
                          tooltip: '关闭当前标签',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.tab_unselected, size: 20),
                          onPressed: _closeTab,
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: loaded
                      ? WebViewWidget(key: const ValueKey('browser-page-view'), controller: _session.controller)
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (_recent.isNotEmpty) ...[
                              Text('最近访问', style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              for (final site in _recent.take(8))
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(site.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(site.host),
                                  onTap: () => _open(site.url),
                                ),
                              const SizedBox(height: 16),
                            ],
                            Text('常去', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            for (final site in _sites)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(site.$1),
                                subtitle: Text(site.$2),
                                onTap: () => _open(site.$2),
                              ),
                            const SizedBox(height: 16),
                            Text(
                              '在这里登录过的网站，只在 App 内有效，不会影响手机浏览器。关闭这个页面后浏览器仍在后台，助手还能继续用。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 浏览器 key beside the composer's attach button: opens [BrowserPage].
class BrowserButton extends StatelessWidget {
  const BrowserButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '浏览器',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.public, size: 22),
      onPressed: () => Navigator.of(context).push(BrowserPage.route()),
    );
  }
}
