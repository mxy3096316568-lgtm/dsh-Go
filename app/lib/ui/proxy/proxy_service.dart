import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 内置代理's live state (channel `dsh/proxy`, proxy/ProxyPlugin.kt).
class ProxyState {
  const ProxyState({
    this.running = false,
    this.port = 7890,
    this.webViewProxy = false,
    this.kernel = false,
    this.configured = false,
    this.error,
    this.subscription = '',
    this.hint = '',
  });

  final bool running;
  final int port;

  /// WebView actually uses the proxy (true once ProxyController accepted it).
  final bool webViewProxy;

  /// The kernel (`libmihomo.so`) is in the APK.
  final bool kernel;

  /// A subscription config was saved.
  final bool configured;

  final String? error;

  /// The last subscription URL or pasted config.
  final String subscription;

  /// A friendly line for the page, when something failed.
  final String hint;

  ProxyState copyWith({
    bool? running,
    int? port,
    bool? webViewProxy,
    bool? kernel,
    bool? configured,
    String? error,
    String? subscription,
    String? hint,
  }) => ProxyState(
    running: running ?? this.running,
    port: port ?? this.port,
    webViewProxy: webViewProxy ?? this.webViewProxy,
    kernel: kernel ?? this.kernel,
    configured: configured ?? this.configured,
    error: error ?? this.error,
    subscription: subscription ?? this.subscription,
    hint: hint ?? this.hint,
  );
}

/// 内置代理: a Clash (mihomo) kernel on 127.0.0.1, used by this app only — WebView through
/// `ProxyController`, downloads and the cloud client through [ProxyRoute]. No VPN, no system
/// setting: closing the switch puts everything back to direct.
class ProxyService {
  static const _channel = MethodChannel('dsh/proxy');

  static const _portKey = 'proxy.port';
  static const _subscriptionKey = 'proxy.subscription';
  static const _enabledKey = 'proxy.enabled';

  static final ValueNotifier<ProxyState> state = ValueNotifier(const ProxyState());

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final port = prefs.getInt(_portKey) ?? 7890;
      final subscription = prefs.getString(_subscriptionKey) ?? '';
      final enabled = prefs.getBool(_enabledKey) ?? false;
      final status = await _status();
      state.value = status.copyWith(port: port, subscription: subscription, configured: status.configured);
      if (enabled && !status.running) unawaited(start(quiet: true));
    } catch (_) {}
  }

  static Future<ProxyState> refresh() async {
    final status = await _status();
    state.value = status.copyWith(subscription: state.value.subscription);
    _applyRoute();
    return state.value;
  }

  /// Downloads (or takes) a Clash config, saves it, and starts the kernel.
  /// Returns null on success, otherwise the reason to show the person.
  static Future<String?> applySubscription(String input, {int? port}) async {
    final text = input.trim();
    if (text.isEmpty) return '先填订阅地址';
    String yaml;
    if (text.contains('proxies:') && text.contains('rules:')) {
      yaml = text;
    } else if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        final response = await http
            .get(Uri.parse(text), headers: {'user-agent': 'clash.meta'})
            .timeout(const Duration(seconds: 45));
        if (response.statusCode != 200) return '下载订阅失败（HTTP ${response.statusCode}）';
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (!body.contains('proxies:')) {
          return '这不是 Clash 配置。请用服务商提供的那种「Clash 订阅」地址，而不是 ss:// / vmess:// 分享链接。';
        }
        yaml = body;
      } on TimeoutException {
        return '订阅下载超时，检查网络或地址';
      } catch (error) {
        return '订阅下载失败：$error';
      }
    } else {
      return '填一个 https:// 开头的 Clash 订阅地址，或直接粘贴 Clash 配置';
    }
    final chosen = (port ?? state.value.port).clamp(1024, 65535).toInt();
    // A subscription brings its own ports and controller; ours have to win, so the
    // conflicting keys are dropped rather than left for the kernel to reject.
    final cleaned = yaml.replaceAll(
      RegExp(
        r'^(mixed-port|port|socks-port|redir-port|tproxy-port|allow-lan|bind-address|external-controller|secret|external-ui|mode|log-level):.*$',
        multiLine: true,
      ),
      '',
    );
    final config = 'mixed-port: $chosen\nallow-lan: false\nbind-address: 127.0.0.1\n'
        'external-controller: 127.0.0.1:9091\nmode: rule\nlog-level: warning\n$cleaned';
    try {
      final written = await _channel.invokeMapMethod<String, Object?>('writeConfig', {'content': config});
      if (written?['error'] != null) return '保存配置失败：${written?['message'] ?? written?['error']}';
    } on PlatformException catch (error) {
      return '保存配置失败：${error.message ?? error.code}';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionKey, text);
    await prefs.setInt(_portKey, chosen);
    await prefs.setBool(_enabledKey, true);
    state.value = state.value.copyWith(subscription: text, port: chosen, configured: true, hint: '');
    final result = await start();
    return result.running ? null : (result.hint.isEmpty ? '内核没起来，看能力控制 → 内置代理 里的日志' : result.hint);
  }

  static Future<ProxyState> start({bool quiet = false}) async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('start', {'port': state.value.port});
      final next = _merge(map);
      state.value = next;
      _applyRoute();
      final prefs = await SharedPreferences.getInstance();
      if (next.running) await prefs.setBool(_enabledKey, true);
      return next;
    } on PlatformException catch (error) {
      if (!quiet) state.value = state.value.copyWith(hint: '启动失败：${error.message ?? error.code}', error: error.code);
      return state.value;
    }
  }

  static Future<ProxyState> stop() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('stop');
      state.value = _merge(map);
      _applyRoute();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, false);
      return state.value;
    } on PlatformException catch (error) {
      return state.value.copyWith(hint: '停止失败：${error.message ?? error.code}');
    }
  }

  static Future<String> log() async {
    try {
      return (await _channel.invokeListMethod<String>('log') ?? const []).join('\n');
    } catch (_) {
      return '';
    }
  }

  static Future<ProxyState> _status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return _merge(map);
    } on PlatformException {
      return state.value.copyWith(kernel: false);
    } on MissingPluginException {
      return state.value.copyWith(kernel: false);
    }
  }

  static ProxyState _merge(Map<String, Object?>? map) {
    if (map == null) return state.value;
    final error = map['error'] as String?;
    final port = (map['port'] as num?)?.toInt() ?? state.value.port;
    return state.value.copyWith(
      running: map['running'] == true,
      port: port,
      webViewProxy: map['webViewProxy'] == true,
      kernel: map['kernel'] == true,
      configured: map['config'] == true,
      error: error,
      hint: _hintFor(map),
    );
  }

  static String _hintFor(Map<String, Object?> map) {
    switch (map['error']) {
      case 'kernel_missing':
        return '这个安装包里没有代理内核（libmihomo.so），需要重新构建';
      case 'no_config':
        return '还没有导入订阅';
      case 'start_timeout':
        return '内核启动了但 20 秒内端口没就绪，可能是订阅配置有问题（看下面的日志）';
      case 'start_failed':
        return '内核启动失败：${map['message'] ?? ''}';
      case 'write_failed':
        return '配置写不进 App 目录：${map['message'] ?? ''}';
      default:
        return '';
    }
  }

  static void _applyRoute() {
    final current = state.value;
    ProxyRoute.httpProxy = current.running ? 'PROXY 127.0.0.1:${current.port}' : null;
  }
}

/// Where the app's own HTTP clients send requests: the local port while 内置代理 is on.
class ProxyRoute {
  static String? httpProxy;

  /// `findProxy` for a fresh [HttpClient].
  static void apply(HttpClient client) {
    final route = httpProxy;
    if (route != null) client.findProxy = (_) => route;
  }
}
