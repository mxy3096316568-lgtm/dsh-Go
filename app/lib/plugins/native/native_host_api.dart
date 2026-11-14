// v1.4 host capabilities (docs/design/native-plugins-protocol.md §13): a plugin asks the app
// for data the host cannot see (this conversation, the selected text) or for an action only the
// app can take (fill the composer, post a notification, register a schedule). Every request is
// one `host.req` on the stream and exactly one `host.res` back.
//
// Rules that do not bend:
//   - 能力控制 → 插件权限 off: every request is refused, whatever was granted before.
//   - per plugin: the grant is `plugin:<package>:<capability>` in the authorization records, so a
//     plugin can neither inherit another plugin's grant nor a tool's approval.
//   - phone / tools are never remembered: each call asks again, because they spend money, delete
//     things and talk to the outside world.
//   - `send` only fills the composer. Nothing here can press the send button.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notify/notify_channel.dart';
import '../../state/capability_guard.dart';
import '../../state/chat_state.dart';
import '../../state/composer_insert.dart';
import '../../state/consent_store.dart';
import '../../state/hosts_state.dart';
import '../../ui/browser/browser_session.dart' show BrowserUi;

/// The one writable place a plugin owns, and the tool names `phone` may name.
/// (Kept here as documentation of the contract; the bridge enforces both.)
const nativeHostNeverRemembered = {'phone', 'tools'};
const nativeHostPluginConsentKind = 'plugin';

String nativeHostConsentKey(String package, String capability) => '$package:$capability';

String nativeHostConsentId(String package, String capability) =>
    '$nativeHostPluginConsentKind:${nativeHostConsentKey(package, capability)}';

/// What the app can do for a plugin. Faked in tests; the real one is [AppHostHandlers].
abstract interface class NativeHostHandlers {
  Future<String?> sessionText(String? sessionId, int limit);

  String? selection();

  void insertText(String text, String? sessionId);

  Future<bool> notify({
    required String package,
    required String? sessionId,
    required String title,
    required String text,
    required bool attention,
  });

  Future<Object?> schedule({
    required String package,
    required String? sessionId,
    required String title,
    required String prompt,
    required Map<String, Object?> timing,
  });
}

/// The app's side of §13: consent first, then the handler, then exactly one answer.
class NativeHostApi {
  NativeHostApi({
    required this.stream,
    required this.handlers,
    required this.consent,
    this.onError,
  });

  final DshGoStream stream;
  final NativeHostHandlers handlers;

  /// Asked for every request the app does not remember; `rememberable` is false for
  /// phone/tools, whose answer is used once and never stored.
  final Future<bool> Function(DshGoHostRequest request, {required bool rememberable}) consent;

  final void Function(Object error)? onError;

  StreamSubscription<DshGoHostRequest>? _sub;
  bool _disposed = false;

  void attach() {
    _sub ??= stream.hostRequests.listen((request) => unawaited(_handle(request)));
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _handle(DshGoHostRequest request) async {
    if (_disposed) return;
    final capability = request.capability;
    final allowed = await _allowed(request);
    if (!allowed) {
      stream.answerHost(request.id, code: 'denied', message: '用户没有允许这次「$capability」');
      return;
    }
    try {
      switch (capability) {
        case 'sessionText':
          final limit = _limit(request);
          final text = await handlers.sessionText(request.scope.sessionId, limit);
          _answer(request, {'text': text ?? ''});
        case 'selection':
          _answer(request, {'text': handlers.selection() ?? ''});
        case 'send':
          handlers.insertText(_text(request, 'text'), request.scope.sessionId);
          _answer(request, null);
        case 'notify':
          final shown = await handlers.notify(
            package: request.package,
            sessionId: request.scope.sessionId,
            title: _text(request, 'title'),
            text: _text(request, 'text'),
            attention: request.payload['attention'] == true,
          );
          if (shown) {
            _answer(request, null);
          } else {
            stream.answerHost(request.id, code: 'unavailable', message: '通知没有发出去：检查通知权限');
          }
        case 'schedule':
          final task = await handlers.schedule(
            package: request.package,
            sessionId: request.scope.sessionId,
            title: _text(request, 'title'),
            prompt: _text(request, 'prompt'),
            timing: request.payload['timing'] is Map
                ? Map<String, Object?>.from(request.payload['timing'] as Map)
                : const {},
          );
          _answer(request, task);
        case 'phone' || 'tools' || 'pluginFiles':
          // The bridge does the work once the app allowed it; there is nothing to run here.
          _answer(request, null);
        default:
          stream.answerHost(request.id, code: 'unsupported', message: '这个版本不认识 $capability');
      }
    } catch (error) {
      onError?.call(error);
      stream.answerHost(request.id, code: 'failed', message: '$error'.split('\n').first);
    }
  }

  Future<bool> _allowed(DshGoHostRequest request) async {
    if (!CapabilityGuard.allows('plugins')) {
      CapabilityGuard.noteDenial('plugins', '${request.capability}@${request.package}');
      return false;
    }
    if (!NativeHostApi.supported.contains(request.capability)) return false;
    final rememberable = !nativeHostNeverRemembered.contains(request.capability);
    return await consent(request, rememberable: rememberable);
  }

  static const supported = {
    'sessionText', 'selection', 'send', 'notify', 'phone', 'tools', 'schedule', 'pluginFiles',
  };

  int _limit(DshGoHostRequest request) {
    final raw = request.payload['limit'];
    return raw is int ? raw.clamp(1000, 20000).toInt() : 12000;
  }

  String _text(DshGoHostRequest request, String key) {
    final value = request.payload[key];
    return value is String ? value : '';
  }

  void _answer(DshGoHostRequest request, Object? value) {
    if (value == null) {
      stream.answerHost(request.id);
      return;
    }
    // UTF-8, not characters: the bridge refuses an answer over 64 KiB and would
    // then report a timeout, so trim here where it can still be read.
    var text = value is Map && value['text'] is String ? value['text'] as String : null;
    if (text != null) {
      text = trimToBytes(text, 60000);
      stream.answerHost(request.id, value: {'text': text});
      return;
    }
    stream.answerHost(request.id, value: value);
  }

  static String trimToBytes(String text, int maxBytes) {
    if (utf8.encode(text).length <= maxBytes) return text;
    var end = text.length;
    while (end > 0 && utf8.encode(text.substring(0, end)).length > maxBytes) {
      end -= maxBytes ~/ 4;
    }
    return '${text.substring(0, end)}\n…（超出长度，已截断）';
  }
}

/// The real handlers: this app's conversation, composer, notifications and schedule API.
class AppHostHandlers implements NativeHostHandlers {
  AppHostHandlers({required this.ref, required this.client, required this.host});

  final Ref ref;
  final DshClient? client;
  final HostRef host;

  @override
  Future<String?> sessionText(String? sessionId, int limit) async {
    if (sessionId == null || sessionId.isEmpty) return null;
    final state = ref.read(chatProvider(sessionId));
    return formatSessionText(state.items, limit: limit);
  }

  @override
  String? selection() => NativeSelectionStore.instance.text.value;

  @override
  void insertText(String text, String? sessionId) {
    if (text.trim().isEmpty) return;
    ref.read(composerInsertProvider.notifier).request(ComposerInsert(token: text, sessionId: sessionId));
  }

  @override
  Future<bool> notify({
    required String package,
    required String? sessionId,
    required String title,
    required String text,
    required bool attention,
  }) async {
    final scope = sessionId ?? 'plugin';
    return NotifyChannel().tryShow(
      NotifyPost(
        group: notifyGroup(host, scope),
        key: 'plugin:$package:${DateTime.now().millisecondsSinceEpoch}',
        attention: attention,
        title: title,
        text: text,
        publicText: attention ? '插件通知' : '插件通知（无提醒）',
        sessionId: scope,
        host: host,
        kind: 'plugin',
      ),
    );
  }

  @override
  Future<Object?> schedule({
    required String package,
    required String? sessionId,
    required String title,
    required String prompt,
    required Map<String, Object?> timing,
  }) async {
    final client = this.client;
    if (client == null) throw StateError('没有连着主机');
    if (sessionId == null || sessionId.isEmpty) throw StateError('这个动作不属于任何对话，登记不了定时任务');
    if (timing.isEmpty) throw StateError('缺少执行时间（timing）');
    final raw = await client.rpc.call('schedule/create', {
      'request': {
        'title': title,
        'prompt': prompt,
        'timing': timing,
        'target': {'kind': 'session', 'sessionId': sessionId},
      },
    });
    return {'task': raw};
  }
}

/// The text a plugin sees for a conversation: latest turns last, bounded.
String formatSessionText(List<ChatItem> items, {required int limit}) {
  final lines = <String>[];
  for (final item in items) {
    switch (item) {
      case UserChatItem(:final text):
        if (text.trim().isNotEmpty) lines.add('用户：${text.trim()}');
      case AssistantChatItem(:final text):
        if (text.trim().isNotEmpty) lines.add('助手：${text.trim()}');
      case ToolChatItem(:final name, :final arguments, :final resultText):
        final result = resultText.trim();
        lines.add('工具 $name(${_cut(arguments, 200)})${result.isEmpty ? '' : ' → ${_cut(result, 400)}'}');
      case NoticeChatItem(:final text):
        if (text.trim().isNotEmpty) lines.add('提示：${text.trim()}');
    }
  }
  var joined = lines.join('\n\n');
  if (joined.length > limit) joined = joined.substring(joined.length - limit);
  return joined;
}

String _cut(String text, int max) => text.length <= max ? text : '${text.substring(0, max)}…';

/// The last text the person selected in a message (长按 → 选择文字). One place, so a
/// plugin's `selection` capability and the quote button agree on what "selected" is.
class NativeSelectionStore {
  NativeSelectionStore._();

  static final instance = NativeSelectionStore._();

  final ValueNotifier<String> text = ValueNotifier('');

  void set(String value) {
    final trimmed = value.trim();
    text.value = trimmed.length <= 4000 ? trimmed : trimmed.substring(0, 4000);
  }

  void clear() => text.value = '';
}

/// Asks the person, and remembers what may be remembered.
Future<bool> showNativeHostConsent(
  DshGoHostRequest request, {
  required bool rememberable,
  required String pluginTitle,
}) async {
  final store = ConsentStore.instance;
  await store.load();
  final key = nativeHostConsentId(request.package, request.capability);
  if (rememberable && store.has(key)) return true;
  if (!rememberable) await store.revoke(key);
  final context = BrowserUi.navigatorKey?.currentContext;
  if (context == null) return false;
  final description = describeHostRequest(request);
  final choice = await showDialog<NativeHostConsentChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('「$pluginTitle」$description'),
      content: Text(
        [
          '这是插件 ${request.package} 发出的请求。',
          if (rememberable) '允许后记进 授权记录，可以随时撤销；' else '这类操作每次都会问你，不提供「总是允许」。',
          '能力开关关闭时所有插件请求都会被拒绝。',
        ].join('\n'),
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(NativeHostConsentChoice.deny),
          child: const Text('拒绝'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(NativeHostConsentChoice.once),
          child: const Text('允许一次'),
        ),
        if (rememberable)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(NativeHostConsentChoice.always),
            child: const Text('总是允许'),
          ),
      ],
    ),
  );
  if (choice == null || choice == NativeHostConsentChoice.deny) return false;
  if (choice == NativeHostConsentChoice.always) {
    await store.remember(
      ConsentGrant(
        kind: nativeHostPluginConsentKind,
        scope: nativeHostConsentKey(request.package, request.capability),
        label: '$pluginTitle：$description',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        requires: const <String>['plugins'],
      ),
    );
  }
  return true;
}

enum NativeHostConsentChoice { deny, once, always }

/// One line the dialog can say about a request, without leaking its payload.
String describeHostRequest(DshGoHostRequest request) {
  final summary = request.payload['summary'];
  final detail = summary is String && summary.isNotEmpty ? summary : (request.payload['path'] as String? ?? '');
  return switch (request.capability) {
    'sessionText' => '想读取当前对话的全文（只读）',
    'selection' => '想读取你选中的文字',
    'send' => '想把一段文字填进输入框（不会自动发送）',
    'notify' => '想发一条本机通知',
    'schedule' => '想登记一个定时任务',
    'phone' => '想操作手机：${_cut(detail.isEmpty ? '一个手机工具' : detail, 160)}',
    'tools' => '想运行工具：${_cut(detail.isEmpty ? '一个工具' : detail, 160)}',
    'pluginFiles' => '想在自己的数据目录里${request.payload['op'] ?? '操作'}${detail.isEmpty ? '' : ' $detail'}',
    _ => '想使用 ${request.capability}',
  };
}
