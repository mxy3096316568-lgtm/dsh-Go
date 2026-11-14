import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动方式: whether a cold launch asks Android to open this activity in a
/// small freeform window instead of full screen.
///
/// The value is read on the native side too (MainActivity, key
/// `flutter.start_in_small_window`), which is what actually sizes the window:
/// by the time Dart runs the window is already built, so the native launch
/// has to consult the stored preference itself.
class StartWindowController extends Notifier<bool> {
  static const key = 'start_in_small_window';

  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(key) ?? false;
    } catch (_) {}
  }

  Future<void> setStartInSmallWindow(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }
}

final startWindowProvider = NotifierProvider<StartWindowController, bool>(StartWindowController.new);
