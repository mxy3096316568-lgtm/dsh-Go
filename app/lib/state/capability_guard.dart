import 'package:flutter/foundation.dart';

/// 能力控制's switches, where the tools actually look.
///
/// One place decides whether a capability is on: the local API every browser / cloud /
/// notification tool goes through asks here, instead of each tool re-checking its own switch.
/// The settings controller pushes its state in ([update]) whenever a switch changes, and the
/// last refusals are kept for 能力控制 → 排查 and for the `capability_state` tool.
class CapabilityGuard {
  CapabilityGuard._();

  /// Tools exist and are refused when off.
  static const enforced = {'browser', 'files', 'cloud', 'notify'};

  /// Off also turns off the phone-control master switch (no tool of ours goes through it).
  static const partial = {'screen'};

  /// Nothing to enforce yet: the page shows them as 尚未接入 and does not pretend.
  static const pending = {'automation', 'voice', 'memory', 'plugins'};

  static const labels = <String, String>{
    'browser': '浏览器',
    'files': '文件',
    'cloud': '云盘',
    'notify': '通知',
    'screen': '屏幕控制',
    'automation': '自动化',
    'voice': '语音',
    'memory': '记忆',
    'plugins': '插件权限',
    'keepalive': '常驻',
  };

  static Map<String, bool> _values = const {};

  /// Last refusals, newest first: "12:31 browser 已关闭（browser_open）".
  static final ValueNotifier<List<String>> denials = ValueNotifier(const []);

  static Map<String, bool> get values => Map.unmodifiable(_values);

  static bool isOn(String key) => _values[key] ?? true;

  static void update(Map<String, bool> next) {
    _values = Map.unmodifiable(next);
  }

  /// The one check every tool entry point uses.
  static bool allows(String key) => isOn(key);

  static void noteDenial(String key, String tool) {
    final time = TimeOfDayShort.now();
    final line = '$time ${labels[key] ?? key} 已关闭（$tool）';
    denials.value = [line, ...denials.value].take(50).toList();
  }

  static String messageFor(String key) =>
      '${labels[key] ?? key}能力已关闭，请在 设置 → 帮助与关于 → 能力控制 打开';

  static Map<String, Object?> describe() => {
    'values': values,
    'enforced': enforced.toList(),
    'partial': partial.toList(),
    'pending': pending.toList(),
    'recentDenials': denials.value,
  };
}

/// A clock without pulling in intl: "HH:mm".
class TimeOfDayShort {
  static String now() {
    final time = DateTime.now();
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
