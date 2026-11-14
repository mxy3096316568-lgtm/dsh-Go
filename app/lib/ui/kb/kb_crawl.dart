// 网页抓取入库：从一页开始按同域、限深、限量往下走，把正文写进知识库。
//
// 两个抓法：直取（HttpClient，快、拿不到登录态和 JS 渲染）和浏览器渲染
// （内置浏览器打开再取 innerText，慢、但能用登录态）。同一时间只跑一次，
// 页间有间隔，robots.txt 逐站读一次并遵守。
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;

import '../browser/browser_session.dart';
import '../proxy/proxy_service.dart';
import 'kb_index.dart';

/// 抓一页的结果。
class CrawlPage {
  const CrawlPage({required this.url, required this.outcome, this.title = '', this.error});

  final String url;
  final KbPutResult outcome;
  final String title;

  /// 失败原因（只在这一页失败时有）。
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    if (title.isNotEmpty) 'title': title,
    'outcome': outcome.name,
    if (error != null) 'error': error,
  };
}

/// 一次抓取的总结果。
class CrawlOutcome {
  const CrawlOutcome({
    required this.added,
    required this.updated,
    required this.unchanged,
    required this.skipped,
    required this.failed,
    this.pages = const <CrawlPage>[],
    this.notes = const <String>[],
    this.stopped = false,
  });

  /// 新入库的页数。
  final int added;

  /// 内容变了、重写过的页数。
  final int updated;

  /// 和上次一模一样、没动的页数。
  final int unchanged;

  /// 没抓的（robots 不让、不同域、正文太短、超出时间预算）。
  final int skipped;

  /// 抓失败的（超时、HTTP 4xx/5xx、打不开）。
  final int failed;

  final List<CrawlPage> pages;

  /// 给用户看的实话：到时间上限、robots 拦了几页之类。
  final List<String> notes;

  /// 是否因为时间预算提前收工。
  final bool stopped;

  int get fetched => added + updated + unchanged;

  Map<String, Object?> toJson() => <String, Object?>{
    'fetched': fetched,
    'added': added,
    'updated': updated,
    'unchanged': unchanged,
    'skipped': skipped,
    'failed': failed,
    'stopped': stopped,
    'pages': [for (final page in pages) page.toJson()],
    if (notes.isNotEmpty) 'notes': notes,
  };
}

class CrawlService {
  const CrawlService();

  /// 一次抓取的页数上限（工具参数还能再压小，不能调大）。
  static const int maxPages = 30;

  /// 页间间隔：对别人的站点客气的下限，也顺便让时间预算够用。
  static const Duration gap = Duration(milliseconds: 600);

  /// 单页正文上限，超过截断：知识库里放一整页已经够用。
  static const int maxPageChars = 30000;

  static const Set<String> _binaryExtensions = <String>{
    'pdf', 'zip', 'rar', '7z', 'gz', 'tar', 'apk', 'exe', 'dmg', 'iso',
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'ico', 'bmp',
    'mp3', 'm4a', 'wav', 'ogg', 'flac', 'mp4', 'mov', 'mkv', 'avi', 'webm',
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'css', 'js', 'woff', 'woff2', 'ttf',
  };

  /// 抓 [start] 及其后续链接。返回统计；不抛异常，出错记在 notes/failed 里。
  Future<CrawlOutcome> crawl({
    required String start,
    int depth = 1,
    int limit = 10,
    bool sameDomain = true,
    bool render = false,
    Duration budget = const Duration(seconds: 150),
    KbIndex? index,
  }) async {
    final notes = <String>[];
    final startUri = _parse(start);
    if (startUri == null) {
      return CrawlOutcome(
        added: 0, updated: 0, unchanged: 0, skipped: 0, failed: 1,
        notes: const <String>['网址不对：要 http 或 https，例如 https://example.com/article'],
      );
    }
    final kb = index ?? KbIndex();
    final maxDepth = depth.clamp(0, 3);
    final pageCap = limit.clamp(1, maxPages);
    final rootHost = startUri.host;
    final queue = <(Uri, int)>[(startUri, 0)];
    final seen = <String>{_key(startUri)};
    final robots = <String, _Robots>{};
    final pages = <CrawlPage>[];
    final deadline = DateTime.now().add(budget);
    var added = 0, updated = 0, unchanged = 0, skipped = 0, failed = 0;
    var fetched = 0;
    var stopped = false;
    var blocked = 0;

    while (queue.isNotEmpty) {
      if (fetched >= pageCap) break;
      if (DateTime.now().isAfter(deadline)) {
        stopped = true;
        notes.add('到时间上限（${budget.inSeconds} 秒），还剩 ${queue.length} 个链接没抓');
        break;
      }
      final (uri, level) = queue.removeAt(0);
      if (sameDomain && !_sameSite(uri.host, rootHost)) {
        skipped += 1;
        continue;
      }
      if (!await _allowed(uri, robots)) {
        skipped += 1;
        blocked += 1;
        continue;
      }
      final page = render ? await _fetchRendered(uri) : await _fetchDirect(uri);
      if (page == null) {
        failed += 1;
        pages.add(CrawlPage(url: uri.toString(), outcome: KbPutResult.failed, error: '打不开'));
        await Future<void>.delayed(gap);
        continue;
      }
      if (page.text.length < 40) {
        skipped += 1;
        notes.add('正文太短，跳过：${uri.toString()}');
        await Future<void>.delayed(gap);
        continue;
      }
      fetched += 1;
      final outcome = await kb.putWebDoc(url: uri.toString(), text: page.text, title: page.title);
      switch (outcome) {
        case KbPutResult.added:
          added += 1;
        case KbPutResult.updated:
          updated += 1;
        case KbPutResult.unchanged:
          unchanged += 1;
        case KbPutResult.failed:
          failed += 1;
      }
      pages.add(CrawlPage(url: uri.toString(), outcome: outcome, title: page.title));
      if (level < maxDepth) {
        for (final link in page.links) {
          final key = _key(link);
          if (!seen.add(key)) continue;
          if (sameDomain && !_sameSite(link.host, rootHost)) continue;
          if (_binaryExtensions.contains(_extensionOf(link.path))) continue;
          queue.add((link, level + 1));
        }
      }
      await Future<void>.delayed(gap);
    }
    if (blocked > 0) notes.add('有 $blocked 页被这个站的 robots.txt 禁止，没抓');
    if (queue.isNotEmpty && !stopped && fetched >= pageCap) {
      notes.add('到页数上限（$pageCap 页），还有 ${queue.length} 个链接没抓；想多抓就把 limit 改大，再抓一次');
    }
    return CrawlOutcome(
      added: added,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      failed: failed,
      pages: pages,
      notes: notes,
      stopped: stopped,
    );
  }

  // ── robots.txt ──────────────────────────────────────────────────────────

  Future<bool> _allowed(Uri uri, Map<String, _Robots> cache) async {
    final origin = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final rules = cache[origin] ??= await _loadRobots(origin);
    return rules.allows(uri.path.isEmpty ? '/' : uri.path);
  }

  Future<_Robots> _loadRobots(String origin) async {
    final text = await _get('$origin/robots.txt', expectText: true);
    if (text == null) return const _Robots(<(bool, String)>[]);
    final rules = <(bool, String)>[];
    var applies = false;
    for (final raw in text.split('\n')) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final at = line.indexOf(':');
      if (at <= 0) continue;
      final key = line.substring(0, at).trim().toLowerCase();
      final value = line.substring(at + 1).trim();
      if (key == 'user-agent') {
        applies = value == '*';
        continue;
      }
      if (!applies) continue;
      if (key == 'disallow') {
        if (value.isNotEmpty) rules.add((false, value));
      } else if (key == 'allow') {
        if (value.isNotEmpty) rules.add((true, value));
      }
    }
    return _Robots(rules);
  }

  // ── 两种抓法 ────────────────────────────────────────────────────────────

  Future<_Page?> _fetchDirect(Uri uri) async {
    final html = await _get(uri.toString());
    if (html == null) return null;
    return _extract(html, uri);
  }

  Future<String?> _get(String url, {bool expectText = false}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    ProxyRoute.apply(client);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 dsh-go');
      if (!expectText) request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,text/plain;q=0.9');
      final response = await request.close().timeout(const Duration(seconds: 20));
      final type = response.headers.contentType?.mimeType ?? '';
      if (response.statusCode >= 400) {
        await response.drain<void>();
        return null;
      }
      if (!expectText) {
        final usable = type.isEmpty || type.contains('html') || type.startsWith('text/') || type.contains('xml');
        if (!usable) {
          await response.drain<void>();
          return null;
        }
      }
      final bytes = BytesBuilder(copy: false);
      var tooBig = false;
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > 4 * 1024 * 1024) {
          tooBig = true;
          break;
        }
      }
      if (tooBig) return null;
      final charset = response.headers.contentType?.charset?.toLowerCase() ?? '';
      final data = bytes.takeBytes();
      // 中文站点还有不少 GBK：Dart 不内置，解不出来就当 UTF-8 兜底，至少不丢整页。
      if (charset.contains('gb')) return _relaxedLatin(data);
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// GBK 解不出来时至少保住 ASCII 部分，不让整页变成空白。
  String _relaxedLatin(List<int> data) {
    final text = utf8.decode(data, allowMalformed: true);
    if (!text.contains('\uFFFD')) return text;
    return String.fromCharCodes(data.map((byte) => byte < 0x80 ? byte : 0x3F));
  }

  Future<_Page?> _fetchRendered(Uri uri) async {
    final session = BrowserSession.instance;
    try {
      await session.open(uri.toString());
    } catch (_) {
      return null;
    }
    await session.waitLoaded(const Duration(seconds: 4));
    if ((await session.loadErrorMark()).isNotEmpty) return null;
    final raw = await BrowserApi.runJs(session, _renderScript, 20000);
    if (raw is! Map || raw['ok'] != true) return null;
    final result = raw['result'];
    if (result is! Map) return null;
    final text = (result['text'] is String ? result['text'] as String : '').trim();
    final title = result['title'] is String ? result['title'] as String : '';
    return _Page(
      title: title,
      text: text.length > maxPageChars ? text.substring(0, maxPageChars) : text,
      links: _linksOf(result['links'], uri),
    );
  }

  static const String _renderScript = '''
const pick = document.querySelector('article') || document.querySelector('main') || document.body;
const text = pick ? (pick.innerText || '') : '';
return {
  title: (document.title || '').trim(),
  text: text.replace(/[ \\t]+/g, ' ').replace(/\\n\\s*\\n\\s*\\n+/g, '\\n\\n').trim(),
  links: [...document.querySelectorAll('a[href]')].slice(0, 300).map(a => a.href),
};
''';

  // ── 解析 ────────────────────────────────────────────────────────────────

  _Page? _extract(String html, Uri base) {
    try {
      final document = html_parser.parse(html);
      for (final el in document.querySelectorAll('script, style, noscript, iframe, svg')) {
        el.remove();
      }
      final title = (document.querySelector('title')?.text ?? '').trim();
      final main = document.querySelector('article') ?? document.querySelector('main') ?? document.body;
      var text = (main?.text ?? '').replaceAll(RegExp(r'[ \t]+'), ' ');
      text = text.replaceAll(RegExp(r'\n[ \t]*\n(\s*\n)+'), '\n\n').trim();
      if (text.length > maxPageChars) text = text.substring(0, maxPageChars);
      final links = <Uri>[];
      for (final anchor in document.querySelectorAll('a[href]')) {
        final href = anchor.attributes['href'];
        if (href == null) continue;
        final link = _resolve(href, base);
        if (link != null) links.add(link);
      }
      return _Page(title: title, text: text, links: links);
    } catch (_) {
      return null;
    }
  }

  List<Uri> _linksOf(Object? raw, Uri base) {
    if (raw is! List) return const <Uri>[];
    final links = <Uri>[];
    for (final item in raw) {
      if (item is! String) continue;
      final link = _resolve(item, base);
      if (link != null) links.add(link);
    }
    return links;
  }

  Uri? _resolve(String href, Uri base) {
    final trimmed = href.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith('javascript:')) return null;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://') && !trimmed.startsWith('/')) {
      if (trimmed.contains(':') && !trimmed.startsWith('./') && !trimmed.startsWith('../')) return null;
    }
    try {
      final resolved = base.resolve(trimmed);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
      if (resolved.host.isEmpty) return null;
      return Uri.parse(resolved.removeFragment().toString());
    } catch (_) {
      return null;
    }
  }

  Uri? _parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return Uri.parse(uri.removeFragment().toString());
  }

  /// 用于去重：去掉 fragment，主机小写。
  String _key(Uri uri) {
    final noFragment = uri.removeFragment();
    return noFragment.replace(host: noFragment.host.toLowerCase()).toString();
  }

  bool _sameSite(String host, String root) {
    final h = host.toLowerCase();
    final r = root.toLowerCase();
    return h == r || h.endsWith('.$r');
  }

  String _extensionOf(String path) {
    final last = path.split('/').last;
    final dot = last.lastIndexOf('.');
    if (dot <= 0 || dot == last.length - 1) return '';
    return last.substring(dot + 1).toLowerCase();
  }
}

class _Page {
  const _Page({required this.title, required this.text, required this.links});

  final String title;
  final String text;
  final List<Uri> links;
}

class _Robots {
  const _Robots(this.rules);

  /// (是否允许, 路径前缀)：最长匹配说了算。
  final List<(bool, String)> rules;

  bool allows(String path) {
    var best = -1;
    var allowed = true;
    for (final (allow, rule) in rules) {
      if (!path.startsWith(rule)) continue;
      if (rule.length < best) continue;
      best = rule.length;
      allowed = allow;
    }
    return allowed;
  }
}
