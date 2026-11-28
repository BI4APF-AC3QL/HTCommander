import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/web/bounded_websocket_output.dart';

void main() {
  test('100000 audio blocks stay bounded and healthy client works', () {
    fakeAsync((t) {
      final blocked = Completer<void>(),
          writes = <Object>[],
          healthy = <Object>[];
      final q = BoundedWebSocketOutput(
        write: (v) {
          writes.add(v);
          return blocked.future;
        },
        onFailure: fail,
        maxBytes: 16,
        maxMessages: 4,
        clock: () => t.elapsed,
      );
      final other = BoundedWebSocketOutput(
        write: (v) async {
          healthy.add(v);
        },
        onFailure: fail,
      );
      for (var i = 0; i < 100000; i++) {
        q.enqueue([i % 256, 0, 0, 0], audio: true);
        expect(q.snapshot['queuedPayloadBytes'], lessThanOrEqualTo(16));
        expect(q.snapshot['queuedMessages'], lessThanOrEqualTo(4));
      }
      other.enqueue('state');
      t.flushMicrotasks();
      expect(healthy, ['state']);
      expect(writes, hasLength(1));
      expect(q.droppedAudioBlocks, 99996);
      blocked.complete();
      t.flushMicrotasks();
      t.elapse(Duration.zero);
      expect((writes[1] as List<int>)[0], 99997 % 256);
      q.close();
      other.close();
    });
  });
  test(
    'active bytes count; audio eviction preserves control FIFO and buffer copy',
    () {
      fakeAsync((t) {
        final blocked = Completer<void>(), writes = <Object>[];
        final q = BoundedWebSocketOutput(
          write: (v) {
            writes.add(v);
            return writes.length == 1 ? blocked.future : Future.value();
          },
          onFailure: fail,
          maxBytes: 12,
          maxMessages: 4,
        );
        q.enqueue('first');
        q.enqueue([1, 2, 3], audio: true);
        final buffer = [9, 8];
        q.enqueue(buffer);
        buffer[0] = 0;
        q.enqueue('last');
        expect(q.droppedAudioBlocks, 1);
        expect(q.snapshot['queuedPayloadBytes'], 11);
        blocked.complete();
        t.flushMicrotasks();
        t.elapse(Duration.zero);
        expect(writes, [
          'first',
          [9, 8],
          'last',
        ]);
        q.close();
      });
    },
  );
  test('UTF8 byte budget; large audio drops, large control aborts once', () {
    final reasons = <String>[];
    final q = BoundedWebSocketOutput(
      write: (_) => Completer<void>().future,
      onFailure: reasons.add,
      maxBytes: 5,
    );
    expect(q.enqueue([0, 1, 2, 3, 4, 5], audio: true), false);
    expect(q.closed, false);
    expect(q.droppedAudioBlocks, 1);
    expect(q.enqueue('中文'), false);
    expect(reasons, ['output_message_too_large']);
    q.enqueue('again');
    expect(reasons, hasLength(1));
  });
  test('audio cannot evict active; control overflow aborts', () {
    final reasons = <String>[];
    final q = BoundedWebSocketOutput(
      write: (_) => Completer<void>().future,
      onFailure: reasons.add,
      maxBytes: 4,
    );
    q.enqueue([1, 2, 3, 4], audio: true);
    expect(q.enqueue([5], audio: true), false);
    expect(q.enqueue('x'), false);
    expect(reasons, ['output_queue_overflow']);
    expect(q.snapshot['queuedPayloadBytes'], 0);
  });
  test('pending audio expires after 500ms while controls survive', () {
    fakeAsync((t) {
      final blocked = Completer<void>(), writes = <Object>[];
      final q = BoundedWebSocketOutput(
        write: (v) {
          writes.add(v);
          return writes.length == 1 ? blocked.future : Future.value();
        },
        onFailure: fail,
        clock: () => t.elapsed,
      );
      q.enqueue('active');
      q.enqueue([1], audio: true);
      q.enqueue('state');
      t.elapse(const Duration(milliseconds: 500));
      blocked.complete();
      t.flushMicrotasks();
      t.elapse(Duration.zero);
      expect(writes, ['active', 'state']);
      expect(q.droppedAudioBlocks, 1);
      q.close();
    });
  });
  test('timeout once; late completion cannot restart writes', () {
    fakeAsync((t) {
      final blocked = Completer<void>(), reasons = <String>[];
      var calls = 0;
      final q = BoundedWebSocketOutput(
        write: (_) {
          calls++;
          return blocked.future;
        },
        onFailure: reasons.add,
      );
      q.enqueue('a');
      q.enqueue('b');
      t.elapse(const Duration(seconds: 3));
      expect(reasons, ['output_write_timeout']);
      blocked.complete();
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 5));
      expect(calls, 1);
      expect(reasons, hasLength(1));
      expect(q.snapshot['queuedMessages'], 0);
    });
  });
  for (final sync in [true, false]) {
    test('write error synchronous=$sync handled once', () {
      fakeAsync((t) {
        final reasons = <String>[];
        final q = BoundedWebSocketOutput(
          write: (_) {
            if (sync) throw StateError('failed');
            return Future.error(StateError('failed'));
          },
          onFailure: reasons.add,
        );
        q.enqueue('a');
        t.flushMicrotasks();
        t.elapse(const Duration(seconds: 4));
        expect(reasons, ['output_write_failed']);
        expect(q.closed, true);
      });
    });
  }
  test('revoke cancels timer and ignores late error', () {
    fakeAsync((t) {
      final blocked = Completer<void>(), reasons = <String>[];
      final q = BoundedWebSocketOutput(
        write: (_) => blocked.future,
        onFailure: reasons.add,
      );
      q.enqueue('a');
      q.close();
      blocked.completeError(StateError('late'));
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 4));
      expect(reasons, isEmpty);
      expect(q.enqueue('b'), false);
    });
  });
}
