// 剪贴板动作: 回到 App 时看一眼剪贴板, 只是"刚复制的东西"才递上来一件小事,
// 不做历史、不后台轮询、不自动发出去。
//
// Android 10 起剪贴板只在 App 在前台时能读, 所以这里只在 resumed 时读一次;
// 读不到(用户关了剪贴板访问)就安静地什么都不做。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ClipboardWatch {
  ClipboardWatch._();

  /// 刚复制、还没处理的内容; 有值时输入框上方会出现一条小条。
  static final ValueNotifier<String?> fresh = ValueNotifier<String?>(null);

  /// 上一次看过的内容, 用来判断"新复制了一份"。
  static String? _seen;

  /// 值得递上来的内容: 链接, 或者有点长度的文字(一两个词的复制不打扰)。
  static bool interesting(String text) {
    final value = text.trim();
    if (value.length < 8) return false;
    final lower = value.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return true;
    return value.length >= 20;
  }

  /// 读一次剪贴板; 与上次相同就不打扰。
  static Future<void> check() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;
      if (text == _seen) return;
      _seen = text;
      if (fresh.value == text) return;
      if (!interesting(text)) return;
      fresh.value = text;
    } catch (_) {
      // 没有剪贴板权限、系统不给读: 当作没复制过。
    }
  }

  /// 用户按了「粘贴」或「存进知识库」: 收起这一条, 不再重复提。
  static void consume() {
    _seen = fresh.value;
    fresh.value = null;
  }

  /// 用户点了「不用」: 这次运行里不再提同样的内容。
  static void dismiss() {
    _seen = fresh.value;
    fresh.value = null;
  }
}
