import 'package:flutter/services.dart';

/// 常驻: whether the engine is up in the background, exempt from battery
/// optimization, and comes back by itself after a reboot.
class KeepAliveStatus {
  const KeepAliveStatus({
    this.boot = false,
    this.service = false,
    this.batteryExempt = false,
    this.replayable = false,
  });

  /// 开机自启 is on.
  final bool boot;

  /// The foreground service (and with it the engine) is running.
  final bool service;

  /// Android's battery optimization leaves this app alone.
  final bool batteryExempt;

  /// A start environment was saved, so a boot start can replay it.
  final bool replayable;

  factory KeepAliveStatus.fromMap(Map<String, Object?>? map) => KeepAliveStatus(
    boot: map?['boot'] == true,
    service: map?['service'] == true,
    batteryExempt: map?['batteryExempt'] == true,
    replayable: map?['replayable'] == true,
  );
}

/// Channel `dsh/keepalive` (keepalive/KeepAlivePlugin.kt). Absent on a host
/// without the native side (tests): every call answers the defaults.
class KeepAliveBridge {
  static const _channel = MethodChannel('dsh/keepalive');

  static Future<KeepAliveStatus> status() => _call('status');

  static Future<KeepAliveStatus> setBoot(bool enabled) => _call('setBoot', {'enabled': enabled});

  /// Starts the engine's foreground service when it is not running.
  static Future<KeepAliveStatus> ensureService() => _call('ensureService');

  static Future<KeepAliveStatus> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return KeepAliveStatus.fromMap(await _channel.invokeMapMethod<String, Object?>(method, args));
    } on MissingPluginException {
      return const KeepAliveStatus();
    } on PlatformException {
      return const KeepAliveStatus();
    }
  }
}
