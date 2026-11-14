// 授权记录: 「总是允许」落在本机，不进引擎配置。
//
// 只记三类里可以记住的那些：只读类工具、某个站点的上传。花钱 / 删除 / 对外发送的
// 动作不提供永久（[toolRememberable] 与 [ConsentGrant.sensitive] 决定），要撤销就
// 在这一页删掉一条，或全部清掉。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'capability_guard.dart';

/// 一条授权。
class ConsentGrant {
  const ConsentGrant({
    required this.kind,
    required this.scope,
    required this.label,
    required this.createdAtMs,
    this.sensitive = false,
    this.requires = const <String>[],
  });

  /// `tool`（工具审批）或 `upload`（上传到某个站点）。
  final String kind;

  /// 工具名，或上传目标站点。
  final String scope;

  /// 界面上怎么念它。
  final String label;

  final int createdAtMs;

  /// 属于「对外发送」类的授权：可以撤销，界面要标出来。
  final bool sensitive;

  /// 依赖的能力开关：关掉其中任何一个，这条授权自动失效（也不必再出现在列表里）。
  final List<String> requires;

  String get id => '$kind:$scope';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'label': label,
    'at': createdAtMs,
    'sensitive': sensitive,
    'requires': requires,
  };

  static ConsentGrant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final scope = raw['scope'];
    if (kind is! String || scope is! String || kind.isEmpty || scope.isEmpty) return null;
    return ConsentGrant(
      kind: kind,
      scope: scope,
      label: raw['label'] is String && (raw['label'] as String).isNotEmpty ? raw['label'] as String : scope,
      createdAtMs: raw['at'] is int ? raw['at'] as int : 0,
      sensitive: raw['sensitive'] == true,
      requires: raw['requires'] is List
          ? <String>[
              for (final item in raw['requires'] as List)
                if (item is String && item.isNotEmpty) item,
            ]
          : const <String>[],
    );
  }
}

class ConsentStore {
  ConsentStore._();

  static final ConsentStore instance = ConsentStore._();

  static const String _key = 'consent.grants';

  final Map<String, ConsentGrant> _grants = <String, ConsentGrant>{};
  bool _loaded = false;

  /// 新加的排前面。
  List<ConsentGrant> get grants {
    final list = _grants.values.toList()..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return List<ConsentGrant>.unmodifiable(list);
  }

  bool get loaded => _loaded;

  /// 读过一次就够；失败当空（宁可多问一次，不会少问）。
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
        final grant = ConsentGrant.fromJson(item);
        if (grant != null) _grants[grant.id] = grant;
      }
    } catch (_) {
      _grants.clear();
    }
  }

  /// 有这条授权，并且它依赖的能力开关都还开着。
  bool has(String id) {
    final grant = _grants[id];
    if (grant == null) return false;
    for (final key in grant.requires) {
      if (!CapabilityGuard.allows(key)) return false;
    }
    return true;
  }

  /// 当前真正生效的授权（能力开关关掉的那些不算）。
  List<ConsentGrant> get active => List<ConsentGrant>.unmodifiable(grants.where(live));

  bool hasAny(String kind) => _grants.values.where(live).any((grant) => grant.kind == kind);

  /// 这条授权现在是否生效（依赖的能力开关都开着）。
  bool live(ConsentGrant grant) {
    for (final key in grant.requires) {
      if (!CapabilityGuard.allows(key)) return false;
    }
    return true;
  }

  /// 能力开关关掉后调用：把依赖它的授权删掉，避免「开关关了、授权还在」。
  Future<int> pruneDisabled() async {
    await load();
    final dead = <String>[
      for (final grant in _grants.values)
        if (!live(grant)) grant.id,
    ];
    if (dead.isEmpty) return 0;
    for (final id in dead) {
      _grants.remove(id);
    }
    await _save();
    return dead.length;
  }

  /// 工具名 → 需要的能力开关。工具自己没说时按前缀认。
  static List<String> requiresForTool(String name) {
    final n = name.toLowerCase();
    if (n.contains('upload') || n.startsWith('kb_')) return const <String>['files'];
    if (n.startsWith('browser_')) return const <String>['browser'];
    if (n.startsWith('notify_')) return const <String>['notify'];
    if (n.startsWith('dav_') || n.startsWith('webdav_')) return const <String>['cloud'];
    return const <String>[];
  }

  Future<void> remember(ConsentGrant grant) async {
    await load();
    _grants[grant.id] = grant;
    await _save();
  }

  Future<void> revoke(String id) async {
    await load();
    if (_grants.remove(id) == null) return;
    await _save();
  }

  Future<void> revokeAll() async {
    await load();
    if (_grants.isEmpty) return;
    _grants.clear();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(<Object?>[for (final grant in _grants.values) grant.toJson()]));
    } catch (_) {
      // 存不下就只在这次运行里有效；下次还会问一次，不算更糟。
    }
  }

  // ── 哪些能记住 ──────────────────────────────────────────────────────────

  /// 只读类工具才给「总是允许」。名字里带这些词的（能花钱、能删、能对外发）不给。
  static const Set<String> _blocked = <String>{
    'send', 'post', 'upload', 'pay', 'buy', 'transfer', 'delete', 'remove', 'rm',
    'write', 'edit', 'exec', 'bash', 'pwsh', 'shell', 'run', 'install', 'uninstall',
    'click', 'tap', 'swipe', 'type', 'share', 'call', 'sms', 'open', 'kill', 'stop',
    'publish', 'comment', 'submit',
  };

  /// 明确认识的只读工具。
  static const Set<String> _readOnly = <String>{
    'read',
    'list',
    'glob',
    'grep',
    'search',
    'stat',
    'cat',
    'ls',
    'web_search',
    'web_fetch',
    'browser_state',
    'browser_read',
    'browser_snapshot',
    'browser_tabs',
    'browser_screenshot',
    'kb_search',
    'kb_read',
    'kb_stats',
    'kb_import',
    'kb_docs',
    'notify_status',
    'notify_list',
    'notify_search',
    'notify_digest',
    'dav_ls',
    'dav_search',
    'dav_config',
    'memory_recall',
    'session_search',
  };

  static const List<String> _readOnlyPrefixes = <String>['read_', 'list_', 'search_', 'get_', 'fetch_', 'recall_'];

  static bool toolRememberable(String name) {
    final n = name.toLowerCase().trim();
    if (n.isEmpty) return false;
    for (final bad in _blocked) {
      if (n.contains(bad)) return false;
    }
    if (_readOnly.contains(n)) return true;
    for (final good in _readOnlyPrefixes) {
      if (n.startsWith(good)) return true;
    }
    return false;
  }
}
