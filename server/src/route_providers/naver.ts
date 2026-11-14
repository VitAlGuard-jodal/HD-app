import { distance, finite, point, record, RouteError, ROUTE_ENDPOINT_GAP_METERS,
  ROUTE_INTERVAL_MS, ROUTE_POINT_LIMIT, ROUTE_RESPONSE_LIMIT } from "../route_contract.ts";
import type { Point, ProviderRoute } from "../route_contract.ts";
import { RejoinEndpointError, validateTraceRejoinEndpoint, REJOIN_POINT_GAP_METERS } from "../trace_rejoin.ts";
import type { RejoinGapDiagnostic, TraceRejoinEndpoint } from "../trace_rejoin.ts";

export interface NaverConfig { provider: "naver"; keyId: string; key: string }
export type RouteConfig = NaverConfig | { provider: "disabled" };
export type RouteEndpoint = "reference" | "destination" | TraceRejoinEndpoint;
// D keeps its road-end allowance. Trace rejoining uses a verified forward
// trace segment; J/P0 and all origins keep the 25 m point rule.
export const DESTINATION_ENDPOINT_GAP_METERS = 100;
export type RouteProvider = (origin: Point, destination: Point, signal: AbortSignal, config: NaverConfig,
  endpoint?: RouteEndpoint) => Promise<ProviderRoute>;
export interface RouteTiming { quality: "guide" | "rough"; knots: { meters: number; seconds: number }[] }
export interface TimedProviderRoute extends ProviderRoute { timing: RouteTiming }

export function routeConfig(env: NodeJS.ProcessEnv = process.env): RouteConfig {
  const keyId = env.NAVER_DIRECTIONS_KEY_ID;
  const key = env.NAVER_DIRECTIONS_KEY;
  // Activation is an operator action after the documented rollout conditions.
  if (env.ROUTE_PROVIDER !== "naver" || !keyId || !key || !/^[\x21-\x7e]+$/.test(keyId) || !/^[\x21-\x7e]+$/.test(key)) {
    return { provider: "disabled" };
  }
  return { provider: "naver", keyId, key };
}

function invalid(): never { throw new RouteError("INVALID_PROVIDER_RESPONSE"); }
function coordinate(value: unknown): Point {
  if (!Array.isArray(value) || value.length !== 2) invalid();
  const result = { lat: value[1], lng: value[0] };
  if (!point(result)) invalid();
  return result;
}
export function atAnchor(origin: Point, destination: Point): ProviderRoute {
  if (distance(origin, destination) > ROUTE_ENDPOINT_GAP_METERS) throw new RouteError("NO_ROUTE");
  return { result: "atAnchor", provider: "naver", routeOption: "traoptimal", points: [], meters: 0, seconds: 0,
    actualStart: null, actualEnd: null, startGapMeters: null, endGapMeters: null };
}

function endpointMismatch(endpoint: RouteEndpoint, diagnostic: RejoinGapDiagnostic): never {
  if (typeof endpoint === "object") throw new RejoinEndpointError(diagnostic);
  throw new RouteError("ENDPOINT_MISMATCH");
}

// Fixtures use invented coordinates, never saved product responses.
export function parseNaverRoute(value: unknown, origin: Point, destination: Point, endpoint: RouteEndpoint = "reference"): ProviderRoute {
  const endGapLimit = typeof endpoint === "object" ? REJOIN_POINT_GAP_METERS
    : endpoint === "destination" ? DESTINATION_ENDPOINT_GAP_METERS : ROUTE_ENDPOINT_GAP_METERS;
  if (!record(value) || !Number.isInteger(value.code)) invalid();
  if (value.code === 1) return atAnchor(origin, destination);
  if ([2, 3, 4, 5].includes(value.code as number)) throw new RouteError("NO_ROUTE");
  if (value.code !== 0 || !record(value.route) || !Array.isArray(value.route.traoptimal)
    || value.route.traoptimal.length === 0) invalid();
  const route = value.route.traoptimal[0];
  if (!record(route) || !record(route.summary) || !Array.isArray(route.path)) invalid();
  if (route.path.length > ROUTE_POINT_LIMIT) throw new RouteError("ROUTE_TOO_LARGE");
  const summary = route.summary;
  if (!finite(summary.distance) || summary.distance < 0 || summary.distance > Number.MAX_SAFE_INTEGER
    || !finite(summary.duration) || summary.duration < 0 || summary.duration > Number.MAX_SAFE_INTEGER
    || !record(summary.start) || !record(summary.goal)) invalid();
  const summaryStart = coordinate(summary.start.location);
  const summaryEnd = coordinate(summary.goal.location);
  const summaryStartGap = distance(origin, summaryStart);
  if (summaryStartGap > ROUTE_ENDPOINT_GAP_METERS) endpointMismatch(endpoint, {
    point: "summaryStart", condition: "summary_start_gap", distanceMeters: summaryStartGap, limitMeters: ROUTE_ENDPOINT_GAP_METERS,
  });
  const summaryEndGap = distance(destination, summaryEnd);
  if (summaryEndGap > endGapLimit) endpointMismatch(endpoint, {
    point: "summaryEnd", condition: "summary_end_gap", distanceMeters: summaryEndGap, limitMeters: endGapLimit,
  });
  const points: Point[] = [];
  let length = 0;
  for (const raw of route.path) {
    const current = coordinate(raw);
    const previous = points.at(-1);
    if (previous?.lat === current.lat && previous.lng === current.lng) continue;
    if (previous) length += distance(previous, current);
    points.push(current);
  }
  if (summary.distance === 0) {
    if (length > ROUTE_ENDPOINT_GAP_METERS || summary.duration !== 0) invalid();
    for (const p of points) {
      const originGap = distance(p, origin);
      if (originGap > ROUTE_ENDPOINT_GAP_METERS) endpointMismatch(endpoint, {
        point: "zeroRoutePoint", condition: "zero_route_point", distanceMeters: originGap,
        limitMeters: ROUTE_ENDPOINT_GAP_METERS, reference: "origin",
      });
      const anchorGap = distance(p, destination);
      if (anchorGap > ROUTE_ENDPOINT_GAP_METERS) endpointMismatch(endpoint, {
        point: "zeroRoutePoint", condition: "zero_route_point", distanceMeters: anchorGap,
        limitMeters: ROUTE_ENDPOINT_GAP_METERS, reference: "anchor",
      });
    }
    return atAnchor(origin, destination);
  }
  if (points.length < 2 || summary.duration === 0) invalid();
  // A long road segment is valid; reject malformed breaks and geometry that
  // cannot fit its reported road distance, rather than applying GPS gap rules.
  if (length > summary.distance + Math.max(25, summary.distance * .1)) invalid();
  const actualStart = points[0];
  const actualEnd = points.at(-1)!;
  const startGapMeters = distance(origin, actualStart);
  const endGapMeters = distance(destination, actualEnd);
  if (startGapMeters > ROUTE_ENDPOINT_GAP_METERS) endpointMismatch(endpoint, {
    point: "actualStart", condition: "start_gap", distanceMeters: startGapMeters, limitMeters: ROUTE_ENDPOINT_GAP_METERS,
  });
  if (endGapMeters > endGapLimit) endpointMismatch(endpoint, {
    point: "actualEnd", condition: "end_gap", distanceMeters: endGapMeters, limitMeters: endGapLimit,
  });
  if (typeof endpoint === "object") {
    validateTraceRejoinEndpoint(actualEnd, points, endpoint, "actualEnd");
    if (distance(destination, summaryEnd) > ROUTE_ENDPOINT_GAP_METERS)
      validateTraceRejoinEndpoint(summaryEnd, points, endpoint, "summaryEnd");
  }
  return { result: "route", provider: "naver", routeOption: "traoptimal", points,
    meters: summary.distance, seconds: summary.duration / 1000,
    actualStart, actualEnd, startGapMeters, endGapMeters };
}

export async function readResponse(response: Response): Promise<unknown> {
  if (Number(response.headers.get("content-length")) > ROUTE_RESPONSE_LIMIT) {
    void response.body?.cancel().catch(() => {});
    throw new RouteError("ROUTE_TOO_LARGE");
  }
  if (!response.body) invalid();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      length += chunk.value.length;
      if (length > ROUTE_RESPONSE_LIMIT) {
        void reader.cancel().catch(() => {});
        throw new RouteError("ROUTE_TOO_LARGE");
      }
      chunks.push(chunk.value);
    }
  } finally {
    reader.releaseLock();
  }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, length))); }
  catch { invalid(); }
}

function retryAfter(value: string | null, now: number): number {
  const delay = value !== null && /^\d+(?:\.\d+)?$/.test(value) ? Number(value) * 1000
    : value === null ? 0 : Date.parse(value) - now;
  return Number.isFinite(delay) ? Math.min(Number.MAX_SAFE_INTEGER, Math.max(ROUTE_INTERVAL_MS, Math.ceil(delay))) : ROUTE_INTERVAL_MS;
}

export function naverProvider(fetcher: typeof fetch = fetch, now = () => Date.now(), includeTiming = false): RouteProvider {
  return async (origin, destination, signal, config, endpoint = "reference") => {
    try {
      const url = new URL("https://maps.apigw.ntruss.com/map-direction/v1/driving");
      url.searchParams.set("start", `${origin.lng},${origin.lat}`);
      url.searchParams.set("goal", `${destination.lng},${destination.lat}`);
      url.searchParams.set("option", "traoptimal");
      const response = await fetcher(url, {
        method: "GET", signal, redirect: "error", cache: "no-store",
        headers: { "x-ncp-apigw-api-key-id": config.keyId, "x-ncp-apigw-api-key": config.key },
      });
      if (response.status !== 200 && response.status !== 400) {
        void response.body?.cancel().catch(() => {});
        if (response.status === 401 || response.status === 403) throw new RouteError("PROVIDER_AUTH_FAILED");
        if (response.status === 429) throw new RouteError("PROVIDER_RATE_LIMITED", retryAfter(response.headers.get("retry-after"), now()));
        throw new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
      }
      const value = await readResponse(response);
      if (response.status === 400 && (!record(value) || ![1, 2, 3, 4, 5].includes(value.code as number))) invalid();
      return includeTiming ? parseNaverRecommendationRoute(value, origin, destination) : parseNaverRoute(value, origin, destination, endpoint);
    } catch (error) {
      if (signal.aborted && signal.reason instanceof RouteError) throw signal.reason;
      if (error instanceof RouteError) throw error;
      throw new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
    }
  };
}

// Guide indices refer to the ORIGINAL path. Cumulative distances at those
// indices preserve the mapping even when parseNaverRoute removes duplicates.
// https://api.ncloud-docs.com/docs/application-maps-directions5
export function parseNaverRecommendationRoute(value: unknown, origin: Point, destination: Point): TimedProviderRoute {
  const result = parseNaverRoute(value, origin, destination, "destination");
  const length = result.points.reduce((sum, p, i) => sum + (i ? distance(result.points[i - 1], p) : 0), 0);
  const rough = (): TimedProviderRoute => ({ ...result, timing: { quality: "rough",
    knots: [{ meters: 0, seconds: 0 }, { meters: length, seconds: result.seconds }] } });
  if (result.result === "atAnchor") return rough();
  const route = (value as { route: { traoptimal: { path: number[][]; guide?: unknown }[] } }).route.traoptimal[0];
  if (!Array.isArray(route.guide) || route.guide.length === 0 || route.guide.length > ROUTE_POINT_LIMIT) return rough();
  const rawDistances: number[] = [0];
  for (let i = 1; i < route.path.length; i++) rawDistances.push(rawDistances[i - 1] + distance(coordinate(route.path[i - 1]), coordinate(route.path[i])));
  const knots = [{ meters: 0, seconds: 0 }];
  let index = -1, seconds = 0;
  for (const guide of route.guide) {
    if (!record(guide) || !Number.isSafeInteger(guide.pointIndex) || (guide.pointIndex as number) <= index
      || (guide.pointIndex as number) >= rawDistances.length || (guide.pointIndex as number) < 0
      || !finite(guide.duration) || guide.duration < 0) return rough();
    index = guide.pointIndex as number; seconds += guide.duration / 1000;
    const meters = rawDistances[index];
    if (!Number.isFinite(seconds) || seconds > result.seconds + .001 || meters === knots.at(-1)!.meters && seconds !== knots.at(-1)!.seconds) return rough();
    if (meters !== knots.at(-1)!.meters) knots.push({ meters, seconds });
  }
  const last = knots.at(-1)!;
  if (last.meters < length) {
    // The remaining summary duration is explicitly the unreported tail only.
    if (result.seconds <= last.seconds) return rough();
    knots.push({ meters: length, seconds: result.seconds });
  } else if (Math.abs(last.seconds - result.seconds) > .001) return rough();
  return { ...result, timing: { quality: "guide", knots } };
}
