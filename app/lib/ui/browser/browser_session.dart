import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'site_store.dart';

/// The one browser in the app: kept alive for the whole process, so a page
/// opened in the background (or left while a chat message is sent) is still
/// there when the tools come back to it.
class BrowserSession {
  BrowserSession._();

  static final BrowserSession instance = BrowserSession._();

  WebViewController? _controller;
  final ValueNotifier<String> url = ValueNotifier<String>('');
  final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
  final ValueNotifier<String> lastBlockedScheme = ValueNotifier<String>('');

  /// The document load in flight (completed on the next page finish).
  Completer<void>? _loading;

  bool get loading => _loading != null && !_loading!.isCompleted;

  Future<void> waitLoaded([Duration limit = const Duration(seconds: 10)]) async {
    final pending = _loading;
    if (pending == null || pending.isCompleted) return;
    try {
      await pending.future.timeout(limit);
    } catch (_) {}
  }

  /// The page is on screen; while false the hidden host keeps the WebView up.
  bool get pageVisible => visible.value;

  WebViewController get controller {
    return _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            const allowed = {'http', 'https', 'about', 'data', 'blob', 'file'};
            if (allowed.contains(uri.scheme)) return NavigationDecision.navigate;
            lastBlockedScheme.value = uri.scheme;
            return NavigationDecision.prevent;
          },
          onPageStarted: (value) {
            url.value = value;
            _loading = Completer<void>();
          },
          onPageFinished: (value) async {
            url.value = value;
            if (_loading != null && !_loading!.isCompleted) _loading!.complete();
            try {
              final title = await _controller!.getTitle() ?? '';
              await SiteStore.record(url: value, title: title);
            } catch (_) {}
          },
        ),
      );
  }

  bool get opened => _controller != null;

  Future<Object?> run(String script) async {
    final c = _controller;
    if (c == null) return null;
    return c.runJavaScriptReturningResult(script);
  }

  /// Loads [target] and waits until the document settles (or the limit
  /// passes), so a read straight after open sees the new page.
  Future<String> open(String target) async {
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(target));
    await waitLoaded();
    return url.value.isEmpty ? target : url.value;
  }
}

/// 本机回环接口: the engine's tools reach the browser through this.
///
/// Fixed port so the plugin has nothing to discover; the token keeps other
/// apps on the phone out. The token is written where the engine can read it
/// (the shared storage), and stays in memory as a fallback.
class BrowserApi {
  static const port = 47811;
  static const tokenFile = '/sdcard/Download/DSH-Go/browser-api.json';

  static HttpServer? _server;
  static String _token = 'dshgo-local';

  static void publishSync() {
    try {
      _token = newToken();
      File(tokenFile).createSync(recursive: true);
      File(tokenFile).writeAsStringSync(jsonEncode({'port': port, 'token': _token}));
    } catch (e) {
      debugPrint('browser api token file not written: $e');
    }
  }

  static Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: true);
      _server = server;
      server.listen(_handle);
      debugPrint('browser api on 127.0.0.1:$port');
    } catch (e) {
      debugPrint('browser api not started: $e');
    }
  }

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final auth = request.headers.value('x-dsh-token');
      if (auth != _token) {
        response.statusCode = HttpStatus.forbidden;
        response.write(jsonEncode({'error': 'bad token'}));
        return;
      }
      final body = request.method == 'POST'
          ? jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>
          : <String, dynamic>{};
      final result = await _route(request.uri.path, body);
      response.write(jsonEncode(result));
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': '$e'}));
    } finally {
      await response.close();
    }
  }

  static Future<Object?> _route(String path, Map<String, dynamic> body) async {
    final session = BrowserSession.instance;
    switch (path) {
      case '/state':
        return {'open': session.opened, 'url': session.url.value, 'visible': session.pageVisible, 'loading': session.loading};
      case '/open':
        final target = (body['url'] as String?)?.trim();
        if (target == null || target.isEmpty) return {'error': 'url required'};
        final finalUrl = await session.open(target);
        return {'ok': true, 'url': target, 'finalUrl': finalUrl, 'loading': session.loading};
      case '/snapshot':
        if (!session.opened) return {'error': 'browser_closed'};
        final raw = await session.run(_snapshotScript);
        return {'elements': _elements(raw)};
      case '/read':
        if (!session.opened) return {'error': 'browser_closed'};
        await session.waitLoaded(const Duration(seconds: 3));
        final raw = await session.run('document.body ? document.body.innerText.slice(0, 20000) : ""');
        final text = _stringOf(raw);
        if (text.contains('ERR_') || text.contains('网页无法打开') || text.contains('This site can')) {
          return {'error': 'load_error', 'message': '页面加载失败：${text.split('\n').first}'};
        }
        return {'ok': true, 'text': text};
      case '/js':
        if (!session.opened) return {'error': 'browser_closed'};
        final code = (body['code'] as String?) ?? '';
        if (code.trim().isEmpty) return {'error': 'code required'};
        final timeoutMs = (body['timeoutMs'] as int?) ?? 10000;
        return await _runJs(session, code, timeoutMs.clamp(1000, 30000));
      case '/download':
        final target = (body['url'] as String?)?.trim();
        if (target == null || target.isEmpty) return {'error': 'url required'};
        return await _download(target, body['filename'] as String?);
      case '/click':
        if (!session.opened) return {'error': 'browser_closed'};
        final ref = body['ref'];
        if (ref is! int) return {'error': 'ref must be an int'};
        final raw = await session.run(
          '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.click(); return "ok"; })()',
        );
        if (_stringOf(raw) == 'missing') {
          return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
        }
        return {'ok': true};
      case '/type':
        if (!session.opened) return {'error': 'browser_closed'};
        final ref = body['ref'];
        final text = (body['text'] as String?) ?? '';
        if (ref is! int) return {'error': 'ref must be an int'};
        final script = '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.focus(); e.value = ${jsonEncode(text)}; e.dispatchEvent(new Event("input", {bubbles: true})); return "ok"; })()';
        final raw = await session.run(script);
        if (_stringOf(raw) == 'missing') {
          return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
        }
        return {'ok': true};
      default:
        return {'error': 'unknown path'};
    }
  }


  static Future<Object?> _runJs(BrowserSession session, String code, int timeoutMs) async {
    final id = DateTime.now().microsecondsSinceEpoch;
    final wrapped = '''
window.__dshJs = { id: $id, done: false };
(async () => {
  try {
    const __v = await (async () => { $code })();
    let __s;
    const __repl = (k, v) => (v && typeof v === 'object' && typeof v.nodeType === 'number')
      ? { tag: String(v.tagName || '').toLowerCase(), text: String(v.innerText || '').slice(0, 200), html: String(v.outerHTML || '').slice(0, 200) }
      : v;
    try { __s = JSON.stringify(__v === undefined ? null : __v, __repl); } catch (e) { __s = String(__v); }
    if (__s !== undefined && __s.length > 32768) __s = __s.slice(0, 32768);
    window.__dshJs = { id: $id, done: true, value: __s };
  } catch (e) {
    const line = String(e && e.stack ? e.stack : e).split('\\n')[0];
    window.__dshJs = { id: $id, done: true, error: line };
  }
})();
true
''';
    await session.run(wrapped);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final raw = await session.run('JSON.stringify(window.__dshJs || null)');
      final text = _stringOf(raw);
      if (text.isEmpty || text == 'null') continue;
      try {
        final state = jsonDecode(text);
        if (state is! Map || state['id'] != id || state['done'] != true) continue;
        if (state['error'] != null) return {'error': 'js_error', 'message': '${state['error']}'};
        final value = state['value'];
        if (value is! String) return {'ok': true, 'result': value};
        try {
          return {'ok': true, 'result': jsonDecode(value)};
        } catch (_) {
          return {'ok': true, 'result': value};
        }
      } catch (_) {
        continue;
      }
    }
    return {'error': 'timeout', 'message': '脚本运行超过 ${timeoutMs}ms 还没返回'};
  }

  static Future<Object?> _download(String url, String? filename) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode >= 400) {
        return {'error': 'not_found', 'message': '服务器返回 ${response.statusCode}'};
      }
      final dir = Directory('/sdcard/Download/DSH-Go');
      await dir.create(recursive: true);
      var name = filename?.trim();
      if (name == null || name.isEmpty) {
        final segment = Uri.parse(url).pathSegments.isEmpty ? 'download' : Uri.parse(url).pathSegments.last;
        name = segment.isEmpty ? 'download' : segment;
      }
      var file = File('${dir.path}/$name');
      var index = 1;
      while (await file.exists()) {
        final dot = name.lastIndexOf('.');
        final base = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        file = File('${dir.path}/$base ($index)$ext');
        index += 1;
      }
      final sink = file.openWrite();
      var bytes = 0;
      await for (final chunk in response) {
        bytes += chunk.length;
        if (bytes > 1024 * 1024 * 1024) {
          await sink.close();
          await file.delete();
          return {'error': 'too_large', 'message': '文件超过 1GB'};
        }
        sink.add(chunk);
      }
      await sink.close();
      return {'ok': true, 'path': file.path, 'bytes': bytes, 'mime': response.headers.contentType?.mimeType ?? ''};
    } on FileSystemException {
      return {'error': 'denied', 'message': '没有存储权限，无法写入下载目录'};
    } catch (e) {
      return {'error': 'unsupported', 'message': '下载失败：$e'};
    }
  }

  static const _snapshotScript = '''
(() => {
  const sel = 'a,button,input,textarea,select,[role=button],[onclick]';
  const seen = new Set();
  const out = [];
  for (const e of document.querySelectorAll(sel)) {
    if (e.getClientRects().length === 0) continue;
    const t = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || '').trim().slice(0, 60);
    if (!t) continue;
    const key = t + '|' + (e.tagName.toLowerCase() === 'button' ? 'a' : e.tagName.toLowerCase());
    if (seen.has(key)) continue;
    seen.add(key);
    e.setAttribute('data-dsh-ref', String(out.length));
    out.push({ ref: out.length, tag: e.tagName.toLowerCase(), text: t });
    if (out.length >= 40) break;
  }
  return JSON.stringify(out);
})()
''';

  static String _stringOf(Object? raw) {
    if (raw == null) return '';
    var text = raw.toString();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return text;
  }

  static List<Object?> _elements(Object? raw) {
    final text = _stringOf(raw);
    if (text.isEmpty) return const [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded;
    } catch (_) {}
    return const [];
  }

  static String newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

/// Keeps the WebView alive under the app: full size, covered by the chat
/// while the browser page is closed, so tools can still read, click and
/// capture it without the page popping up over the conversation.
class BrowserHost extends StatelessWidget {
  const BrowserHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: BrowserSession.instance.visible,
          builder: (context, visible, _) {
            final session = BrowserSession.instance;
            if (visible || !session.opened) return const SizedBox.shrink();
            return Positioned.fill(
              child: IgnorePointer(
                child: WebViewWidget(key: const ValueKey('browser-host'), controller: session.controller),
              ),
            );
          },
        ),
        child,
      ],
    );
  }
}
