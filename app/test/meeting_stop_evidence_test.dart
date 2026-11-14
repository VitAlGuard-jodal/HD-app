import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/meeting_stop_evidence.dart';
import 'package:unavo/net/models.dart';
import 'support/follow_route_fakes.dart';

List<LocationFix> fixes({
  List<int> times = const [0, 5000, 10000],
  List<int> sequences = const [0, 1, 2],
  List<double> positions = const [0, 0, 0],
  double? speed = 0,
  double? acc = 2,
  String? src,
  String stream = '0123456789abcdef',
}) => [
  for (var n = 0; n < times.length; n++)
    testFix(
      positions[n],
      seq: sequences[n],
      at: routeEpoch + times[n],
      speed: speed,
      acc: acc,
      src: src,
      stream: n == times.length - 1 ? stream : '0123456789abcdef',
    ),
];

bool stopped(
  List<LocationFix> samples, {
  double age = 200,
  List<num>? receipts,
}) => meetingStopped(
  samples,
  latestAgeMs: age,
  receivedAtMs: receipts ?? samples.map((s) => s.at + 200).toList(),
);

void main() {
  test(
    'r11 B3 known low speed tolerates phone jitter within location quality',
    () {
      for (final speed in [0.0, 1.5]) {
        expect(
          stopped(fixes(positions: [0, 4, -1], speed: speed, acc: 5)),
          isTrue,
        );
      }
      expect(
        stopped(fixes(positions: [0, 4, -1], speed: null, acc: 5)),
        isFalse,
      );
      expect(stopped(fixes(positions: [0, 4, -1], speed: 2, acc: 5)), isFalse);
    },
  );
  test('r10 parked evidence survives the whole 5-second upload interval', () {
    final samples = fixes();
    for (final age in [200.0, 5199.0, 10000.0]) {
      expect(stopped(samples, age: age), isTrue);
    }
    for (final age in [-1.0, 199.0, 10001.0, double.nan, double.infinity]) {
      expect(stopped(samples, age: age), isFalse);
    }
  });

  test(
    'r10 stop window allows 15 seconds and rejects one millisecond more',
    () {
      expect(stopped(fixes(times: [0, 7500, 15000])), isTrue);
      expect(stopped(fixes(times: [0, 7500, 15001])), isFalse);
    },
  );

  for (final entry in <String, List<LocationFix>>{
    'missing sample': fixes().sublist(1),
    'duplicate sequence': fixes(sequences: [0, 0, 2]),
    'sequence gap': fixes(sequences: [0, 1, 3]),
    'different stream': fixes(stream: '1111111111111111'),
    'reversed measurement': fixes(times: [0, 0, 10000]),
    'gap over 10 seconds': fixes(times: [0, 10001, 12000]),
    'poor accuracy': fixes(acc: 26),
    'phone without accuracy': fixes(acc: null),
    'speed at 2 m/s': fixes(speed: 2),
    'negative speed': fixes(speed: -1),
    'non-finite speed': fixes(speed: double.nan),
    'displacement with unknown speed': fixes(
      speed: null,
      positions: [0, 0, 3.1],
    ),
    'unknown-speed excursion then return': fixes(
      speed: null,
      positions: [0, 3.1, 0],
    ),
  }.entries) {
    test('r10 stop evidence rejects ${entry.key}', () {
      expect(stopped(entry.value), isFalse);
    });
  }

  test(
    'r10 receipt clocks must be ordered, timely and span 2 to 15 seconds',
    () {
      final samples = fixes();
      for (final offsets in [
        [200, 5200, 9999],
        [10001, 10200, 10400],
        [9000, 9500, 10200],
        [6000, 5200, 10200],
        [200, 5200, 15201],
      ]) {
        final receipts = offsets.map((n) => routeEpoch + n).toList();
        expect(stopped(samples, age: 6000, receipts: receipts), isFalse);
      }
    },
  );

  test(
    'r10 unknown speed and vehicle accuracy fallback still need stationary fixes',
    () {
      expect(stopped(fixes(speed: null, acc: null, src: 'vehicle')), isTrue);
      expect(
        stopped(
          fixes(speed: null, acc: null, src: 'vehicle', positions: [0, 3.1, 0]),
        ),
        isFalse,
      );
    },
  );
}
