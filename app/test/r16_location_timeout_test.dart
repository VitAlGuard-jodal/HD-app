import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/net/api_client.dart';

import 'support/location_fakes.dart';

void main() {
  test(
    'R16.2 stalled upload releases the latest sample at five seconds and ignores a late acknowledgement',
    () {
      fakeAsync((clock) {
        final http = FakeLocationHttp();
        final source = FakeLocationSource();
        final api = ApiClient(
          tokenStore: LocationTestTokenStore(),
          clientFactory: http.client,
        );
        final share = LocationShare(
          api: api,
          source: source,
          roomCode: () => 'ROOM',
          selfHandle: () => 'self',
          now: clock.getClock(DateTime.utc(2026)).now,
          monotonicNow: () => clock.elapsed.inMilliseconds,
        );
        final gate = Completer<void>();
        http.sendGate = gate.future;
        unawaited(share.start(token: Object(), stillValid: () => true));
        clock.flushMicrotasks();
        void sample() {
          source.add(
            LocationSample(
              lat: 37,
              lng: 127,
              speed: 2,
              at: DateTime.utc(2026).add(clock.elapsed),
            ),
          );
          clock.flushMicrotasks();
        }

        sample();
        for (var n = 0; n < 4; n++) {
          clock.elapse(const Duration(seconds: 1));
          sample();
        }
        expect(http.posts, hasLength(1));
        http.sendGate = null;
        clock.elapse(const Duration(seconds: 1));
        expect(http.posts, hasLength(2));
        expect(http.posts.map((p) => p.body['seq']), [0, 1]);
        expect(share.lastSent!.seq, 1);
        expect(share.lastSentAgeMs, 1000);
        gate.complete();
        clock.flushMicrotasks();
        expect(share.lastSent!.seq, 1);
        expect(http.posts, hasLength(2));
        unawaited(share.stop(notifyServer: false));
        clock.flushMicrotasks();
        share.dispose();
        api.close();
        unawaited(source.close());
        unawaited(http.close());
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );
}
