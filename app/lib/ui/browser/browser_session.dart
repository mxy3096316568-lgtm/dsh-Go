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

  /// The page is on screen; while false the hidden host keeps the WebView up.
  bool get pageVisible => visible.value;

  WebViewController get controller {
    return _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (value) => url.value = value,
          onPageFinished: (value) async {
            url.value = value;
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

  Future<void> open(String target) async {
    await controller.loadRequest(Uri.parse(target));
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
        return {'open': session.opened, 'url': session.url.value, 'visible': session.pageVisible};
      case '/open':
        final target = (body['url'] as String?)?.trim();
        if (target == null || target.isEmpty) return {'error': 'url required'};
        await session.open(target);
        return {'ok': true, 'url': target};
      case '/snapshot':
        if (!session.opened) return {'error': 'browser_closed'};
        final raw = await session.run(_snapshotScript);
        return {'elements': _elements(raw)};
      case '/read':
        if (!session.opened) return {'error': 'browser_closed'};
        final raw = await session.run('document.body ? document.body.innerText.slice(0, 20000) : ""');
        return {'text': _stringOf(raw)};
      case '/click':
        if (!session.opened) return {'error': 'browser_closed'};
        final ref = body['ref'];
        if (ref is! int) return {'error': 'ref must be an int'};
        final raw = await session.run(
          '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.click(); return "ok"; })()',
        );
        return {'result': _stringOf(raw)};
      case '/type':
        if (!session.opened) return {'error': 'browser_closed'};
        final ref = body['ref'];
        final text = (body['text'] as String?) ?? '';
        if (ref is! int) return {'error': 'ref must be an int'};
        final script = '(() => { const e = document.querySelector(\'[data-dsh-ref="$ref"]\'); if (!e) return "missing"; e.focus(); e.value = ${jsonEncode(text)}; e.dispatchEvent(new Event("input", {bubbles: true})); return "ok"; })()';
        final raw = await session.run(script);
        return {'result': _stringOf(raw)};
      default:
        return {'error': 'unknown path'};
    }
  }

  static const _snapshotScript = '''
(() => {
  const sel = 'a,button,input,textarea,select,[role=button],[onclick]';
  const els = Array.from(document.querySelectorAll(sel))
    .filter(e => e.getClientRects().length > 0);
  const out = els.slice(0, 120).map((e, i) => {
    e.setAttribute('data-dsh-ref', String(i));
    const t = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || '').trim().slice(0, 60);
    return { ref: i, tag: e.tagName.toLowerCase(), text: t };
  });
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

/// Keeps the WebView alive while the browser page is closed: a 1px host off
/// the screen's corner owns the platform view, so the assistant can keep
/// reading and clicking after the person returns to the chat.
class BrowserHost extends StatelessWidget {
  const BrowserHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<bool>(
          valueListenable: BrowserSession.instance.visible,
          builder: (context, visible, _) {
            final session = BrowserSession.instance;
            if (visible || !session.opened) return const SizedBox.shrink();
            return Positioned(
              left: -2,
              top: -2,
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: WebViewWidget(key: const ValueKey('browser-host'), controller: session.controller),
              ),
            );
          },
        ),
      ],
    );
  }
}
