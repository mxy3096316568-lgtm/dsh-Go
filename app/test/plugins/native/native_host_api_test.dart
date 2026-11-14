// v1.4 host capabilities in the app (docs/design/native-plugins-protocol.md §13):
// one answer per request, the right conversation, and phone/tools never remembered.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/plugins/native/native_host_api.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Socket implements DshGoSocket {
  _Socket(this.features);

  final List<String> features;
  final input = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];

  @override
  Stream<Object?> get messages => input.stream;

  @override
  void send(String text) {
    final map = jsonDecode(text) as Map<String, Object?>;
    sent.add(map);
    if (map['t'] == 'hello') {
      input.add(jsonEncode({'t': 'welcome', 'conn': 'c1', 'features': features}));
    }
  }

  void receive(Map<String, Object?> data) => input.add(jsonEncode(data));

  @override
  Future<void> close([int? code]) async {
    if (!input.isClosed) await input.close();
  }
}

class _FakeHandlers implements NativeHostHandlers {
  String? sessionId;
  int? limit;
  String? inserted;
  String? insertedSession;
  bool notified = false;
  Map<String, Object?>? timing;

  @override
  Future<String?> sessionText(String? sessionId, int limit) async {
    this.sessionId = sessionId;
    this.limit = limit;
    return '用户：你好';
  }

  @override
  String? selection() => 'selected text';

  @override
  void insertText(String text, String? sessionId) {
    inserted = text;
    insertedSession = sessionId;
  }

  @override
  Future<bool> notify({
    required String package,
    required String? sessionId,
    required String title,
    required String text,
    required bool attention,
  }) async {
    notified = true;
    return true;
  }

  @override
  Future<Object?> schedule({
    required String package,
    required String? sessionId,
    required String title,
    required String prompt,
    required Map<String, Object?> timing,
  }) async {
    this.timing = timing;
    return {'task': 't1'};
  }
}

Future<void> _pumpUntil(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

void main() {
  test('a sessionText request answers with the conversation the tap came from', () async {
    final socket = _Socket(const ['sessionText']);
    final stream = DshGoStream(() async => socket, features: const ['sessionText']);
    final handlers = _FakeHandlers();
    final asked = <(String, bool)>[];
    final api = NativeHostApi(
      stream: stream,
      handlers: handlers,
      consent: (request, {required rememberable}) async {
        asked.add((request.capability, rememberable));
        return true;
      },
    )..attach();
    addTearDown(() async {
      await api.dispose();
      await stream.close();
    });
    await stream.hold();
    socket.receive({
      't': 'host.req',
      'id': 'r1',
      'pkg': 'demo',
      'cap': 'sessionText',
      'scope': {'sessionId': 's1'},
      'payload': {'limit': 8000},
    });
    await _pumpUntil(() => socket.sent.any((m) => m['t'] == 'host.res'));
    final answer = socket.sent.last;
    expect(answer['id'], 'r1');
    expect(answer['ok'], true);
    expect(answer['value'], {'text': '用户：你好'});
    expect(handlers.sessionId, 's1');
    expect(handlers.limit, 8000);
    expect(asked, [('sessionText', true)]);
  });

  test('phone and tools are asked every time; send only fills the composer', () async {
    final socket = _Socket(const ['phone', 'tools', 'send']);
    final stream = DshGoStream(() async => socket, features: const ['phone', 'tools', 'send']);
    final handlers = _FakeHandlers();
    final rememberable = <String, bool>{};
    final api = NativeHostApi(
      stream: stream,
      handlers: handlers,
      consent: (request, {required rememberable: canRemember}) async {
        rememberable[request.capability] = canRemember;
        return true;
      },
    )..attach();
    addTearDown(() async {
      await api.dispose();
      await stream.close();
    });
    await stream.hold();
    void ask(String id, String cap, [Map<String, Object?> payload = const {}]) => socket.receive({
      't': 'host.req',
      'id': id,
      'pkg': 'demo',
      'cap': cap,
      'scope': {'sessionId': 's1'},
      'payload': payload,
    });
    ask('a', 'phone', {'tool': 'mcp__phone__screen', 'summary': 'mcp__phone__screen {}'});
    ask('b', 'tools', {'tool': 'web_search', 'summary': 'web_search {}'});
    ask('c', 'send', {'text': 'draft'});
    await _pumpUntil(() => socket.sent.where((m) => m['t'] == 'host.res').length == 3);
    expect(rememberable, {'phone': false, 'tools': false, 'send': true});
    expect(handlers.inserted, 'draft');
    expect(handlers.insertedSession, 's1');
    expect(socket.sent.where((m) => m['t'] == 'host.res').every((m) => m['ok'] == true), true);
  });

  test('a refusal is one host.res with a code, and nothing runs', () async {
    final socket = _Socket(const ['notify']);
    final stream = DshGoStream(() async => socket, features: const ['notify']);
    final handlers = _FakeHandlers();
    final api = NativeHostApi(
      stream: stream,
      handlers: handlers,
      consent: (request, {required rememberable}) async => false,
    )..attach();
    addTearDown(() async {
      await api.dispose();
      await stream.close();
    });
    await stream.hold();
    socket.receive({
      't': 'host.req',
      'id': 'r1',
      'pkg': 'demo',
      'cap': 'notify',
      'payload': {'title': 'T', 'text': 'B'},
    });
    await _pumpUntil(() => socket.sent.any((m) => m['t'] == 'host.res'));
    expect(socket.sent.last['ok'], false);
    expect(socket.sent.last['code'], 'denied');
    expect(handlers.notified, false);
  });

  test('the conversation text is bounded and keeps the latest turns', () {
    final items = <ChatItem>[
      for (var i = 0; i < 40; i++)
        UserChatItem(seq: i, time: DateTime(2026), text: '第$i条', images: const [], files: const []),
    ];
    final text = formatSessionText(items, limit: 120);
    expect(text.length, lessThanOrEqualTo(120));
    expect(text, contains('第39条'));
    expect(text, isNot(contains('第0条')));
  });

  test('answers are trimmed by UTF-8 bytes, not characters', () {
    final text = '汉' * 30000;
    final trimmed = NativeHostApi.trimToBytes(text, 60000);
    expect(utf8.encode(trimmed).length, lessThan(60050));
    expect(trimmed, endsWith('已截断）'));
  });

  test('the consent id is per plugin and capability', () {
    expect(nativeHostConsentId('demo', 'sessionText'), 'plugin:demo:sessionText');
    expect(nativeHostConsentId('demo', 'sessionText'), isNot(nativeHostConsentId('other', 'sessionText')));
  });
}
