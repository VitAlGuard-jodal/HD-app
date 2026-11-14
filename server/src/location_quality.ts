import type { LocationFix } from "./locations.ts";
import { distance, finite, ROUTE_LOCATION_AGE_MS } from "./route_contract.ts";

// Keep the stop rule in sync with app/lib/location/meeting_stop_evidence.dart.
export const STOP_EVIDENCE_MIN_SAMPLES = 3;
export const STOP_EVIDENCE_MIN_SPAN_MS = 2_000;
// Three parked uploads span 10 s; allow 5 s of cadence/receipt jitter.
export const STOP_EVIDENCE_MAX_SPAN_MS = 15_000;
export const STOP_EVIDENCE_RETENTION_MS = STOP_EVIDENCE_MAX_SPAN_MS + ROUTE_LOCATION_AGE_MS;
export const STOP_MAX_DISPLACEMENT_METERS = 3;
export const STOP_SPEED_LIMIT_MPS = 2;

export function accuracyAllowance(fix: LocationFix): number | undefined {
  // r6: this is an assumed jump allowance, not measured accuracy or provenance.
  if (fix.acc === undefined) return fix.src === "vehicle" ? 25 : undefined;
  return finite(fix.acc) && fix.acc >= 0 && fix.acc <= 25 ? fix.acc : undefined;
}
export function quality(fix: LocationFix): boolean {
  return accuracyAllowance(fix) !== undefined && fix.at <= fix.receivedAt
    && fix.receivedAt - fix.at <= ROUTE_LOCATION_AGE_MS;
}
export function fresh(fix: LocationFix | undefined, now: number): fix is LocationFix {
  return !!fix && quality(fix) && now >= fix.receivedAt && now - fix.receivedAt <= ROUTE_LOCATION_AGE_MS
    && now >= fix.at && now - fix.at <= ROUTE_LOCATION_AGE_MS;
}
export function continuous(a: LocationFix, b: LocationFix): boolean {
  const elapsed = b.at - a.at;
  return a.stream === b.stream && b.seq === a.seq + 1 && quality(a) && quality(b)
    && elapsed > 0 && elapsed <= ROUTE_LOCATION_AGE_MS && b.receivedAt >= a.receivedAt
    && distance(a, b) <= 70 * elapsed / 1000 + accuracyAllowance(a)! + accuracyAllowance(b)!;
}
export function context(samples: LocationFix[], now: number): boolean {
  return samples.length >= 3 && samples.at(-1)!.at - samples[0].at >= 2000
    && samples.at(-1)!.receivedAt - samples[0].receivedAt >= 2000
    && samples.every((s, i) => fresh(s, now) && (i === 0 || continuous(samples[i - 1], s)));
}
export function stopped(samples: LocationFix[], now: number): boolean {
  if (samples.length < STOP_EVIDENCE_MIN_SAMPLES || !fresh(samples.at(-1), now)) return false;
  const measuredSpan = samples.at(-1)!.at - samples[0].at;
  const receivedSpan = samples.at(-1)!.receivedAt - samples[0].receivedAt;
  return measuredSpan >= STOP_EVIDENCE_MIN_SPAN_MS && measuredSpan <= STOP_EVIDENCE_MAX_SPAN_MS
    && receivedSpan >= STOP_EVIDENCE_MIN_SPAN_MS && receivedSpan <= STOP_EVIDENCE_MAX_SPAN_MS
    && samples.every((s, i) => quality(s) && (i === 0 || continuous(samples[i - 1], s))
      && (s.speed === undefined || finite(s.speed) && s.speed >= 0 && s.speed < STOP_SPEED_LIMIT_MPS)
      && distance(samples[0], s) < STOP_MAX_DISPLACEMENT_METERS);
}
