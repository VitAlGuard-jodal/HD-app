import { distance, ROUTE_ENDPOINT_GAP_METERS } from "./route_contract.ts";
import type { Point } from "./route_contract.ts";

export const REJOIN_FORWARD_METERS = 120;
// Wire endGapMeters remains the real distance to the requested point. This is
// only a coarse bound; the trace and direction checks below are mandatory.
export const REJOIN_POINT_GAP_METERS = REJOIN_FORWARD_METERS + ROUTE_ENDPOINT_GAP_METERS;
export interface TraceRejoinEndpoint { kind: "traceRejoin"; points: Point[]; minimum: number; anchor: Point }
interface Projection { point: Point; along: number; gap: number; bearing: number }

function bearing(a: Point, b: Point): number {
  const r = Math.PI / 180;
  return (Math.atan2(Math.sin((b.lng - a.lng) * r) * Math.cos(b.lat * r),
    Math.cos(a.lat * r) * Math.sin(b.lat * r) - Math.sin(a.lat * r) * Math.cos(b.lat * r)
      * Math.cos((b.lng - a.lng) * r)) / r + 360) % 360;
}

// Keep the projection, ambiguity and heading rules in sync with the app's
// projectTraceRejoinEndpoint. Looking at the whole branch preserves ambiguity.
export function projectTraceRejoinEndpoint(point: Point, route: Point[], target: TraceRejoinEndpoint): Projection | null {
  if (route.length < 2) return null;
  const end = route.at(-1)!;
  const before = route.slice(0, -1).reverse().find((p) => distance(p, end) >= 2.999999);
  if (!before) return null;
  const direction = bearing(before, end);
  const candidates: Projection[] = [];
  let along = 0;
  for (let i = 0; i + 1 < target.points.length; i++) {
    const a = target.points[i], b = target.points[i + 1], length = distance(a, b);
    if (length < .01) continue;
    const scale = Math.cos(point.lat * Math.PI / 180);
    const x = (b.lng - a.lng) * scale, y = b.lat - a.lat;
    const f = Math.max(0, Math.min(1, ((point.lng - a.lng) * scale * x + (point.lat - a.lat) * y) / (x * x + y * y)));
    const projected = { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f };
    candidates.push({ point: projected, along: along + length * f, gap: distance(point, projected), bearing: bearing(a, b) });
    along += length;
  }
  candidates.sort((a, b) => a.gap - b.gap);
  const best = candidates[0];
  const angle = best ? Math.abs((direction - best.bearing + 540) % 360 - 180) : 180;
  // Keep ordinary T-junction approaches inside the original point allowance.
  // Extending that point allowance requires alignment; opposite arrivals are
  // rejected in both cases.
  const wrongDirection = distance(point, target.anchor) <= 25.000001
    ? angle >= 119.999999 : angle > 60.000001;
  if (!best || best.gap > 25.000001 || best.along < target.minimum - .000001
    || best.along > target.minimum + REJOIN_FORWARD_METERS + .000001
    || wrongDirection
    || candidates.some((p) => Math.abs(p.along - best.along) > 40 && p.gap <= 25 && Math.abs(p.gap - best.gap) <= 5)) return null;
  return best;
}
