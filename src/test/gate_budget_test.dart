import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprsis/gate_budget.dart';

void main() {
  test(
    'gate rejects duplicates, overload and invalid lines with bounded memory',
    () {
      var now = DateTime(2026);
      final gate = GateBudget(clock: () => now, capacity: 2, limitPerMinute: 3);
      expect(gate.accept('CALL>APRS:one'), true);
      expect(gate.accept('CALL>APRS:one'), false);
      expect(gate.accept('CALL>APRS:two'), true);
      expect(gate.accept('CALL>APRS:three'), true);
      expect(gate.metrics['dedupEntries'], 2);
      expect(gate.accept('CALL>APRS:four'), false);
      expect(gate.accept('CALL>APRS:bad\nline'), false);
      expect(gate.accept('x' * 513), false);
      now = now.add(const Duration(minutes: 1));
      expect(gate.accept('CALL>APRS:one'), true);
      expect(gate.metrics['duplicateDrops'], 1);
      expect(gate.metrics['rateDrops'], 1);
      expect(gate.metrics['invalidDrops'], 2);
    },
  );
}
