import { distance, RouteError, ROUTE_ENDPOINT_GAP_METERS } from "./route_contract.ts";
import type { Point } from "./route_contract.ts";

export const REJOIN_FORWARD_METERS = 120;
// Keep in sync with traceRejoinBackwardMeters in the app geometry helper.
export const REJOIN_BACKWARD_METERS = 10;
// Wire endGapMeters remains the real distance to the requested point. This is
// only a coarse bound; the trace and direction checks below are mandatory.
export const REJOIN_POINT_GAP_METERS = REJOIN_FORWARD_METERS + ROUTE_ENDPOINT_GAP_METERS;
export interface TraceRejoinEndpoint { kind: "traceRejoin"; points: Point[]; minimum: number; anchor: Point }
interface Projection { point: Point; along: number; gap: number; bearing: number }
type RejoinCondition = "missing_point" | "arrival_direction_missing" | "trace_projection_missing"
  | "trace_distance" | "before_minimum" | "after_maximum" | "arrival_direction" | "ambiguous";
type RejoinPoint = "actualEnd" | "pathEnd" | "summaryEnd";
interface RejoinMetrics {
  traceDistanceMeters: number | null;
  forwardMeters: number | null;
  directionDifferenceDegrees: number | null;
  targetDistanceMeters: number | null;
  ambiguousSegments: number;
  tracePointCount: number;
  traceLengthMeters: number;
}
interface TraceRejoinRejectionDiagnostic extends RejoinMetrics { point: RejoinPoint; condition: RejoinCondition }
export interface RejoinGapDiagnostic {
  point: "summaryStart" | "summaryEnd" | "actualStart" | "actualEnd" | "zeroRoutePoint";
  condition: "summary_start_gap" | "summary_end_gap" | "start_gap" | "end_gap" | "zero_route_point";
  distanceMeters: number;
  limitMeters: number;
  reference?: "origin" | "anchor";
}
export type RejoinRejectionDiagnostic = TraceRejoinRejectionDiagnostic | RejoinGapDiagnostic;

// Only safe scalar diagnostics travel with this existing error code. The
// inherited body() keeps them out of the HTTP response contract.
export class RejoinEndpointError extends RouteError {
  readonly diagnostic: RejoinRejectionDiagnostic;
  constructor(diagnostic: RejoinRejectionDiagnostic) {
    super("ENDPOINT_MISMATCH"); this.diagnostic = diagnostic;
  }
}

function bearing(a: Point, b: Point): number {
  const r = Math.PI / 180;
  return (Math.atan2(Math.sin((b.lng - a.lng) * r) * Math.cos(b.lat * r),
    Math.cos(a.lat * r) * Math.sin(b.lat * r) - Math.sin(a.lat * r) * Math.cos(b.lat * r)
      * Math.cos((b.lng - a.lng) * r)) / r + 360) % 360;
}

// Keep the projection, ambiguity and heading rules in sync with the app's
// projectTraceRejoinEndpoint. Looking at the whole branch preserves ambiguity.
export function projectTraceRejoinEndpoint(point: Point, route: Point[], target: TraceRejoinEndpoint): Projection | null {
  return inspectTraceRejoinEndpoint(point, route, target).projection;
}

export function validateTraceRejoinEndpoint(point: Point | null | undefined, route: Point[], target: TraceRejoinEndpoint,
  pointName: RejoinPoint): void {
  const result = inspectTraceRejoinEndpoint(point, route, target);
  if (result.condition) throw new RejoinEndpointError({ ...result.metrics, point: pointName, condition: result.condition });
}

function inspectTraceRejoinEndpoint(point: Point | null | undefined, route: Point[], target: TraceRejoinEndpoint): {
  projection: Projection | null; condition: RejoinCondition | null; metrics: RejoinMetrics;
} {
  const end = route.at(-1)!;
  const before = route.length < 2 ? undefined : route.slice(0, -1).reverse().find((p) => distance(p, end) >= 2.999999);
  const direction = before ? bearing(before, end) : null;
  const candidates: Projection[] = [];
  let along = 0;
  for (let i = 0; i + 1 < target.points.length; i++) {
    const a = target.points[i], b = target.points[i + 1], length = distance(a, b);
    if (length < .01) continue;
    if (point) {
      const scale = Math.cos(point.lat * Math.PI / 180);
      const x = (b.lng - a.lng) * scale, y = b.lat - a.lat;
      const f = Math.max(0, Math.min(1, ((point.lng - a.lng) * scale * x + (point.lat - a.lat) * y) / (x * x + y * y)));
      const projected = { lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f };
      candidates.push({ point: projected, along: along + length * f, gap: distance(point, projected), bearing: bearing(a, b) });
    }
    along += length;
  }
  candidates.sort((a, b) => a.gap - b.gap);
  const best = candidates[0];
  const angle = best && direction !== null ? Math.abs((direction - best.bearing + 540) % 360 - 180) : null;
  const targetDistance = point ? distance(point, target.anchor) : null;
  // The near-target radius permits only a bounded backward projection, not a
  // different visit to the road. Keep the same lower bound in the app.
  const nearTarget = targetDistance !== null && targetDistance <= 25.000001;
  const backwardAllowance = nearTarget ? REJOIN_BACKWARD_METERS : 0;
  const ambiguousSegments = best ? candidates.filter((p) => Math.abs(p.along - best.along) > 40
    && p.gap <= 25 && Math.abs(p.gap - best.gap) <= 5).length : 0;
  // Keep ordinary T-junction approaches inside the original point allowance.
  // Extending that point allowance requires alignment; opposite arrivals are
  // rejected in both cases.
  const wrongDirection = angle !== null && (nearTarget
    ? angle >= 119.999999 : angle > 60.000001);
  const condition: RejoinCondition | null = !point ? "missing_point"
    : !before ? "arrival_direction_missing"
    : !best ? "trace_projection_missing"
    : best.gap > 25.000001 ? "trace_distance"
    : best.along < target.minimum - backwardAllowance - .000001 ? "before_minimum"
    : best.along > target.minimum + REJOIN_FORWARD_METERS + .000001 ? "after_maximum"
    : wrongDirection ? "arrival_direction"
    : ambiguousSegments > 0 ? "ambiguous" : null;
  return { projection: condition ? null : best, condition, metrics: {
    traceDistanceMeters: best?.gap ?? null, forwardMeters: best ? best.along - target.minimum : null,
    directionDifferenceDegrees: angle, targetDistanceMeters: targetDistance, ambiguousSegments,
    tracePointCount: target.points.length, traceLengthMeters: along,
  } };
}
