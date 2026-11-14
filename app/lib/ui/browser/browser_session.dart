import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../state/capability_guard.dart';
import '../notify/notify_bridge.dart';
import '../proxy/proxy_service.dart';
import 'site_store.dart';
import 'webdav_client.dart';

/// One tab of the in-app browser.
class BrowserTab {
  BrowserTab({required this.id, this.url = '', this.title = ''});

  final int id;
  String url;
  String title;

  String get label {
    if (title.trim().isNotEmpty) return title.trim();
    if (url.trim().isEmpty) return '新标签';
    final uri = Uri.tryParse(url);
    return uri?.host.isNotEmpty == true ? uri!.host : url;
  }

  Map<String, Object?> toJson(int active) => {
    'id': id,
    'url': url,
    'title': label,
    'active': id == active,
  };
}

/// The one browser in the app: kept alive for the whole process, so a page
/// opened in the background (or left while a chat message is sent) is still
/// there when the tools come back to it.
///
/// One WebView carries every tab: switching keeps the address (and reloads it),
/// which costs a page load but keeps eight tabs from meaning eight Chromium
/// processes. Cookies, logins and storage are shared, as they would be in a
/// browser.
class BrowserSession {
  BrowserSession._();

  static final BrowserSession instance = BrowserSession._();

  /// Refuse beyond this: each tab is a page the person has to close by hand.
  static const maxTabs = 8;

  /// Where screenshots go: shared storage, so the engine can read them back.
  static const screenshotDir = '/sdcard/Download/DSH-Go/screenshots';

  /// Extensions the upload tool and the person's own file picker accept.
  static const allowedUploadExtensions = <String>{
    'pdf', 'txt', 'md', 'csv', 'json', 'xml', 'yaml', 'yml', 'log',
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub',
    'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic',
    'zip', '7z', 'rar', 'tar', 'gz',
    'mp3', 'm4a', 'wav', 'ogg', 'mp4', 'mov', 'webm',
  };

  /// Folders a page may be handed a file from (checked again for the tool).
  static const uploadFolders = <String>['/sdcard/Download/', '/sdcard/DCIM/'];

  WebViewController? _controller;
  final ValueNotifier<String> url = ValueNotifier<String>('');
  final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
  final ValueNotifier<String> lastBlockedScheme = ValueNotifier<String>('');

  /// Which tab the WebView shows (an index into [_tabs]).
  final ValueNotifier<int> activeTab = ValueNotifier<int>(0);

  /// Bumped whenever the tab list itself changes, so the page can redraw.
  final ValueNotifier<int> tabsRevision = ValueNotifier<int>(0);

  final List<BrowserTab> _tabs = [];
  int _nextTabId = 1;

  /// The document load in flight (completed on the next page finish).
  Completer<void>? _loading;

  /// The largest file the upload tool can hand to a page: the bytes travel
  /// into the page as base64, so this is memory, not disk.
  static const maxUploadBytes = 10 * 1024 * 1024;

  /// Set when the person asks for a file the next time a page opens a picker.
  bool confirmUploads = true;

  List<BrowserTab> get tabs => List<BrowserTab>.unmodifiable(_tabs);

  bool get opened => _controller != null && _tabs.isNotEmpty;

  bool get loading => _loading != null && !_loading!.isCompleted;

  BrowserTab? get currentTab {
    if (_tabs.isEmpty) return null;
    final index = activeTab.value.clamp(0, _tabs.length - 1).toInt();
    return _tabs[index];
  }

  /// 全部暂停 / 关掉浏览器: stop what the page is doing right now, not just refuse the
  /// next call. Tabs stay (the person can read them again after turning it back on).
  Future<void> abort() async {
    final pending = _loading;
    if (pending != null && !pending.isCompleted) pending.complete();
    _loading = null;
    try {
      // webview_flutter 4.x has no stopLoading: navigating away is what cancels a load.
      await _controller?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

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
    final existing = _controller;
    if (existing != null) return existing;
    // Assigned after construction: the delegate below answers with this controller.
    late final WebViewController created;
    created = WebViewController()
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
            final tab = currentTab;
            if (tab != null) tab.url = value;
            _loading = Completer<void>();
          },
          onPageFinished: (value) async {
            url.value = value;
            final tab = currentTab;
            if (tab != null) tab.url = value;
            if (_loading != null && !_loading!.isCompleted) _loading!.complete();
            try {
              final mark = await loadErrorMark();
              final title = mark.isEmpty ? (await created.getTitle() ?? '') : '加载失败';
              if (tab != null) {
                tab.title = title;
                _bumpTabs();
              }
              if (mark.isEmpty) await SiteStore.record(url: value, title: title);
            } catch (_) {}
          },
        ),
      );
    final platform = created.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setOnShowFileSelector(_chooseFiles));
    }
    _controller = created;
    return created;
  }

  /// A marker when the page Chrome is showing is an error page (host unreachable,
  /// certificate, DNS…), empty otherwise. Android's error page is not a document
  /// the page itself served, so nothing else can tell them apart.
  static const _errorProbe = '''
(() => {
  const url = String(location.href || "");
  if (url.startsWith("chrome-error")) return "chrome-error";
  const text = document.body ? String(document.body.innerText || "").slice(0, 600) : "";
  const found = text.match(/ERR_[A-Z_]+|网页无法打开|无法访问此网站|This site can.t be reached/);
  return found ? found[0] : "";
})()
''';

  /// 标签标题: an error page has no title of its own worth showing.
  void markLoadFailed() {
    final tab = currentTab;
    if (tab == null) return;
    tab.title = '加载失败';
    _bumpTabs();
  }

  Future<String> loadErrorMark() async {
    try {
      return _stringOf(await run(_errorProbe));
    } catch (_) {
      return '';
    }
  }

  Future<Object?> run(String script) async {
    final c = _controller;
    if (c == null) return null;
    return c.runJavaScriptReturningResult(script);
  }

  void _bumpTabs() {
    tabsRevision.value++;
    final index = activeTab.value.clamp(0, max(0, _tabs.length - 1)).toInt();
    activeTab.value = index;
  }

  /// Loads [target] in the current tab (opening one when there is none) and
  /// waits until the document settles, so a read straight after open sees the
  /// new page.
  Future<String> open(String target, {bool newTab = false}) async {
    if (_tabs.isEmpty || newTab) {
      if (_tabs.length >= maxTabs && newTab) {
        throw const BrowserTabsFull();
      }
      final tab = BrowserTab(id: _nextTabId++, url: target);
      _tabs.add(tab);
      activeTab.value = _tabs.length - 1;
      _bumpTabs();
    } else {
      currentTab!.url = target;
    }
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(target));
    await waitLoaded();
    return url.value.isEmpty ? target : url.value;
  }

  /// Opens a blank tab the person (or the assistant) can type into.
  int newTab({String url = ''}) {
    if (_tabs.length >= maxTabs) throw const BrowserTabsFull();
    final tab = BrowserTab(id: _nextTabId++, url: url);
    _tabs.add(tab);
    activeTab.value = _tabs.length - 1;
    _bumpTabs();
    if (url.isEmpty) {
      // Materialise the WebView too: a blank tab is still an open browser.
      unawaited(controller.loadRequest(Uri.parse('about:blank')));
    } else {
      unawaited(open(url));
    }
    return tab.id;
  }

  /// Switches to the tab at [index]; the address is loaded again because one
  /// WebView carries every tab.
  Future<void> switchTo(int index) async {
    if (_tabs.isEmpty) return;
    final target = index.clamp(0, _tabs.length - 1).toInt();
    if (target == activeTab.value) return;
    activeTab.value = target;
    _bumpTabs();
    final tab = _tabs[target];
    if (tab.url.isEmpty) return;
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(tab.url));
    await waitLoaded();
  }

  /// Closes the tab at [index]; the neighbouring one takes its place. Closing
  /// the last tab leaves the browser closed (`browser_closed`).
  Future<void> closeTab(int? index) async {
    if (_tabs.isEmpty) return;
    final target = (index ?? activeTab.value).clamp(0, _tabs.length - 1).toInt();
    _tabs.removeAt(target);
    if (_tabs.isEmpty) {
      activeTab.value = 0;
      url.value = '';
      _bumpTabs();
      try {
        await run('location.href = "about:blank"');
      } catch (_) {}
      return;
    }
    final next = target >= _tabs.length ? _tabs.length - 1 : target;
    activeTab.value = next;
    _bumpTabs();
    final tab = _tabs[next];
    if (tab.url.isEmpty) return;
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(tab.url));
    await waitLoaded();
  }

  /// Screenshot of what the page currently shows (native: Flutter cannot
  /// capture a platform view).
  Future<Map<String, Object?>> screenshot() async {
    if (!opened) return {'error': 'browser_closed'};
    try {
      final result = await const MethodChannel('dsh/browser-shot')
          .invokeMapMethod<String, Object?>('capture', {
            'dir': screenshotDir,
            'url': url.value,
            'maxSide': 1600,
            'quality': 80,
          });
      if (result == null) return {'error': 'capture_failed'};
      if (result['error'] != null) return Map<String, Object?>.from(result);
      return {'ok': true, ...result};
    } on PlatformException catch (e) {
      return {'error': 'capture_failed', 'message': e.message ?? e.code};
    }
  }

  /// Feeds [path] to the file input [ref] (browser_upload). The chooser the
  /// page opens is answered with that one file, so no system picker appears.
  /// Feeds [path] to the file input [ref] by filling `input.files` with a real
  /// `File` and firing `input`/`change`.
  ///
  /// The click-into-the-chooser route does not work here: Chrome only opens a file
  /// chooser for a trusted (user) gesture, and a tool's programmatic `click()` is
  /// not one, so `onShowFileSelector` never runs. Building the `File` in the page
  /// needs no gesture and no chooser, and the page sees exactly what a person's
  /// pick would have given it.
  Future<Map<String, Object?>> upload(int ref, String path) async {
    if (!opened) return {'error': 'browser_closed'};
    final file = File(path);
    final problem = _uploadProblem(file);
    if (problem != null) return problem;
    if (confirmUploads) {
      if (!BrowserUi.hasUi) {
        return {
          'error': 'denied',
          'message': '上传会把文件内容发给网页，需要用户在 App 里点确认；请让用户打开浏览器页面后重试',
        };
      }
      final host = Uri.tryParse(url.value)?.host ?? '这个页面';
      final allowed = await BrowserUi.confirm(
        '上传文件',
        '要把「${file.uri.pathSegments.last}」传到 $host 吗？上传后这个页面就能读到它的内容。',
        yes: '允许上传',
      );
      if (!allowed) return {'error': 'denied', 'message': '用户取消了这个文件的上传'};
    }
    final bytes = await file.readAsBytes();
    final name = file.uri.pathSegments.last;
    final mime = BrowserUi.mimeFor(name);
    final base64Data = base64Encode(bytes);
    // A multi-megabyte argument would ride in one evaluateJavaScript call; hand it
    // over in chunks instead, then build the File from what the page kept.
    await run('window.__dshUp = ""; true');
    const chunkSize = 2 * 1024 * 1024;
    for (var offset = 0; offset < base64Data.length; offset += chunkSize) {
      final end = offset + chunkSize < base64Data.length ? offset + chunkSize : base64Data.length;
      final chunk = base64Data.substring(offset, end);
      await run('window.__dshUp += ${jsonEncode(chunk)}; true');
    }
    final script = '''
(async () => {
  const el = document.querySelector('[data-dsh-ref="$ref"]');
  if (!el) return "missing";
  if (String(el.tagName || "").toLowerCase() !== "input" || String(el.type || "").toLowerCase() !== "file") return "not_file";
  const bin = atob(window.__dshUp || "");
  window.__dshUp = "";
  const data = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) data[i] = bin.charCodeAt(i);
  const file = new File([data], ${jsonEncode(name)}, { type: ${jsonEncode(mime)} });
  const transfer = new DataTransfer();
  transfer.items.add(file);
  el.files = transfer.files;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  // A page may move/replace its input in the change handler; report what stands now,
  // after giving that handler a tick to run.
  await new Promise((resolve) => setTimeout(resolve, 50));
  const picked = el.files && el.files[0];
  return { count: el.files ? el.files.length : 0, name: picked ? picked.name : "" };
})()
''';
    final result = await BrowserApi.runJs(this, script, 60000);
    if (result is Map && result['error'] != null) return Map<String, Object?>.from(result);
    final value = result is Map ? result['result'] : null;
    if (value == 'missing') return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
    if (value == 'not_file') {
      return {'error': 'unsupported', 'message': '这个编号不是文件选择框（<input type=file>）'};
    }
    final count = value is num ? value.toInt() : (value is Map ? (value['count'] as num?)?.toInt() ?? 0 : 0);
    if (count >= 1) {
      return {'ok': true, 'path': path, 'name': name, 'bytes': bytes.length, 'files': count};
    }
    return {'error': 'unsupported', 'message': '页面没有接受这个文件（input.files 还是空的）'};
  }

  Map<String, Object?>? _uploadProblem(File file) {
    final normalized = file.path;
    if (!uploadFolders.any(normalized.startsWith)) {
      return {
        'error': 'denied',
        'message': '只允许上传 下载(Download) 和 DCIM 里的文件',
      };
    }
    final dot = normalized.lastIndexOf('.');
    final ext = dot > 0 ? normalized.substring(dot + 1).toLowerCase() : '';
    if (!allowedUploadExtensions.contains(ext)) {
      return {'error': 'unsupported', 'message': '不支持上传 .$ext 类型的文件'};
    }
    if (!file.existsSync()) {
      return {'error': 'not_found', 'message': '这个文件不在手机上'};
    }
    if (file.lengthSync() > maxUploadBytes) {
      return {'error': 'too_large', 'message': '这个文件超过 10MB，上传工具一次带不动；请改用更小的文件'};
    }
    return null;
  }

  /// The page opened a file input: hand it the file [upload] chose, or ask the
  /// person which one when they tapped the input themselves.
  Future<List<String>> _chooseFiles(FileSelectorParams params) async {
    // Only the person's own tap gets here (a trusted gesture). webview_flutter hands
    // the answer to Chrome as `Uri.parse(path)`, and a bare path has no scheme
    // there: send a file:// URI, which Chrome can open.
    final picked = await BrowserUi.pickFile(params.acceptTypes);
    return picked == null ? const [] : [Uri.file(picked).toString()];
  }

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
}

/// Raised when a ninth tab is asked for.
class BrowserTabsFull implements Exception {
  const BrowserTabsFull();

  @override
  String toString() => 'tabs_full';
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

  /// Which capability switch a route needs. `/state`, `/capabilities` and `/dav/config`
  /// stay open, so the model can always ask what is going on.
  static const _needs = <String, List<String>>{
    '/open': ['browser'],
    '/read': ['browser'],
    '/snapshot': ['browser'],
    '/click': ['browser'],
    '/type': ['browser'],
    '/js': ['browser'],
    '/screenshot': ['browser'],
    '/tabs': ['browser'],
    '/tab-open': ['browser'],
    '/tab-switch': ['browser'],
    '/tab-close': ['browser'],
    '/upload': ['browser', 'files'],
    '/download': ['files'],
    '/dav/ls': ['cloud'],
    '/dav/search': ['cloud'],
    '/dav/upload': ['cloud', 'files'],
    '/dav/download': ['cloud', 'files'],
    '/notify/status': ['notify'],
    '/notify/list': ['notify'],
    '/notify/search': ['notify'],
    '/notify/digest': ['notify'],
    '/notify/rules': ['notify'],
    '/notify/rule-add': ['notify'],
    '/notify/rule-remove': ['notify'],
    '/notify/hits': ['notify'],
  };

  static Future<Object?> _route(String path, Map<String, dynamic> body) async {
    final session = BrowserSession.instance;
    for (final key in _needs[path] ?? const <String>[]) {
      if (CapabilityGuard.allows(key)) continue;
      CapabilityGuard.noteDenial(key, path);
      return {'error': 'denied', 'capability': key, 'message': CapabilityGuard.messageFor(key)};
    }
    if (path == '/capabilities') return {'ok': true, ...CapabilityGuard.describe()};
    switch (path) {
      case '/state':
        return {
          'open': session.opened,
          'url': session.url.value,
          'visible': session.pageVisible,
          'loading': session.loading,
          'tabs': _tabsOf(session),
        };
      case '/open':
        final target = (body['url'] as String?)?.trim();
        if (target == null || target.isEmpty) return {'error': 'url required'};
        try {
          final finalUrl = await session.open(target);
          final mark = await session.loadErrorMark();
          if (mark.isNotEmpty) {
            session.markLoadFailed();
            return {
              'error': 'load_error',
              'message': '页面没打开：$target（$mark）。网址或网络有问题，读不到这个页面。',
              'url': target,
              'finalUrl': finalUrl,
              'loading': session.loading,
              'tabs': _tabsOf(session),
            };
          }
          return {
            'ok': true,
            'url': target,
            'finalUrl': finalUrl,
            'loading': session.loading,
            'tabs': _tabsOf(session),
          };
        } on BrowserTabsFull {
          return _full();
        }
      case '/tabs':
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-open':
        final target = (body['url'] as String?)?.trim() ?? '';
        try {
          if (target.isEmpty) {
            session.newTab();
          } else {
            await session.open(target, newTab: true);
          }
        } on BrowserTabsFull {
          return _full();
        }
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-switch':
        if (!session.opened) return {'error': 'browser_closed'};
        final index = _tabIndex(session, body);
        if (index == null) return {'error': 'not_found', 'message': '没有这个标签'};
        await session.switchTo(index);
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/tab-close':
        if (!session.opened) return {'error': 'browser_closed'};
        final index = _tabIndex(session, body);
        if (index == null) return {'error': 'not_found', 'message': '没有这个标签'};
        await session.closeTab(index);
        if (!session.opened) return {'ok': true, 'tabs': const [], 'closed': true};
        return {'ok': true, 'tabs': _tabsOf(session), 'activeIndex': session.activeTab.value};
      case '/screenshot':
        if (!session.opened) return {'error': 'browser_closed'};
        return await session.screenshot();
      case '/upload':
        if (!session.opened) return {'error': 'browser_closed'};
        final ref = body['ref'];
        final file = (body['path'] as String?)?.trim();
        if (ref is! int) return {'error': 'ref must be an int'};
        if (file == null || file.isEmpty) return {'error': 'path required'};
        return await session.upload(ref, file);
      case '/snapshot':
        if (!session.opened) return {'error': 'browser_closed'};
        final raw = await session.run(_snapshotScript);
        return {'elements': _elements(raw)};
      case '/read':
        if (!session.opened) return {'error': 'browser_closed'};
        await session.waitLoaded(const Duration(seconds: 3));
        final raw = await session.run('document.body ? document.body.innerText.slice(0, 20000) : ""');
        final text = BrowserSession._stringOf(raw);
        final mark = await session.loadErrorMark();
        if (mark.isNotEmpty || text.contains('ERR_') || text.contains('网页无法打开') || text.contains('This site can')) {
          final reason = mark.isNotEmpty ? mark : text.split('\n').first;
          return {'error': 'load_error', 'message': '页面加载失败：$reason'};
        }
        return {'ok': true, 'text': text};
      case '/js':
        if (!session.opened) return {'error': 'browser_closed'};
        final code = (body['code'] as String?) ?? '';
        if (code.trim().isEmpty) return {'error': 'code required'};
        final timeoutMs = (body['timeoutMs'] as int?) ?? 10000;
        return await runJs(session, code, timeoutMs.clamp(1000, 60000).toInt());
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
        if (BrowserSession._stringOf(raw) == 'missing') {
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
        if (BrowserSession._stringOf(raw) == 'missing') {
          return {'error': 'not_found', 'message': '这个编号不存在，请重新 snapshot'};
        }
        return {'ok': true};
      case '/notify/status':
        final status = await NotifyBridge.status();
        return {'ok': true, 'granted': status.granted, 'count': status.count};
      case '/notify/list':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final items = await NotifyBridge.list(
          limit: (body['limit'] as int?) ?? 30,
          app: body['app'] as String?,
        );
        return {'ok': true, 'items': [for (final item in items) item.toJson()]};
      case '/notify/search':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final items = await NotifyBridge.search(
          (body['query'] as String?) ?? '',
          limit: (body['limit'] as int?) ?? 30,
        );
        return {'ok': true, 'items': [for (final item in items) item.toJson()]};
      case '/notify/rules':
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/rule-add':
        final keyword = (body['keyword'] as String?)?.trim() ?? '';
        if (keyword.isEmpty) return {'error': 'keyword required'};
        final action = (body['action'] as String?) == 'remind' ? 'remind' : 'record';
        await NotifyBridge.addRule(keyword, action);
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/rule-remove':
        await NotifyBridge.removeRule((body['keyword'] as String?)?.trim() ?? '');
        return {'ok': true, 'rules': await _ruleList()};
      case '/notify/hits':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final hits = await NotifyBridge.hits(limit: (body['limit'] as int?) ?? 50);
        return {'ok': true, 'items': [for (final hit in hits) hit.toJson()]};
      case '/notify/digest':
        final granted = (await NotifyBridge.status()).granted;
        if (!granted) return _notifyDenied();
        final apps = await NotifyBridge.summary();
        final items = await NotifyBridge.list(limit: (body['limit'] as int?) ?? 40);
        final lines = [
          for (final app in apps.take(12))
            '[${app['app']}] ${app['count']} 条，最新：${app['latest']}',
        ];
        return {
          'ok': true,
          'apps': apps,
          'summary': lines.join('\n'),
          'items': [for (final item in items) item.toJson()],
        };
      case '/dav/config':
        return {'ok': true, 'configured': WebdavConfig.configured, 'address': WebdavConfig.address, 'user': WebdavConfig.user};
      case '/dav/ls':
        return await WebdavClient.list((body['path'] as String?) ?? '/');
      case '/dav/upload':
        return await WebdavClient.upload(
          local: (body['local'] as String?) ?? '',
          remote: (body['remote'] as String?) ?? '',
        );
      case '/dav/download':
        return await WebdavClient.download(
          remote: (body['remote'] as String?) ?? '',
          filename: body['filename'] as String?,
        );
      case '/dav/search':
        return await WebdavClient.search(
          query: (body['query'] as String?) ?? '',
          path: (body['path'] as String?) ?? '/',
        );
      default:
        return {'error': 'unknown path'};
    }
  }

  static Future<List<Map<String, Object?>>> _ruleList() async => [
    for (final rule in await NotifyBridge.rules()) {'keyword': rule.keyword, 'action': rule.action},
  ];

  static Object _notifyDenied() => {
    'error': 'denied',
    'message': '还没有通知读取权限：请用户在 设置 → 通知使用权（或 能力控制 → 通知）里打开 DSH Go',
  };

  static Object _full() => {'error': 'tabs_full', 'message': '最多 ${BrowserSession.maxTabs} 个标签，先关掉一个'};

  static List<Map<String, Object?>> _tabsOf(BrowserSession session) => [
    for (final tab in session.tabs) tab.toJson(session.currentTab?.id ?? -1),
  ];

  /// A tab from `index` or `id` in the request body.
  static int? _tabIndex(BrowserSession session, Map<String, dynamic> body) {
    final index = body['index'];
    if (index is int && index >= 0 && index < session.tabs.length) return index;
    final id = body['id'];
    if (id is int) {
      final found = session.tabs.indexWhere((tab) => tab.id == id);
      if (found >= 0) return found;
    }
    if (index == null && id == null) return session.activeTab.value;
    return null;
  }

  static Future<Object?> runJs(BrowserSession session, String code, int timeoutMs) async {
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
      final text = BrowserSession._stringOf(raw);
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
      ProxyRoute.apply(client);
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
    const isFile = e.tagName === 'INPUT' && String(e.type || '').toLowerCase() === 'file';
    // A file input is usually display:none behind a styled label, and takes no
    // text: keep it anyway, or uploading has no ref to aim at.
    if (!isFile && e.getClientRects().length === 0) continue;
    let t = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || '').trim().slice(0, 60);
    if (!t && isFile) t = '文件选择框';
    if (!t) continue;
    const key = isFile ? 'file|' + out.length : t + '|' + (e.tagName.toLowerCase() === 'button' ? 'a' : e.tagName.toLowerCase());
    if (seen.has(key)) continue;
    seen.add(key);
    e.setAttribute('data-dsh-ref', String(out.length));
    const item = { ref: out.length, tag: e.tagName.toLowerCase(), text: t };
    if (isFile) item.file = true;
    out.push(item);
    if (out.length >= 40) break;
  }
  return JSON.stringify(out);
})()
''';

  static List<Object?> _elements(Object? raw) {
    final text = BrowserSession._stringOf(raw);
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

/// Dialogs the browser raises while a tool drives it.
class BrowserUi {
  /// The app's navigator, set once the app is built (app.dart).
  static GlobalKey<NavigatorState>? navigatorKey;

  static BuildContext? get context => navigatorKey?.currentContext;

  static bool get hasUi => context != null;

  /// False when the app is not on screen: uploading sends the file out, so
  /// without a person to ask there is no consent.
  static Future<bool> confirm(String title, String message, {String yes = '允许', String no = '取消'}) async {
    final page = context;
    if (page == null) return false;
    final answer = await showDialog<bool>(
      context: page,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(no)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(yes)),
        ],
      ),
    );
    return answer ?? false;
  }

  /// The person tapped a file input: a short sheet of recent allowed files.
  static Future<String?> pickFile(List<String> acceptTypes) async {
    final page = context;
    if (page == null) return null;
    final files = _recentFiles(acceptTypes);
    return showModalBottomSheet<String>(
      context: page,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择要上传的文件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('下载 和 DCIM 里还没有能上传的文件'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final file in files)
                    ListTile(
                      dense: true,
                      title: Text(file.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(file.path),
                      onTap: () => Navigator.of(context).pop(file.path),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<File> _recentFiles(List<String> acceptTypes) {
    final found = <File>[];
    for (final folder in BrowserSession.uploadFolders) {
      final dir = Directory(folder);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is File) found.add(entity);
        }
      } catch (_) {}
    }
    found.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return found.where((file) => _accepts(file, acceptTypes)).take(40).toList();
  }

  static bool _accepts(File file, List<String> acceptTypes) {
    final path = file.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot + 1) : '';
    if (!BrowserSession.allowedUploadExtensions.contains(ext)) return false;
    if (acceptTypes.isEmpty) return true;
    for (final type in acceptTypes) {
      final t = type.trim().toLowerCase();
      if (t.isEmpty || t == '*/*') return true;
      if (t.startsWith('.')) {
        if (t.substring(1) == ext) return true;
      } else if (t.endsWith('/*')) {
        final prefix = t.substring(0, t.length - 1);
        if (_mimeOf(ext).startsWith(prefix)) return true;
      } else if (t == _mimeOf(ext)) {
        return true;
      }
    }
    return false;
  }

  /// The MIME type a page should see for [name].
  static String mimeFor(String name) {
    final dot = name.lastIndexOf('.');
    return _mimeOf(dot > 0 ? name.substring(dot + 1).toLowerCase() : '');
  }

  static String _mimeOf(String ext) => switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'txt' || 'md' || 'log' => 'text/plain',
    'json' => 'application/json',
    'mp4' => 'video/mp4',
    'mp3' => 'audio/mpeg',
    _ => 'application/octet-stream',
  };
}

/// Keeps the WebView alive under the app: full size, covered by the chat
/// while the browser page is closed, so tools can still read, click and
/// capture it without the page popping up over the conversation.
class BrowserHost extends StatelessWidget {
  const BrowserHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Rebuilds when the page is shown and when a tab appears or goes: a page the
    // tools opened while the browser screen was closed still has to be mounted,
    // or it has no size to lay out (and no snapshot, no screenshot).
    return Stack(
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([BrowserSession.instance.visible, BrowserSession.instance.tabsRevision]),
          builder: (context, _) {
            final session = BrowserSession.instance;
            if (session.visible.value || !session.opened) return const SizedBox.shrink();
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
