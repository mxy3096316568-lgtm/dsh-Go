import 'package:flutter/services.dart';

/// One notification as 通知中枢 keeps it.
class NotifyItem {
  const NotifyItem({
    required this.app,
    required this.package,
    required this.title,
    required this.text,
    required this.time,
    required this.timeText,
    this.ongoing = false,
  });

  final String app;
  final String package;
  final String title;
  final String text;
  final int time;
  final String timeText;
  final bool ongoing;

  factory NotifyItem.fromMap(Map<Object?, Object?> map) => NotifyItem(
    app: '${map['app'] ?? ''}',
    package: '${map['package'] ?? ''}',
    title: '${map['title'] ?? ''}',
    text: '${map['text'] ?? ''}',
    time: (map['time'] as num?)?.toInt() ?? 0,
    timeText: '${map['timeText'] ?? ''}',
    ongoing: map['ongoing'] == true,
  );

  String get line => '[$app] $timeText ${title.isEmpty ? '' : '$title：'}$text';

  Map<String, Object?> toJson() => {
    'app': app,
    'package': package,
    'title': title,
    'text': text,
    'time': time,
    'timeText': timeText,
    'ongoing': ongoing,
  };
}

/// Channel `dsh/notifications` (notifyreader/NotificationReaderPlugin.kt).
///
/// The listener only runs once the person grants 通知使用权 in the system's own list; without
/// it every call answers empty and [granted] is false.
class NotifyBridge {
  static const _channel = MethodChannel('dsh/notifications');

  static Future<({bool granted, int count})> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return (granted: map?['granted'] == true, count: (map?['count'] as num?)?.toInt() ?? 0);
    } on MissingPluginException {
      return (granted: false, count: 0);
    } on PlatformException {
      return (granted: false, count: 0);
    }
  }

  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<NotifyItem>> list({int limit = 30, String? app}) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('list', {'limit': limit, 'app': app});
      return _items(raw);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<NotifyItem>> search(String query, {int limit = 30}) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('search', {'query': query, 'limit': limit});
      return _items(raw);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Map<String, Object?>>> summary() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('summary') ?? const [];
      return [
        for (final entry in raw)
          if (entry is Map) entry.map((key, value) => MapEntry('$key', value)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 通知规则: keyword → 'record' | 'remind'.
  static Future<List<({String keyword, String action})>> rules() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('rules') ?? const [];
      return [
        for (final entry in raw)
          if (entry is Map) (keyword: '${entry['keyword']}', action: '${entry['action']}'),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<({String keyword, String action})>> addRule(String keyword, String action) async {
    try {
      await _channel.invokeListMethod<Object?>('addRule', {'keyword': keyword, 'action': action});
    } catch (_) {}
    return rules();
  }

  static Future<List<({String keyword, String action})>> removeRule(String keyword) async {
    try {
      await _channel.invokeListMethod<Object?>('removeRule', {'keyword': keyword});
    } catch (_) {}
    return rules();
  }

  static Future<List<NotifyItem>> hits({int limit = 50}) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('hits', {'limit': limit});
      return _items(raw);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clearHits() async {
    try {
      await _channel.invokeMethod<void>('clearHits');
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {}
  }

  static List<NotifyItem> _items(List<Object?>? raw) => [
    for (final entry in raw ?? const [])
      if (entry is Map) NotifyItem.fromMap(entry),
  ];
}
