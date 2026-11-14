import { distance, finite, point, record, RouteError, ROUTE_ENDPOINT_GAP_METERS,
  ROUTE_INTERVAL_MS, ROUTE_POINT_LIMIT, ROUTE_RESPONSE_LIMIT } from "../route_contract.ts";
import type { Point, ProviderRoute } from "../route_contract.ts";

export interface NaverConfig { provider: "naver"; keyId: string; key: string }
export type RouteConfig = NaverConfig | { provider: "disabled" };
export type RouteProvider = (origin: Point, destination: Point, signal: AbortSignal, config: NaverConfig) => Promise<ProviderRoute>;

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
function atAnchor(origin: Point, destination: Point): ProviderRoute {
  if (distance(origin, destination) > ROUTE_ENDPOINT_GAP_METERS) throw new RouteError("NO_ROUTE");
  return { result: "atAnchor", provider: "naver", routeOption: "traoptimal", points: [], meters: 0, seconds: 0,
    actualStart: null, actualEnd: null, startGapMeters: null, endGapMeters: null };
}

// Fixtures use invented coordinates, never saved product responses.
export function parseNaverRoute(value: unknown, origin: Point, destination: Point): ProviderRoute {
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
  if (distance(origin, summaryStart) > ROUTE_ENDPOINT_GAP_METERS
    || distance(destination, summaryEnd) > ROUTE_ENDPOINT_GAP_METERS) throw new RouteError("ENDPOINT_MISMATCH");
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
    if (points.some((p) => distance(p, origin) > ROUTE_ENDPOINT_GAP_METERS
      || distance(p, destination) > ROUTE_ENDPOINT_GAP_METERS)) throw new RouteError("ENDPOINT_MISMATCH");
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
  if (startGapMeters > ROUTE_ENDPOINT_GAP_METERS || endGapMeters > ROUTE_ENDPOINT_GAP_METERS) throw new RouteError("ENDPOINT_MISMATCH");
  return { result: "route", provider: "naver", routeOption: "traoptimal", points,
    meters: summary.distance, seconds: summary.duration / 1000,
    actualStart, actualEnd, startGapMeters, endGapMeters };
}

async function readResponse(response: Response): Promise<unknown> {
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

export function naverProvider(fetcher: typeof fetch = fetch, now = () => Date.now()): RouteProvider {
  return async (origin, destination, signal, config) => {
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
      return parseNaverRoute(value, origin, destination);
    } catch (error) {
      if (signal.aborted && signal.reason instanceof RouteError) throw signal.reason;
      if (error instanceof RouteError) throw error;
      throw new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
    }
  };
}
