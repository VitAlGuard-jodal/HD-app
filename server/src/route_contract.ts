export const ROUTE_BODY_LIMIT = 16 * 1024;
export const ROUTE_RESPONSE_LIMIT = 2 * 1024 * 1024;
export const ROUTE_POINT_LIMIT = 50_000;
export const ROUTE_TIMEOUT_MS = 5_000;
export const ROUTE_INTERVAL_MS = 30_000;
export const ROUTE_INPUT_TTL_MS = 120_000;
export const ROUTE_LOCATION_AGE_MS = 10_000;
export const ROUTE_ENDPOINT_GAP_METERS = 25;
export const ROUTE_CONSENT_VERSION = "4";

export interface Point { lat: number; lng: number }
export interface SampleRef { stream: string; seq: number }
export type RouteAnchor = { kind: "sample"; ref: SampleRef }
  | { kind: "segment"; startRef: SampleRef; endRef: SampleRef; fraction: number };
export interface FollowRouteRequest {
  schemaVersion: 1;
  followRequestId: string;
  guidanceGeneration: number;
  calculationId: string;
  requestId: string;
  mode: "A" | "B";
  originRef: SampleRef;
  anchor: RouteAnchor;
}
export interface ProviderRoute {
  result: "route" | "atAnchor";
  provider: "naver";
  routeOption: "traoptimal";
  points: Point[];
  meters: number;
  seconds: number;
  actualStart: Point | null;
  actualEnd: Point | null;
  startGapMeters: number | null;
  endGapMeters: number | null;
}
export interface FollowRouteResponse extends FollowRouteRequest, ProviderRoute {
  requestedOrigin: Point;
  requestedAnchor: Point;
  serverNowMs: number;
}

const errorStatuses = {
  INVALID_REQUEST: 400, REQUEST_TOO_LARGE: 413, UNAUTHENTICATED: 401,
  NOT_ROOM_MEMBER: 403, NOT_ACTIVE_SENDER: 403,
  CONSENT_REQUIRED_SELF: 403, CONSENT_REQUIRED_TARGET: 403,
  FOLLOW_NOT_ACTIVE: 409, LOCATION_NOT_READY: 409, REFERENCE_EXPIRED: 409,
  TRACE_DISCONTINUITY: 409, CONTEXT_MISMATCH: 409, ROUTE_IN_PROGRESS: 409,
  NO_ROUTE: 422, ENDPOINT_MISMATCH: 422, RATE_LIMITED: 429, PROVIDER_RATE_LIMITED: 429,
  ROUTING_DISABLED: 503, PROVIDER_AUTH_FAILED: 502, INVALID_PROVIDER_RESPONSE: 502,
  ROUTE_TOO_LARGE: 502, PROVIDER_UNAVAILABLE: 502, ROUTE_TIMEOUT: 504,
} as const;
export type RouteErrorCode = keyof typeof errorStatuses;
const retryableCodes = new Set<RouteErrorCode>([
  "RATE_LIMITED", "PROVIDER_RATE_LIMITED", "PROVIDER_UNAVAILABLE", "ROUTE_TIMEOUT",
]);

export class RouteError extends Error {
  readonly code: RouteErrorCode;
  readonly status: number;
  readonly retryable: boolean;
  readonly retryAfterMs: number | null;
  inputExpiresAtMs?: number;

  constructor(code: RouteErrorCode, retryAfterMs: number | null = null, retryable = retryableCodes.has(code)) {
    // Never retain a provider exception, URL, response body or credentials.
    super(code);
    this.code = code;
    this.status = errorStatuses[code];
    this.retryable = retryable;
    this.retryAfterMs = retryAfterMs;
  }

  body(request?: FollowRouteRequest) {
    return {
      error: { code: this.code, retryable: this.retryable, retryAfterMs: this.retryAfterMs },
      ...(request ? {
        followRequestId: request.followRequestId, guidanceGeneration: request.guidanceGeneration,
        calculationId: request.calculationId, requestId: request.requestId,
      } : {}),
      ...(this.inputExpiresAtMs === undefined ? {} : { inputAccepted: true, inputExpiresAtMs: this.inputExpiresAtMs }),
    };
  }
}

export function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function keys(value: Record<string, unknown>, expected: string[]): boolean {
  return Object.keys(value).length === expected.length && expected.every((key) => Object.hasOwn(value, key));
}
function integer(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}
function identifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
}
function ref(value: unknown): value is SampleRef {
  return record(value) && keys(value, ["stream", "seq"])
    && typeof value.stream === "string" && /^[0-9a-f]{16}$/.test(value.stream) && integer(value.seq);
}

export function parseRouteRequest(value: unknown): FollowRouteRequest {
  if (!record(value) || !keys(value, ["schemaVersion", "followRequestId", "guidanceGeneration", "calculationId", "requestId", "mode", "originRef", "anchor"])
    || value.schemaVersion !== 1 || !identifier(value.followRequestId) || !integer(value.guidanceGeneration)
    || !identifier(value.calculationId) || !identifier(value.requestId) || !ref(value.originRef)
    || !record(value.anchor)) throw new RouteError("INVALID_REQUEST");
  const anchor = value.anchor;
  const base = {
    schemaVersion: 1 as const, followRequestId: value.followRequestId, guidanceGeneration: value.guidanceGeneration,
    calculationId: value.calculationId, requestId: value.requestId, originRef: { stream: value.originRef.stream, seq: value.originRef.seq },
  };
  if (value.mode === "A" && keys(anchor, ["kind", "ref"]) && anchor.kind === "sample" && ref(anchor.ref)) {
    return { ...base, mode: "A", anchor: { kind: "sample", ref: { stream: anchor.ref.stream, seq: anchor.ref.seq } } };
  }
  if (value.mode === "B" && keys(anchor, ["kind", "startRef", "endRef", "fraction"])
    && anchor.kind === "segment" && ref(anchor.startRef) && ref(anchor.endRef)
    && finite(anchor.fraction) && anchor.fraction >= 0 && anchor.fraction <= 1) {
    return { ...base, mode: "B", anchor: {
      kind: "segment", startRef: { stream: anchor.startRef.stream, seq: anchor.startRef.seq },
      endRef: { stream: anchor.endRef.stream, seq: anchor.endRef.seq }, fraction: anchor.fraction,
    } };
  }
  throw new RouteError("INVALID_REQUEST");
}

export function sameRef(a: SampleRef, b: SampleRef): boolean { return a.stream === b.stream && a.seq === b.seq; }
export function point(value: unknown): value is Point {
  return record(value) && finite(value.lat) && value.lat >= -90 && value.lat <= 90
    && finite(value.lng) && value.lng >= -180 && value.lng <= 180;
}
export function distance(a: Point, b: Point): number {
  const rad = Math.PI / 180;
  const h = Math.sin((b.lat - a.lat) * rad / 2) ** 2
    + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin((b.lng - a.lng) * rad / 2) ** 2;
  return 6_371_000 * 2 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}
