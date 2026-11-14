import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'browser_session.dart';
import 'site_store.dart';

/// 内置浏览器: a WebView of the app's own — its cookies are separate from the
/// phone's browser, so signing in here is signing in only for this app.
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

  late final WebViewController _controller;
  final _address = TextEditingController();
  String _url = '';
  bool _loading = false;
  List<BrowserSite> _sites = const [];

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            BrowserSession.instance.url.value = url;
            if (!mounted) return;
            setState(() {
              _url = url;
              _loading = true;
              _address.text = url;
            });
          },
          onPageFinished: (url) async {
            BrowserSession.instance.url.value = url;
            final title = await _controller.getTitle() ?? '';
            final sites = await SiteStore.record(url: url, title: title);
            if (mounted) setState(() => _sites = sites);
            if (!mounted) return;
            setState(() {
              _url = url;
              _loading = false;
              _address.text = url;
            });
          },
        ),
      );
    BrowserSession.instance.attach(_controller);
    SiteStore.load().then((sites) {
      if (mounted) setState(() => _sites = sites);
    });
    final initial = widget.initialUrl;
    if (initial != null && initial.isNotEmpty) {
      _open(initial);
    }
  }

  @override
  void dispose() {
    BrowserSession.instance.detach(_controller);
    _address.dispose();
    super.dispose();
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
    _controller.loadRequest(Uri.parse(url));
    if (_address.text != url) _address.text = url;
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
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
                    onPressed: () => _controller.reload(),
                  ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _url.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_sites.isNotEmpty) ...[
                          Text('最近访问', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          for (final site in _sites.take(8))
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
                          '在这里登录过的网站，只在 App 内有效，不会影响手机浏览器。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    )
                  : WebViewWidget(controller: _controller),
            ),
          ],
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
