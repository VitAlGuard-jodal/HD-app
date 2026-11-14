import '../net/follow_route.dart';
import '../net/models.dart';
import 'follow_route_geometry.dart';

// Keep in sync with server/src/location_quality.ts. Moving/trace evidence
// keeps its existing 10 s freshness rule for every sample.
const meetingStopLocationAgeMs = 10000;
const meetingStopMinSamples = 3;
const meetingStopMinSpanMs = 2000;
const meetingStopMaxSpanMs = 15000;
const meetingStopMaxDisplacementMeters = 3.0;
const meetingStopSpeedLimitMps = 2.0;
const meetingEvidenceSampleLimit = 64;

/// [receivedAtMs] contains server receipts when available. For own fixes the
/// controller records successful upload acknowledgements on the measurement
/// clock; the wire format does not return the server's receipt timestamp.
/// Arrival/departure displays always use authoritative server runtime.
bool meetingStopped(
  List<LocationFix> samples, {
  required double latestAgeMs,
  required List<num> receivedAtMs,
}) {
  if (samples.length < meetingStopMinSamples ||
      receivedAtMs.length != samples.length ||
      !latestAgeMs.isFinite ||
      latestAgeMs < 0 ||
      latestAgeMs > meetingStopLocationAgeMs ||
      latestAgeMs < receivedAtMs.last - samples.last.at) {
    return false;
  }
  var start = samples.length - 1;
  while (start > 0 &&
      (samples.length - start < meetingStopMinSamples ||
          samples.last.at - samples[start].at < meetingStopMinSpanMs ||
          receivedAtMs.last - receivedAtMs[start] < meetingStopMinSpanMs)) {
    if (!traceContinuous(samples[start - 1], samples[start])) break;
    start--;
  }
  final measuredSpan = samples.last.at - samples[start].at;
  final receivedSpan = receivedAtMs.last - receivedAtMs[start];
  if (samples.length - start < meetingStopMinSamples ||
      measuredSpan < meetingStopMinSpanMs ||
      measuredSpan > meetingStopMaxSpanMs ||
      receivedSpan < meetingStopMinSpanMs ||
      receivedSpan > meetingStopMaxSpanMs) {
    return false;
  }
  final origin = RoutePoint.fromFix(samples[start]);
  for (var n = start; n < samples.length; n++) {
    final fix = samples[n], received = receivedAtMs[n];
    if (!routeQuality(fix) ||
        !fix.at.isFinite ||
        !received.isFinite ||
        received < fix.at ||
        received - fix.at > meetingStopLocationAgeMs ||
        n > start &&
            (!traceContinuous(samples[n - 1], fix) ||
                received < receivedAtMs[n - 1]) ||
        fix.speed != null &&
            (!fix.speed!.isFinite ||
                fix.speed! < 0 ||
                fix.speed! >= meetingStopSpeedLimitMps) ||
        fix.speed == null &&
            routeDistance(origin, RoutePoint.fromFix(fix)) >=
                meetingStopMaxDisplacementMeters) {
      return false;
    }
  }
  return true;
}
