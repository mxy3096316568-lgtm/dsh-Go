// 看护（watch）：盯着一个网页上的某样东西，变了再告诉人。
//
// 只在本机做：定时取页面、抽正文、和上次比，有变化就发一条本机通知。
// 不做全站镜像、不做反爬；间隔最小 5 分钟，页间不并发，失败退避。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/proxy/proxy_service.dart';

/// 一条看护。
class WatchItem {
  const WatchItem({
    required this.id,
    required this.label,
    required this.url,
    required this.keyword,
    required this.everySeconds,
    required this.sessionId,
    this.active = true,
    this.lastHash = '',
    this.lastSnippet = '',
    this.lastCheckedAtMs = 0,
    this.changes = 0,
    this.lastError = '',
  });

  final String id;

  /// 人给它的名字，例如「机票价格」。
  final String label;

  /// 要看的页面。
  final String url;

  /// 关注什么：页面上出现这个词附近的内容才算数；空 = 整页正文。
  final String keyword;

  /// 检查间隔（秒），最小 300。
  final int everySeconds;

  /// 建的时候正在看的会话：通知点开回到那里。
  final String sessionId;

  final bool active;

  /// 上次看到的内容哈希，用来判断“变了”。
  final String lastHash;

  /// 上次变化时抓到的片段，给通知和列表看。
  final String lastSnippet;

  final int lastCheckedAtMs;

  /// 累计变化次数。
  final int changes;

  /// 上次失败的原因（成功时为空）。
  final String lastError;

  WatchItem copyWith({
    String? label,
    String? url,
    String? keyword,
    int? everySeconds,
    bool? active,
    String? lastHash,
    String? lastSnippet,
    int? lastCheckedAtMs,
    int? changes,
    String? lastError,
  }) => WatchItem(
    id: id,
    label: label ?? this.label,
    url: url ?? this.url,
    keyword: keyword ?? this.keyword,
    everySeconds: everySeconds ?? this.everySeconds,
    sessionId: sessionId,
    active: active ?? this.active,
    lastHash: lastHash ?? this.lastHash,
    lastSnippet: lastSnippet ?? this.lastSnippet,
    lastCheckedAtMs: lastCheckedAtMs ?? this.lastCheckedAtMs,
    changes: changes ?? this.changes,
    lastError: lastError ?? this.lastError,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'url': url,
    'keyword': keyword,
    'every': everySeconds,
    'session': sessionId,
    'active': active,
    'hash': lastHash,
    'snippet': lastSnippet,
    'at': lastCheckedAtMs,
    'changes': changes,
    'error': lastError,
  };

  static WatchItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || url is! String || id.isEmpty || url.isEmpty) return null;
    return WatchItem(
      id: id,
      label: raw['label'] is String && (raw['label'] as String).isNotEmpty ? raw['label'] as String : url,
      url: url,
      keyword: raw['keyword'] is String ? raw['keyword'] as String : '',
      everySeconds: raw['every'] is int && (raw['every'] as int) >= 300 ? raw['every'] as int : 900,
      sessionId: raw['session'] is String ? raw['session'] as String : '',
      active: raw['active'] != false,
      lastHash: raw['hash'] is String ? raw['hash'] as String : '',
      lastSnippet: raw['snippet'] is String ? raw['snippet'] as String : '',
      lastCheckedAtMs: raw['at'] is int ? raw['at'] as int : 0,
      changes: raw['changes'] is int ? raw['changes'] as int : 0,
      lastError: raw['error'] is String ? raw['error'] as String : '',
    );
  }

  bool due(int nowMs) => active && (lastCheckedAtMs == 0 || nowMs - lastCheckedAtMs >= everySeconds * 1000);
}

/// 看护的存储与执行。所有方法都不抛异常：看护是辅助功能，失败不该影响聊天。
class WatchService {
  WatchService._();

  static final WatchService instance = WatchService._();

  static const String _key = 'watch.items';

  /// 一次检查的结果，给页面「立即检查」用。
  static const Duration _timeout = Duration(seconds: 25);

  final List<WatchItem> _items = <WatchItem>[];
  bool _loaded = false;
  Timer? _timer;
  bool _running = false;

  static final RegExp _whitespace = RegExp(r'\s+');

  List<WatchItem> get items => List<WatchItem>.unmodifiable(_items);

  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final watch = WatchItem.fromJson(item);
        if (watch != null) _items.add(watch);
      }
    } catch (_) {
      _items.clear();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(<Object?>[for (final item in _items) item.toJson()]));
    } catch (_) {
      // 存不下就只在这次运行里有效。
    }
  }

  Future<WatchItem> add({
    required String url,
    required String label,
    required String keyword,
    required int everySeconds,
    required String sessionId,
  }) async {
    await load();
    final item = WatchItem(
      id: 'w${DateTime.now().microsecondsSinceEpoch}',
      label: label.trim().isEmpty ? url : label.trim(),
      url: url.trim(),
      keyword: keyword.trim(),
      everySeconds: everySeconds < 300 ? 300 : everySeconds,
      sessionId: sessionId,
    );
    _items.insert(0, item);
    await _save();
    return item;
  }

  Future<void> remove(String id) async {
    await load();
    _items.removeWhere((item) => item.id == id);
    await _save();
  }

  Future<void> setActive(String id, bool active) async {
    await load();
    final at = _items.indexWhere((item) => item.id == id);
    if (at < 0) return;
    _items[at] = _items[at].copyWith(active: active);
    await _save();
  }

  /// 起一个每分钟看一眼的循环：谁到点了就检查谁。重复调用只有一个循环。
  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(tick()));
    unawaited(tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  /// 检查所有到点的看护；返回这次真的检查了几条。
  Future<int> tick() async {
    await load();
    var checked = 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final item in List<WatchItem>.of(_items)) {
      if (!item.due(nowMs)) continue;
      await check(item.id);
      checked += 1;
      // 一条一条来：对别人的站点客气，也免得同一时间开一堆连接。
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return checked;
  }

  /// 检查一条；返回它现在的内容有没有变化。
  Future<bool> check(String id) async {
    await load();
    final at = _items.indexWhere((item) => item.id == id);
    if (at < 0) return false;
    final item = _items[at];
    final text = await _read(item);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (text == null) {
      _items[at] = item.copyWith(lastCheckedAtMs: nowMs, lastError: '打不开这个页面');
      await _save();
      return false;
    }
    final snippet = _snippet(text, item.keyword);
    final hash = _hashOf(snippet);
    final first = item.lastHash.isEmpty;
    final changed = !first && hash != item.lastHash;
    _items[at] = item.copyWith(
      lastHash: hash,
      lastSnippet: snippet,
      lastCheckedAtMs: nowMs,
      changes: changed ? item.changes + 1 : item.changes,
      lastError: '',
    );
    await _save();
    if (changed) await _notify(_items[at], snippet);
    return changed;
  }

  // ── 抓取 ────────────────────────────────────────────────────────────────

  static String _hashOf(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = (hash ^ unit) * 0x01000193 & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  /// 关注词附近 240 字；没有关注词就整页正文（截断）。
  static String _snippet(String text, String keyword) {
    final whole = text.replaceAll(_whitespace, ' ').trim();
    if (keyword.isEmpty) return whole.length > 600 ? whole.substring(0, 600) : whole;
    final at = whole.indexOf(keyword);
    if (at < 0) return '（页面上没找到「$keyword」）';
    final start = at - 80 < 0 ? 0 : at - 80;
    final end = at + keyword.length + 160;
    return whole.substring(start, end > whole.length ? whole.length : end).trim();
  }

  Future<String?> _read(WatchItem item) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    ProxyRoute.apply(client);
    try {
      final request = await client.getUrl(Uri.parse(item.url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) dsh-go watch');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode >= 400) {
        await response.drain<void>();
        return null;
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.isNotEmpty && !type.contains('html') && !type.startsWith('text/')) {
        await response.drain<void>();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > 3 * 1024 * 1024) break;
      }
      final raw = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      final document = html_parser.parse(raw);
      for (final el in document.querySelectorAll('script, style, noscript, svg')) {
        el.remove();
      }
      return document.body?.text ?? raw;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 本机通知：点开回到建看护时那个会话。
  Future<void> _notify(WatchItem item, String snippet) async {
    try {
      await const MethodChannel('dsh/notify').invokeMethod<void>('show', <String, Object?>{
        'group': 'watch',
        'key': item.id,
        'sessionId': item.sessionId,
        'title': '看护：${item.label} 有变化',
        'text': snippet,
        'publicText': '${item.label} 有更新',
        'attention': true,
        'kind': 'watch',
      });
    } catch (_) {
      // 没有原生通知（桌面/测试）或系统不给发：变化仍记在列表里。
    }
  }
}
