import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// File operations run only in the recorder isolate (or isolated unit tests).
/// Only files with this store's names in its dedicated directory are managed.
class RollingVoiceStore {
  RollingVoiceStore(
    this.directory, {
    this.retention = const Duration(hours: 24),
    this.maxBytes = 6 * 1024 * 1024 * 1024,
    this.maxPinnedBytes = 1024 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    directory.createSync(recursive: true);
    pinned.createSync();
    recover();
    _normal = _files(directory);
    _kept = _files(pinned);
    for (final f in [..._normal, ..._kept]) {
      _sizes[f.path] = f.lengthSync();
    }
    prune();
  }
  final Directory directory;
  Directory get pinned => Directory('${directory.path}/kept');
  Duration retention;
  final int maxBytes, maxPinnedBytes;
  final DateTime Function() _clock;
  final String _session = Random.secure()
      .nextInt(0xffffffff)
      .toRadixString(16)
      .padLeft(8, '0');
  static final _pattern = RegExp(
    r'^rx_(\d{13})_(\d+)_([a-f0-9]{8})_(\d+)\.(wav|part)$',
  );
  late List<File> _normal, _kept;
  final Map<String, int> _sizes = {};
  RandomAccessFile? _file;
  File? _active;
  int _bytes = 0, _sequence = 0, _radio = -1, _minute = -1;
  String _channel = '';
  static Uint8List header(int bytes) {
    final out = Uint8List(44), d = ByteData.sublistView(out);
    void tag(int at, String value) {
      out.setRange(at, at + value.length, value.codeUnits);
    }

    tag(0, 'RIFF');
    d.setUint32(4, bytes + 36, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    d.setUint32(16, 16, Endian.little);
    d.setUint16(20, 1, Endian.little);
    d.setUint16(22, 1, Endian.little);
    d.setUint32(24, 32000, Endian.little);
    d.setUint32(28, 64000, Endian.little);
    d.setUint16(32, 2, Endian.little);
    d.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    d.setUint32(40, bytes, Endian.little);
    return out;
  }

  String _name(File file) => file.uri.pathSegments.last;
  List<File> _files(Directory dir) =>
      dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where(
            (f) => _pattern.hasMatch(_name(f)) && _name(f).endsWith('.wav'),
          )
          .toList()
        ..sort((a, b) => _name(a).compareTo(_name(b)));
  void append(int radio, String channel, Uint8List pcm) {
    if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 256 * 1024) return;
    final now = _clock().toUtc(), minute = now.millisecondsSinceEpoch ~/ 60000;
    if (_file != null &&
        (_minute != minute ||
            _radio != radio ||
            _channel != channel ||
            _bytes + pcm.length > 3840000)) {
      finish();
    }
    if (_file == null) {
      prune(reserve: 3840044);
      _minute = minute;
      _radio = radio;
      _channel = channel;
      _active = File(
        '${directory.path}/rx_${now.millisecondsSinceEpoch}_${radio}_${_session}_${_sequence++}.part',
      );
      _file = _active!.openSync(mode: FileMode.write);
      _file!.writeFromSync(header(0));
      _bytes = 0;
    }
    _file!.writeFromSync(pcm);
    _bytes += pcm.length;
  }

  void finish() {
    final file = _file, active = _active;
    _file = null;
    _active = null;
    if (file == null || active == null) return;
    try {
      file.setPositionSync(0);
      file.writeFromSync(header(_bytes));
      file.flushSync();
    } finally {
      file.closeSync();
    }
    if (_bytes > 0) {
      final completed = active.renameSync(
        active.path.replaceFirst(RegExp(r'\.part$'), '.wav'),
      );
      _normal.add(completed);
      _normal.sort((a, b) => _name(a).compareTo(_name(b)));
      _sizes[completed.path] = _bytes + 44;
    } else {
      active.deleteSync();
    }
    _bytes = 0;
    prune();
  }

  void maintenance() {
    if (_file != null &&
        _clock().toUtc().millisecondsSinceEpoch ~/ 60000 != _minute) {
      finish();
    }
    prune();
  }

  void recover() {
    for (final file
        in directory.listSync(followLinks: false).whereType<File>()) {
      if (!_pattern.hasMatch(_name(file)) || !_name(file).endsWith('.part')) {
        continue;
      }
      final size = file.lengthSync();
      if (size <= 44) {
        file.deleteSync();
        continue;
      }
      final payload = (size - 44) ~/ 2 * 2;
      final handle = file.openSync(mode: FileMode.append);
      try {
        handle.truncateSync(payload + 44);
        handle.setPositionSync(0);
        handle.writeFromSync(header(payload));
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      file.renameSync(file.path.replaceFirst(RegExp(r'\.part$'), '.wav'));
    }
  }

  void prune({int reserve = 0}) {
    final files = List<File>.from(_normal),
        cutoff = _clock().toUtc().subtract(retention).millisecondsSinceEpoch;
    var total =
        files.fold<int>(0, (sum, f) => sum + (_sizes[f.path] ?? 0)) +
        _bytes +
        (_file == null ? 0 : 44) +
        reserve;
    for (final file in files) {
      final stamp = int.parse(_pattern.firstMatch(_name(file))![1]!);
      if (stamp < cutoff || total > maxBytes) {
        total -= _sizes.remove(file.path) ?? 0;
        _normal.remove(file);
        if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          file.deleteSync();
        }
      }
    }
  }

  String preserveLatest() {
    finish();
    // Users may clear kept clips through Explorer while recording is running.
    for (final file in _kept) {
      _sizes.remove(file.path);
    }
    _kept = _files(pinned);
    for (final file in _kept) {
      _sizes[file.path] = file.lengthSync();
    }
    final files = _normal;
    if (files.isEmpty) return 'no_recording';
    final file = files.last,
        total = _kept.fold<int>(0, (sum, f) => sum + (_sizes[f.path] ?? 0));
    if (total + (_sizes[file.path] ?? 0) > maxPinnedBytes) {
      return 'kept_storage_full';
    }
    final bytes = _sizes.remove(file.path) ?? 0;
    final saved = file.renameSync('${pinned.path}/${_name(file)}');
    _normal.remove(file);
    _kept.add(saved);
    _sizes[saved.path] = bytes;
    return 'saved';
  }

  Map<String, Object?> snapshot() {
    final files = _normal, kept = _kept;
    return {
      'folder': directory.path,
      'retentionHours': retention.inHours,
      'files': files.length,
      'keptFiles': kept.length,
      'bytes':
          files.fold<int>(0, (sum, f) => sum + (_sizes[f.path] ?? 0)) + _bytes,
      'keptBytes': kept.fold<int>(0, (sum, f) => sum + (_sizes[f.path] ?? 0)),
      'active': _file != null,
      'maxBytes': maxBytes,
      'recent': [...files, ...kept].reversed
          .take(10)
          .map(
            (f) => {
              'name': _name(f),
              'bytes': _sizes[f.path] ?? 0,
              'kept': f.parent.path == pinned.path,
            },
          )
          .toList(),
    };
  }
}
