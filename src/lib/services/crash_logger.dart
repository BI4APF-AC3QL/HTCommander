/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Writes uncaught startup and runtime errors to an on-disk log file so a user can
send diagnostics even when the application fails before its UI (and therefore
the Debug tab) is ever shown. Works on every non-web platform (Windows, macOS,
Linux, Android, iOS) using the platform application-support directory.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode, Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'diagnostic_log.dart';

/// Appends timestamped diagnostics to `htcommander_crash.log` in the platform
/// application-support directory.
///
/// The logger is safe to use before [init] completes: messages logged early are
/// buffered in memory and flushed to disk as soon as the file path resolves, so
/// early diagnostics can be retained. Writes are asynchronous, serialized and
/// bounded to keep disk stalls off the UI. Abrupt process termination may lose
/// the most recent pending records.
class CrashLogger {
  CrashLogger._() : _maxFileBytes = _maxBytes;

  /// Isolated file writer used by regression tests, never changes the singleton.
  CrashLogger.forTesting(File file, {int maxBytes = _maxBytes})
    : _file = file,
      _maxFileBytes = maxBytes {
    if (maxBytes < 1024) throw ArgumentError('Crash log limit too small');
  }

  /// The single shared instance.
  static final CrashLogger instance = CrashLogger._();

  /// The GitHub repository crash reports are filed against.
  static const String githubRepo = 'Ylianst/HTCommander';

  static const String _fileName = 'htcommander_crash.log';

  /// Rotate the log once it grows past this size so it never accumulates
  /// unbounded across many launches.
  static const int _maxBytes = 512 * 1024;

  File? _file;
  bool _initialized = false;
  final int _maxFileBytes;
  Future<void> _writing = Future<void>.value();
  int _queued = 0;
  int droppedRecords = 0;
  Future<void> flush() => _writing;

  /// Lines logged before the on-disk path resolved, flushed on [init].
  final List<String> _pending = <String>[];

  /// The resolved crash log file path, or null on web / before [init].
  String? get filePath => _file?.path;

  Future<String> _readSafeTail(File file) async {
    final reader = await file.open();
    try {
      final length = await reader.length();
      await reader.setPosition(length > 32768 ? length - 32768 : 0);
      return DiagnosticLog.safeCrashTail(
        utf8.decode(await reader.read(32768), allowMalformed: true),
      );
    } finally {
      await reader.close();
    }
  }

  /// Returns the last [maxChars] characters of the crash log file (trimmed to a
  /// whole-line boundary), or an empty string if the file is missing/unreadable.
  /// Used to embed recent errors and stack traces into a crash report.
  Future<String> readTail({int maxChars = 3000}) async {
    final file = _file;
    if (file == null) return '';
    try {
      if (!await file.exists()) return '';
      await flush();
      String content = await _readSafeTail(file);
      maxChars = maxChars.clamp(1, 32768);
      if (content.length > maxChars) {
        content = content.substring(content.length - maxChars);
        final firstNewline = content.indexOf('\n');
        if (firstNewline >= 0) content = content.substring(firstNewline + 1);
      }
      return content.trimRight();
    } catch (_) {
      return '';
    }
  }

  /// Returns the most recent logged error: its `[ERROR]` line plus the top of
  /// its stack trace (the throw site), or an empty string when none is found.
  ///
  /// Crash stack traces can be hundreds of frames deep, so [readTail] alone
  /// often captures only the outermost frames and drops the error message and
  /// the actual failing code. This surfaces the diagnostic head of the newest
  /// error so an embedded crash report is actionable.
  Future<String> readRecentError({int maxLines = 30}) async {
    final file = _file;
    if (file == null) return '';
    try {
      if (!await file.exists()) return '';
      await flush();
      final lines = (await _readSafeTail(file)).split('\n');
      var errorIndex = -1;
      for (var i = lines.length - 1; i >= 0; i--) {
        if (lines[i].contains('[ERROR]')) {
          errorIndex = i;
          break;
        }
      }
      if (errorIndex < 0) return '';
      final timestamped = RegExp(r'^\[\d{4}-\d\d-\d\d');
      final out = <String>[lines[errorIndex]];
      for (
        var i = errorIndex + 1;
        i < lines.length && out.length < maxLines;
        i++
      ) {
        final line = lines[i];
        // Stack frames after the first are not timestamped; a new timestamped
        // line that is not a frame marks the start of an unrelated log entry.
        if (timestamped.hasMatch(line) && !line.contains('#')) break;
        out.add(line);
      }
      return out.join('\n').trimRight();
    } catch (_) {
      return '';
    }
  }

  String get _platformLabel {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  /// Resolves the log file, archives the previous launch, flushes buffered lines
  /// and writes a startup banner. Never throws: diagnostics logging must not be
  /// able to crash the app.
  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      try {
        if (await file.exists()) {
          final old = File('${file.path}.1');
          if (await old.exists()) await old.delete();
          await file.rename(old.path);
        }
      } catch (_) {
        // Never append to a legacy raw file if archiving failed.
        return;
      }
      _file = file;

      // Flush anything buffered before the path resolved, then the banner.
      final buffered = List<String>.from(_pending);
      _pending.clear();
      for (final line in buffered) {
        _writeLine(line);
      }
      _write('[INFO] startup');
    } catch (_) {
      // If even the application-support directory is unavailable there is
      // nowhere to log; drop silently rather than crash.
    }
  }

  /// Records an error (with optional stack trace) to the log file.
  void logError(String message, [Object? error, StackTrace? stack]) {
    _write(DiagnosticLog.crashRecord(message, error, stack));
  }

  /// Records an informational line to the log file.
  void logInfo(String message) => _write('[INFO] applicationDiagnostic');

  /// Builds a pre-filled GitHub "New Issue" URL for a report. The body embeds
  /// the app version, platform and the most recent log (the on-disk crash log
  /// tail when available, otherwise [fallbackLog]) so the user can review and
  /// submit it under their own account — no server, no telemetry.
  ///
  /// Defaults produce a crash report; callers can override [title], [label],
  /// [promptHeader], [promptHint] and [attachNote] to file a different kind of
  /// issue (e.g. a general "Issue report" from the About box).
  Future<Uri> buildGithubIssueUri({
    String title = 'Crash report',
    String? label = 'crash',
    String promptHeader = '**What happened / what were you doing?**',
    String promptHint = '_(please describe the steps that led to the crash)_',
    String attachNote =
        'Review the redacted current crash log before attaching. Older rotated logs may contain private data.',
    String? fallbackLog,
    int maxLogChars = 2000,
  }) async {
    String version = 'unknown';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    String logTail = await readTail(maxChars: maxLogChars);
    if (logTail.isEmpty && fallbackLog != null) {
      logTail = '[Legacy free-text diagnostic fallback omitted]';
      if (logTail.length > maxLogChars) {
        logTail = logTail.substring(logTail.length - maxLogChars);
      }
    }

    // The head of the newest error (message + throw site). Deep stack traces
    // push this out of [logTail], so surface it explicitly to keep the report
    // actionable.
    final recentError = await readRecentError();

    final body = StringBuffer()
      ..writeln(promptHeader)
      ..writeln(promptHint)
      ..writeln()
      ..writeln('**App version:** $version')
      ..writeln('**Platform:** $_platformLabel')
      ..writeln();
    if (recentError.isNotEmpty) {
      body
        ..writeln('**Most recent error:**')
        ..writeln('```')
        ..writeln(recentError)
        ..writeln('```')
        ..writeln();
    }
    if (logTail.isNotEmpty) {
      body
        ..writeln('**Recent log:**')
        ..writeln('```')
        ..writeln(logTail)
        ..writeln('```')
        ..writeln();
    }
    body.writeln('> $attachNote');

    final query = <String, String>{'title': title, 'body': body.toString()};
    if (label != null && label.isNotEmpty) query['labels'] = label;

    return Uri.https('github.com', '/$githubRepo/issues/new', query);
  }

  void _write(String message) {
    final line = '[${DateTime.now().toUtc().toIso8601String()}] $message';
    _writeLine(line);
  }

  void _writeLine(String line) {
    // Every caller passes a fixed metadata record. Never write arbitrary text.
    final file = _file;
    if (file == null) {
      if (_pending.length == 64) _pending.removeAt(0);
      _pending.add(line);
      return;
    }
    if (_queued >= 64) {
      droppedRecords++;
      return;
    }
    _queued++;
    _writing = _writing.then((_) async {
      try {
        final record =
            '${line.length <= 2048 ? line : line.substring(0, 2048)}\n';
        if (await file.exists() &&
            await file.length() + record.length * 3 > _maxFileBytes) {
          final old = File('${file.path}.1');
          if (await old.exists()) await old.delete();
          await file.rename(old.path);
        }
        await file.writeAsString(record, mode: FileMode.append, flush: true);
      } catch (_) {
        droppedRecords++;
      } finally {
        _queued--;
      }
    });
  }
}
