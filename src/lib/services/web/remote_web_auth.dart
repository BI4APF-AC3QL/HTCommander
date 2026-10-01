import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// In-memory, bounded sessions: restarting/reconfiguring the server revokes them.
class RemoteWebAuth {
  RemoteWebAuth(this.password, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final String password;
  final DateTime Function() _clock;
  final Map<String, DateTime> _sessions = {};
  final Map<String, DateTime> _forms = {};
  final Map<String, List<DateTime>> _failures = {};

  static String token() => base64UrlEncode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );

  String newForm() {
    _prune(_forms);
    if (_forms.length >= 64) _forms.remove(_forms.keys.first);
    final value = token();
    _forms[value] = _clock().add(const Duration(minutes: 5));
    return value;
  }

  bool consumeForm(String? cookie, String? field) {
    _prune(_forms);
    return cookie != null && field == cookie && _forms.remove(cookie) != null;
  }

  bool rateLimited(String address) {
    final now = _clock();
    _failures.removeWhere((_, times) {
      times.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
      return times.isEmpty;
    });
    return (_failures[address]?.length ?? 0) >= 5;
  }

  String? login(String address, String attemptedPassword) {
    if (rateLimited(address)) return null;
    final expected = sha256.convert(utf8.encode(password)).bytes;
    final actual = sha256.convert(utf8.encode(attemptedPassword)).bytes;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    if (difference != 0) {
      if (!_failures.containsKey(address) && _failures.length >= 256) {
        _failures.remove(_failures.keys.first);
      }
      (_failures[address] ??= []).add(_clock());
      return null;
    }
    _failures.remove(address);
    _prune(_sessions);
    if (_sessions.length >= 16) _sessions.remove(_sessions.keys.first);
    final session = token();
    _sessions[session] = _clock().add(const Duration(hours: 12));
    return session;
  }

  bool authenticated(String? token) {
    _prune(_sessions);
    return token != null && _sessions.containsKey(token);
  }

  void logout(String? token) => _sessions.remove(token);

  void _prune(Map<String, DateTime> entries) =>
      entries.removeWhere((_, expiry) => !expiry.isAfter(_clock()));
}
