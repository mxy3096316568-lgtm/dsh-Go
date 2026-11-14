import 'package:dsh_app/ui/proxy/clash_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int count(String text, String key) => RegExp('^$key:', multiLine: true).allMatches(text).length;

  test('a subscription copy of an owned key is replaced, never duplicated', () {
    const yaml = 'proxies:\n'
        '  - {name: a, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n'
        'proxy-groups:\n'
        '  - {name: auto, type: url-test, proxies: [a]}\n'
        'rules:\n'
        '  - MATCH,auto\n'
        'mixed-port: 8888\n'
        'mode: global\n'
        'log-level: info\n'
        'external-controller: 0.0.0.0:9090\n'
        'allow-lan: true\n';
    final out = sanitizeClashConfig(yaml, port: 7890);
    for (final key in ['mixed-port', 'mode', 'log-level', 'external-controller', 'allow-lan']) {
      expect(count(out, key), 1, reason: '$key must appear once');
    }
    expect(out, contains('mixed-port: 7890'));
    expect(out, isNot(contains('mixed-port: 8888')));
    expect(out, contains('mode: rule'));
    expect(out, isNot(contains('mode: global')));
    expect(out, contains('external-controller: 127.0.0.1:9091'));
    expect(out, isNot(contains('allow-lan: true')));
    expect(out, contains('proxies:'));
    expect(out, contains('proxy-groups:'));
    expect(out, contains('  - MATCH,auto'));
  });

  test('a pasted config with CRLF line endings is cleaned too', () {
    const yaml = 'mode: global\r\nproxies:\r\n  - {name: a}\r\nrules:\r\n  - MATCH,DIRECT\r\n';
    final out = sanitizeClashConfig(yaml, port: 7891);
    expect(out, isNot(contains('mode: global')));
    expect(out, isNot(contains('\r')));
    expect(count(out, 'mode'), 1);
    expect(out, contains('mixed-port: 7891'));
    expect(out, contains('  - MATCH,DIRECT'));
  });

  test('an indented block under an owned key goes with it', () {
    const yaml = 'external-controller:\n'
        '  tls: true\n'
        '  host: 0.0.0.0\n'
        'proxies: []\n';
    final out = sanitizeClashConfig(yaml, port: 7892);
    expect(out, isNot(contains('tls: true')));
    expect(out, contains('external-controller: 127.0.0.1:9091'));
    expect(out, contains('proxies: []'));
  });

  test('a config without owned keys keeps its body byte for byte', () {
    const yaml = 'proxies:\n  - {name: a}\nrules:\n  - MATCH,DIRECT\n';
    final out = sanitizeClashConfig(yaml, port: 7893);
    expect(out, endsWith(yaml));
    expect(count(out, 'mixed-port'), 1);
  });

  test('socks-port and friends are dropped as well', () {
    const yaml = 'port: 1\nsocks-port: 2\nredir-port: 3\ntproxy-port: 4\nsecret: x\nexternal-ui: y\nrules: []\n';
    final out = sanitizeClashConfig(yaml, port: 7894);
    for (final key in ['port', 'socks-port', 'redir-port', 'tproxy-port', 'secret', 'external-ui']) {
      expect(count(out, key), 0, reason: '$key must be dropped');
    }
    expect(out, contains('rules: []'));
  });

  test('sanitising an already healed config changes nothing (idempotent)', () {
    const yaml = 'proxies:\n  - {name: a}\nrules:\n  - MATCH,DIRECT\nmode: global\n';
    final once = sanitizeClashConfig(yaml, port: 7895);
    final twice = sanitizeClashConfig(once, port: 7895);
    expect(twice, once);
  });
}
