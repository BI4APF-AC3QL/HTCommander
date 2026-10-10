import 'dart:convert';

/// Exporting free text cannot guarantee privacy. Share only fixed metadata.
class DiagnosticLog {
  static const maxEntries = 200;
  static const maxMessageChars = 2048;

  static String localText(String text, {Iterable<String> secrets = const []}) {
    // Bound work before matching hostile/huge incoming strings.
    var value = text.length > 8192 ? text.substring(0, 8192) : text;
    for (final secret in secrets.take(32)) {
      if (secret.isNotEmpty && secret.length <= 8192) {
        value = value.replaceAll(secret, '[redacted]');
      }
    }
    // Payloads, login lines and key material are omitted as a whole.
    if (RegExp(
      r'password|passwd|authorization|cookie|token|api.?key|passcode|private.key|BEGIN .*KEY|login .* pass |GPS|latitude|longitude|[A-Z0-9-]+>[^ ]+:|raw.*frame|frame.*(?:rx|tx)|(?:rx|tx).*frame',
      caseSensitive: false,
    ).hasMatch(value)) {
      return '[sensitive diagnostic text omitted]';
    }
    value = value.replaceAll(
      RegExp(r'https?://\S+', caseSensitive: false),
      '[address]',
    );
    value = value.replaceAll(
      RegExp(r'(?:[A-Za-z]:[\\/]|/Users/|/home/)\S+'),
      '[path]',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
      '[address]',
    );
    value = value.replaceAll(
      RegExp(r'\b[0-9a-f]{0,4}:[0-9a-f:]{2,}(?:%\w+)?\b', caseSensitive: false),
      '[address]',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b', caseSensitive: false),
      '[device]',
    );
    value = value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
    return value.length <= maxMessageChars
        ? value
        : '${value.substring(0, maxMessageChars)}…';
  }

  static Map<String, Object> metadata(Map entry) {
    final time = entry['time'];
    final parsed = time is String && time.length <= 64
        ? DateTime.tryParse(time)
        : null;
    return {
      if (parsed != null) 'time': parsed.toUtc().toIso8601String(),
      'level': entry['isError'] == true ? 'error' : 'info',
      'code': 'applicationDiagnostic',
    };
  }

  static String export(
    Iterable<Map> entries,
  ) => const JsonEncoder.withIndent('  ').convert({
    'format': 'htcommander-diagnostics-v1',
    'notice':
        'Only timestamps and fixed event metadata are shared. Free text is omitted.',
    'entries': entries.take(maxEntries).map(metadata).toList(),
  });

  /// Error class is chosen from SDK types; never uses an error's toString().
  static String errorCode(Object? error) {
    if (error is StateError) return 'stateError';
    if (error is RangeError) return 'rangeError';
    if (error is ArgumentError) return 'argumentError';
    if (error is FormatException) return 'formatError';
    if (error is UnsupportedError) return 'unsupportedError';
    if (error is TypeError) return 'typeError';
    return error == null ? 'unspecifiedError' : 'runtimeError';
  }

  static String crashRecord(String message, Object? error, StackTrace? stack) {
    final category = switch (message) {
      'Uncaught error' => 'uncaughtError',
      'Flutter framework error' => 'frameworkError',
      _ => 'applicationError',
    };
    // Keep only numeric package frame locations; no paths, method names or
    // exception strings. A support report can still identify the throw site.
    final sites = <String>[];
    var text = '';
    try {
      text = stack?.toString() ?? '';
    } catch (_) {}
    final bounded = text.length > 16384 ? text.substring(0, 16384) : text;
    for (final match in RegExp(
      r'package:htcommander/(?:[a-z_]+/)*([a-z_]{1,40}\.dart):(\d{1,6}):(\d{1,6})',
    ).allMatches(bounded).take(12)) {
      sites.add('${match[1]}:${match[2]}:${match[3]}');
    }
    return '[ERROR] $category ${errorCode(error)}${sites.isEmpty ? '' : ' sites=${sites.join(',')}'}';
  }

  /// Older versions wrote raw files. Public issue bodies never reuse them.
  static String safeCrashTail(String text) {
    final bounded = text.length > 32768
        ? text.substring(text.length - 32768)
        : text;
    final pattern = RegExp(
      r'^\[\d{4}-\d\d-\d\dT[0-9:.Z+\-]+\] \[ERROR\] (uncaughtError|frameworkError|applicationError) (stateError|argumentError|formatError|unsupportedError|rangeError|typeError|runtimeError|unspecifiedError)( sites=(?:[a-z_]{1,40}\.dart:\d{1,6}:\d{1,6})(?:,[a-z_]{1,40}\.dart:\d{1,6}:\d{1,6}){0,11})?$',
    );
    return bounded
        .split('\n')
        .where(pattern.hasMatch)
        .toList()
        .reversed
        .take(30)
        .toList()
        .reversed
        .join('\n');
  }
}
