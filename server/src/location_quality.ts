import type { LocationFix } from "./locations.ts";
import { distance, finite, ROUTE_LOCATION_AGE_MS } from "./route_contract.ts";

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
  if (!context(samples, now)) return false;
  return samples.every((s, i) => s.speed !== undefined ? s.speed < 2
    : i === 0 || distance(samples[i - 1], s) < 2 * (s.at - samples[i - 1].at) / 1000);
}
