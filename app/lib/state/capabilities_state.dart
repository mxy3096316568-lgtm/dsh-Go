import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 能力控制: the switches on 设置 → 帮助与关于 → 能力控制, one place for
/// everything this build adds beyond the original chat.
class CapabilitiesController extends Notifier<Map<String, bool>> {
  static const prefix = 'cap.';

  /// The switch keys, in the order the page shows them.
  static const keys = <String>[
    'browser',
    'cloud',
    'keepalive',
    'notify',
    'automation',
    'screen',
    'files',
    'voice',
    'memory',
    'plugins',
  ];

  static Map<String, bool> _all(bool value) => {for (final k in keys) k: value};

  @override
  Map<String, bool> build() {
    // Off until read back, so a switch never shows "on" before its saved value.
    unawaited(_load());
    return _all(true);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = <String, bool>{};
      for (final k in keys) {
        next[k] = prefs.getBool('$prefix$k') ?? true;
      }
      state = next;
    } catch (_) {}
  }

  Future<void> set(String key, bool value) async {
    state = {...state, key: value};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$prefix$key', value);
    } catch (_) {}
  }

  Future<void> pauseAll() async {
    state = _all(false);
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in keys) {
        await prefs.setBool('$prefix$k', false);
      }
    } catch (_) {}
  }
}

final capabilitiesProvider = NotifierProvider<CapabilitiesController, Map<String, bool>>(CapabilitiesController.new);
