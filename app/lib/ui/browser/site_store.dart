import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One site the browser has been to: what to show, where to go back to, and
/// whether the assistant may drive it.
class BrowserSite {
  const BrowserSite({
    required this.host,
    required this.title,
    required this.url,
    this.allowed = true,
    this.seen = 0,
  });

  final String host;
  final String title;
  final String url;
  final bool allowed;
  final int seen;

  BrowserSite copyWith({String? title, String? url, bool? allowed, int? seen}) => BrowserSite(
    host: host,
    title: title ?? this.title,
    url: url ?? this.url,
    allowed: allowed ?? this.allowed,
    seen: seen ?? this.seen,
  );

  Map<String, Object?> toJson() => {'h': host, 't': title, 'u': url, 'a': allowed, 'n': seen};

  static BrowserSite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final host = raw['h'];
    final url = raw['u'];
    if (host is! String || url is! String) return null;
    return BrowserSite(
      host: host,
      title: (raw['t'] as String?) ?? host,
      url: url,
      allowed: (raw['a'] as bool?) ?? true,
      seen: (raw['n'] as int?) ?? 0,
    );
  }
}

/// 站点库: the sites this browser has visited, kept across launches.
class SiteStore {
  static const key = 'browser.sites';
  static const _limit = 40;

  static Future<List<BrowserSite>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final out = <BrowserSite>[];
      for (final item in list) {
        final site = BrowserSite.fromJson(item);
        if (site != null) out.add(site);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<BrowserSite> sites) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode([for (final site in sites) site.toJson()]));
    } catch (_) {}
  }

  /// Records a visit: newest first, one entry per host.
  static Future<List<BrowserSite>> record({required String url, required String title}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return load();
    final sites = await load();
    final previous = sites.where((site) => site.host == uri.host).firstOrNull;
    final next = <BrowserSite>[
      BrowserSite(
        host: uri.host,
        title: title.trim().isEmpty ? uri.host : title.trim(),
        url: url,
        allowed: previous?.allowed ?? true,
        seen: (previous?.seen ?? 0) + 1,
      ),
      ...sites.where((site) => site.host != uri.host),
    ].take(_limit).toList();
    await _save(next);
    return next;
  }

  static Future<List<BrowserSite>> setAllowed(String host, bool allowed) async {
    final sites = await load();
    final next = [for (final site in sites) site.host == host ? site.copyWith(allowed: allowed) : site];
    await _save(next);
    return next;
  }
}
