import { CallBudget } from "./call_budget.ts";
import { identifier, keys, point, record, RouteError } from "./route_contract.ts";
import type { FollowPlanService } from "./follow_plans.ts";
import type { LocationInvalidation, RoomLocationStore } from "./locations.ts";
import { readResponse } from "./route_providers/naver.ts";
import type { NaverConfig, RouteConfig } from "./route_providers/naver.ts";

export const GEOCODING_LIMITS = { accountPerMinute: 20, accountPerHour: 300, providerPerMinute: 120, providerPerHour: 3000 };
export interface AddressResult { lat: number; lng: number; label: string; roadAddress: string; jibunAddress: string }
export interface SearchRequest { requestId: string; query: string }
export type GeocodingProvider = (query: string, signal: AbortSignal, config: NaverConfig) => Promise<AddressResult[]>;
export interface GeocodingOptions {
  now?: () => number; monotonicNow?: () => number; config?: () => RouteConfig; provider?: GeocodingProvider;
  limits?: Partial<typeof GEOCODING_LIMITS>;
}
export function geocodingConfig(env: NodeJS.ProcessEnv = process.env): RouteConfig {
  const keyId = env.NAVER_DIRECTIONS_KEY_ID, key = env.NAVER_DIRECTIONS_KEY;
  if (env.GEOCODING_ENABLED !== "true" || !keyId || !key || !/^[\x21-\x7e]+$/.test(keyId) || !/^[\x21-\x7e]+$/.test(key)) return { provider: "disabled" };
  return { provider: "naver", keyId, key };
}
export function parseSearch(value: unknown): SearchRequest {
  if (!record(value) || !keys(value, ["requestId", "query"]) || !identifier(value.requestId)
    || typeof value.query !== "string" || /[\p{Cc}\p{Cf}]/u.test(value.query)) throw new RouteError("INVALID_REQUEST");
  const query = value.query.trim().replace(/\s+/gu, " ");
  if (Array.from(query).length < 2 || Array.from(query).length > 200) throw new RouteError("INVALID_REQUEST");
  return { requestId: value.requestId, query };
}
export function parseAddresses(value: unknown): AddressResult[] {
  function fail(): never { throw new RouteError("SEARCH_UNAVAILABLE"); }
  if (!record(value) || value.status !== "OK" || !Array.isArray(value.addresses) || value.addresses.length > 5) fail();
  return value.addresses.map((a: unknown) => {
    if (!record(a) || typeof a.x !== "string" || typeof a.y !== "string"
      || !/^-?\d+(?:\.\d+)?$/.test(a.x) || !/^-?\d+(?:\.\d+)?$/.test(a.y)) fail();
    const p = { lat: Number(a.y), lng: Number(a.x) };
    if (!point(p)) fail();
    const label = (value: unknown): string => {
      if (typeof value !== "string" || Array.from(value).length > 200 || /[\p{Cc}\p{Cf}]/u.test(value)) fail();
      return value.trim();
    };
    const roadAddress = label(a.roadAddress), jibunAddress = label(a.jibunAddress);
    if (!roadAddress && !jibunAddress) fail();
    return { ...p, label: roadAddress || jibunAddress, roadAddress, jibunAddress };
  });
}
export function naverGeocoding(fetcher: typeof fetch = fetch): GeocodingProvider {
  return async (query, signal, config) => {
    try {
      const url = new URL("https://maps.apigw.ntruss.com/map-geocode/v2/geocode");
      url.searchParams.set("query", query); url.searchParams.set("page", "1"); url.searchParams.set("count", "5");
      const response = await fetcher(url, { method: "GET", signal, cache: "no-store", redirect: "error",
        headers: { Accept: "application/json", "x-ncp-apigw-api-key-id": config.keyId, "x-ncp-apigw-api-key": config.key } });
      if (response.status !== 200) {
        void response.body?.cancel().catch(() => {});
        if (response.status === 429) {
          const header = response.headers.get("retry-after");
          const wait = header && /^\d+$/.test(header) ? Number(header) * 1000 : 60_000;
          throw new RouteError("RATE_LIMITED", Math.min(3_600_000, Math.max(1000, wait)));
        }
        throw new RouteError("SEARCH_UNAVAILABLE");
      }
      return parseAddresses(await readResponse(response));
    } catch (error) {
      if (signal.aborted && signal.reason instanceof RouteError) throw signal.reason;
      if (error instanceof RouteError && ["SEARCH_UNAVAILABLE", "RATE_LIMITED"].includes(error.code)) throw error;
      throw new RouteError("SEARCH_UNAVAILABLE");
    }
  };
}
interface Search { code: string; handle: string; controller: AbortController; planKey: string }
export class GeocodingService {
  #plans: FollowPlanService; #locations: RoomLocationStore; #now: () => number;
  #config: () => RouteConfig; #provider: GeocodingProvider; #budget: CallBudget;
  #active = new Map<string, Search>(); #closed = false;
  #replyChecks = new WeakMap<object, () => void>();
  #invalidated: (event: LocationInvalidation) => void;
  #planInvalidated: (event: { code: string; leaderHandle?: string }) => void;
  constructor(locations: RoomLocationStore, plans: FollowPlanService, options: GeocodingOptions = {}) {
    this.#plans = plans; this.#locations = locations; this.#now = options.now ?? (() => Date.now());
    this.#config = options.config ?? geocodingConfig; this.#provider = options.provider ?? naverGeocoding();
    this.#budget = new CallBudget({ clock: options.monotonicNow, defaults: GEOCODING_LIMITS, limits: options.limits, intervalMs: 1000 });
    this.#invalidated = (e) => {
      for (const s of this.#active.values()) if (s.code === e.code && (!e.handle && !e.requester || s.handle === (e.handle ?? e.requester))) s.controller.abort(new RouteError("PLAN_CHANGED"));
    };
    this.#planInvalidated = (e) => { const s = e.leaderHandle && this.#active.get(e.leaderHandle); if (s && s.code === e.code) s.controller.abort(new RouteError("PLAN_CHANGED")); };
    locations.on("invalidated", this.#invalidated); plans.on("invalidated", this.#planInvalidated);
  }
  feature() { return { enabled: !this.#closed && this.#config().provider === "naver" }; }
  assertCurrent(reply: object): void { const check = this.#replyChecks.get(reply); if (!check) throw new RouteError("PLAN_CHANGED"); check(); }
  assertFailureCurrent(error: object): void { this.#replyChecks.get(error)?.(); }
  #check(search: Search, authorize: () => void, checkSignal = true): NaverConfig {
    authorize();
    const config = this.#config();
    if (this.#closed || config.provider !== "naver") throw new RouteError("GEOCODING_DISABLED");
    this.#plans.assertEditable(search.code, search.handle);
    const snapshot = this.#plans.get(search.code, search.handle, search.handle);
    if (JSON.stringify([snapshot.plan?.planId, snapshot.plan?.revision]) !== search.planKey) throw new RouteError("PLAN_CHANGED");
    if (snapshot.runtime?.enrollments.length) throw new RouteError("PLAN_LOCKED");
    if (checkSignal) search.controller.signal.throwIfAborted();
    return config;
  }
  async search(code: string, handle: string, raw: unknown, authorize: () => void, signal?: AbortSignal) {
    const input = parseSearch(raw); authorize();
    const snapshot = this.#plans.get(code, handle, handle);
    const controller = new AbortController(); const search = { code, handle, controller, planKey: JSON.stringify([snapshot.plan?.planId, snapshot.plan?.revision]) };
    const config = this.#check(search, authorize);
    if (signal?.aborted) throw new RouteError("PLAN_CHANGED");
    const reservation = this.#budget.reserve([handle]); this.#active.set(handle, search);
    const cancel = () => controller.abort(new RouteError("PLAN_CHANGED"));
    signal?.addEventListener("abort", cancel, { once: true });
    const timeout = setTimeout(() => controller.abort(new RouteError("SEARCH_TIMEOUT")), 5000);
    const aborted = Promise.withResolvers<never>(); const reject = () => aborted.reject(controller.signal.reason);
    controller.signal.addEventListener("abort", reject, { once: true });
    reservation.start(handle);
    const transport = (async () => this.#provider(input.query, controller.signal, config))();
    const release = () => reservation.release(handle);
    void transport.then(release, release);
    try {
      const results = await Promise.race([transport, aborted.promise]);
      this.#check(search, authorize);
      const reply = { requestId: input.requestId, results, serverNowMs: this.#now() };
      this.#replyChecks.set(reply, () => { if (signal?.aborted) throw new RouteError("PLAN_CHANGED"); this.#check(search, authorize); });
      return reply;
    } catch (error) {
      if (!controller.signal.aborted) this.#check(search, authorize);
      const failure = error instanceof RouteError ? error : new RouteError("SEARCH_UNAVAILABLE");
      if (failure.code === "RATE_LIMITED") this.#budget.defer(failure.retryAfterMs ?? 60_000);
      this.#replyChecks.set(failure, () => this.#check(search, authorize, false));
      throw failure;
    } finally {
      clearTimeout(timeout); signal?.removeEventListener("abort", cancel); controller.signal.removeEventListener("abort", reject);
      if (this.#active.get(handle) === search) this.#active.delete(handle);
    }
  }
  invalidateConsent(handle: string): void { this.#active.get(handle)?.controller.abort(new RouteError("CONSENT_REQUIRED_SELF")); }
  sweep(): void { this.#budget.sweep(); }
  close(): void {
    this.#closed = true;
    for (const s of this.#active.values()) s.controller.abort(new RouteError("GEOCODING_DISABLED"));
    this.#locations.off("invalidated", this.#invalidated); this.#plans.off("invalidated", this.#planInvalidated);
  }
}
