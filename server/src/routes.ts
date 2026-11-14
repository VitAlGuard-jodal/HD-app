import type { LocationFix, LocationInvalidation, RoomLocationStore } from "./locations.ts";
import { distance, finite, parseRouteRequest, RouteError, sameRef, ROUTE_INPUT_TTL_MS,
  ROUTE_INTERVAL_MS, ROUTE_LOCATION_AGE_MS, ROUTE_TIMEOUT_MS } from "./route_contract.ts";
import type { FollowRouteRequest, FollowRouteResponse, Point, RouteAnchor, RouteErrorCode } from "./route_contract.ts";
import { naverProvider, routeConfig } from "./route_providers/naver.ts";
import type { RouteConfig, RouteProvider } from "./route_providers/naver.ts";

export { parseRouteRequest, RouteError } from "./route_contract.ts";
export type { FollowRouteRequest } from "./route_contract.ts";

// Shared provider budgets are deliberately conservative until the operator
// verifies the account quota. They can be lowered through server configuration.
export const DEFAULT_ROUTE_LIMITS = { accountPerMinute: 2, accountPerHour: 60, providerPerMinute: 60, providerPerHour: 1800 };
export interface RouteServiceOptions {
  config?: () => RouteConfig;
  provider?: RouteProvider;
  now?: () => number;
  monotonicNow?: () => number;
  limits?: Partial<typeof DEFAULT_ROUTE_LIMITS>;
}
interface Input {
  code: string;
  requester: string;
  target: string;
  request: FollowRouteRequest;
  fingerprint: string;
  origin: Point;
  anchor: Point;
  expiresAt: number;
  deadline: number;
  timer?: ReturnType<typeof setTimeout>;
  attempts: number;
  requestIds: Set<string>;
  lastError?: RouteError;
  done: boolean;
  retryAt: number;
}
interface ActiveCall {
  input: Input;
  controller: AbortController;
}

function accuracyAllowance(fix: LocationFix): number | undefined {
  // Pleos supplies no documented metre accuracy. 25 m is only an assumed
  // jump allowance, never a measured acc or proof of vehicle provenance.
  // Keep in sync with app/lib/location/follow_route_geometry.dart.
  if (fix.acc === undefined) return fix.src === "vehicle" ? 25 : undefined;
  return finite(fix.acc) && fix.acc >= 0 && fix.acc <= 25 ? fix.acc : undefined;
}
function quality(fix: LocationFix): boolean {
  return accuracyAllowance(fix) !== undefined
    && fix.at <= fix.receivedAt && fix.receivedAt - fix.at <= ROUTE_LOCATION_AGE_MS;
}
function fresh(fix: LocationFix | undefined, now: number): fix is LocationFix {
  return !!fix && quality(fix) && now >= fix.receivedAt && now - fix.receivedAt <= ROUTE_LOCATION_AGE_MS
    && now >= fix.at && now - fix.at <= ROUTE_LOCATION_AGE_MS;
}
function continuous(a: LocationFix, b: LocationFix): boolean {
  const elapsed = b.at - a.at;
  return a.stream === b.stream && b.seq === a.seq + 1 && quality(a) && quality(b)
    && elapsed > 0 && elapsed <= ROUTE_LOCATION_AGE_MS && b.receivedAt >= a.receivedAt
    && distance(a, b) <= 70 * elapsed / 1000 + accuracyAllowance(a)! + accuracyAllowance(b)!;
}
function coordinates(fix: Point): Point { return { lat: fix.lat, lng: fix.lng }; }
function fingerprint(request: FollowRouteRequest): string {
  const { requestId: _attempt, ...input } = request;
  return JSON.stringify(input);
}

export class FollowRouteService {
  #locations: RoomLocationStore;
  #config: () => RouteConfig;
  #provider: RouteProvider;
  #now: () => number;
  #clock: () => number;
  #limits: typeof DEFAULT_ROUTE_LIMITS;
  #inputs = new Map<string, Input>();
  #active = new Map<string, ActiveCall>();
  #accountCalls = new Map<string, number[]>();
  #providerCalls: number[] = [];
  #providerRetryAt = 0;
  #closed = false;
  #onInvalidated: (event: LocationInvalidation) => void;

  constructor(locations: RoomLocationStore, options: RouteServiceOptions = {}) {
    this.#locations = locations;
    this.#config = options.config ?? routeConfig;
    this.#provider = options.provider ?? naverProvider();
    this.#now = options.now ?? (() => Date.now());
    this.#clock = options.monotonicNow ?? (() => performance.now());
    this.#limits = { ...DEFAULT_ROUTE_LIMITS, ...options.limits };
    for (const [name, limit] of Object.entries(this.#limits)) {
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > DEFAULT_ROUTE_LIMITS[name as keyof typeof DEFAULT_ROUTE_LIMITS]) {
        throw new Error("Invalid route limit");
      }
    }
    this.#onInvalidated = (event) => this.#invalidate((input) => input.code === event.code
      && (event.requester ? input.requester === event.requester
        : event.handle ? input.requester === event.handle || input.target === event.handle : true), "FOLLOW_NOT_ACTIVE");
    locations.on("invalidated", this.#onInvalidated);
  }

  feature() {
    const enabled = !this.#closed && this.#config().provider === "naver";
    return { enabled, provider: enabled ? "naver" : null, routeOption: enabled ? "traoptimal" : null,
      ...(enabled ? {} : { code: "ROUTING_DISABLED" }) };
  }

  #drop(input: Input, code: RouteErrorCode): void {
    if (this.#inputs.get(input.requester) === input) this.#inputs.delete(input.requester);
    clearTimeout(input.timer);
    const active = this.#active.get(input.requester);
    if (active?.input === input) active.controller.abort(new RouteError(code));
  }

  #invalidate(matches: (input: Input) => boolean, code: RouteErrorCode): void {
    for (const input of this.#inputs.values()) if (matches(input)) this.#drop(input, code);
    // A replaced calculation may still be finishing its transport cancellation.
    for (const active of this.#active.values()) if (matches(active.input)) active.controller.abort(new RouteError(code));
  }

  invalidateConsent(handle: string): void {
    this.#invalidate((input) => input.requester === handle, "CONSENT_REQUIRED_SELF");
    this.#invalidate((input) => input.target === handle, "CONSENT_REQUIRED_TARGET");
  }

  sweep(): void {
    const now = this.#clock();
    for (const input of this.#inputs.values()) if (now >= input.deadline) this.#drop(input, "REFERENCE_EXPIRED");
    for (const [account, calls] of this.#accountCalls) {
      const recent = calls.filter((at) => now - at < 3_600_000);
      if (recent.length) this.#accountCalls.set(account, recent);
      else this.#accountCalls.delete(account);
    }
    this.#providerCalls = this.#providerCalls.filter((at) => now - at < 3_600_000);
    this.#locations.pruneReferences();
    if (this.#config().provider !== "naver") this.#invalidate(() => true, "ROUTING_DISABLED");
  }

  close(): void {
    this.#closed = true;
    this.#invalidate(() => true, "ROUTING_DISABLED");
    this.#accountCalls.clear();
    this.#providerCalls = [];
    this.#locations.off("invalidated", this.#onInvalidated);
  }

  assertCurrent(code: string, requester: string, request: FollowRouteRequest, authorize: () => string): void {
    const { target } = this.#check(code, requester, request, authorize);
    const input = this.#inputs.get(requester);
    if (!input || input.code !== code || input.target !== target || input.fingerprint !== fingerprint(request)) {
      throw new RouteError("CONTEXT_MISMATCH");
    }
    if (this.#clock() >= input.deadline) {
      this.#drop(input, "REFERENCE_EXPIRED");
      throw new RouteError("REFERENCE_EXPIRED");
    }
    this.#anchor(code, target, request.anchor, false);
  }

  #check(code: string, requester: string, request: FollowRouteRequest, authorize: () => string): { target: string; config: RouteConfig & { provider: "naver" } } {
    const target = authorize();
    const config = this.#config();
    if (this.#closed || config.provider !== "naver") throw new RouteError("ROUTING_DISABLED");
    const relation = this.#locations.relationOf(code, requester);
    if (relation?.requestId !== request.followRequestId || this.#locations.targetOf(code, requester) !== target
      || relation.target !== target) throw new RouteError("FOLLOW_NOT_ACTIVE");
    if (!this.#locations.isSharing(code, requester) || !this.#locations.isSharing(code, target)
      || !fresh(this.#locations.position(code, requester), this.#now())
      || !fresh(this.#locations.position(code, target), this.#now())) throw new RouteError("LOCATION_NOT_READY");
    return { target, config };
  }

  #anchor(code: string, target: string, anchor: RouteAnchor, initial: boolean): Point {
    const trail = this.#locations.trail(code, target);
    const startRef = anchor.kind === "sample" ? anchor.ref : anchor.startRef;
    const index = trail.findIndex((sample) => sameRef(sample, startRef));
    if (index < 0) throw new RouteError("REFERENCE_EXPIRED");
    const start = trail[index];
    if (anchor.kind === "sample" && initial && !fresh(start, this.#now())) throw new RouteError("REFERENCE_EXPIRED");
    if (!quality(start)) throw new RouteError("TRACE_DISCONTINUITY");
    if (anchor.kind === "segment" && (!trail[index + 1] || !sameRef(trail[index + 1], anchor.endRef))) {
      throw new RouteError("TRACE_DISCONTINUITY");
    }
    for (let i = index + 1; i < trail.length; i++) {
      if (!continuous(trail[i - 1], trail[i])) throw new RouteError("TRACE_DISCONTINUITY");
    }
    const current = this.#locations.position(code, target);
    if (!current || !sameRef(trail.at(-1)!, current)) throw new RouteError("TRACE_DISCONTINUITY");
    if (anchor.kind === "sample") return coordinates(start);
    const end = trail[index + 1];
    if (distance(start, end) === 0) throw new RouteError("TRACE_DISCONTINUITY");
    return { lat: start.lat + (end.lat - start.lat) * anchor.fraction, lng: start.lng + (end.lng - start.lng) * anchor.fraction };
  }

  #pin(code: string, requester: string, target: string, request: FollowRouteRequest): Input {
    let previous = this.#inputs.get(requester);
    if (previous && this.#clock() >= previous.deadline) {
      this.#drop(previous, "REFERENCE_EXPIRED");
      if (previous.request.calculationId === request.calculationId) throw new RouteError("REFERENCE_EXPIRED");
      previous = undefined;
    }
    if (previous && previous.request.calculationId === request.calculationId) {
      if (previous.code !== code || previous.target !== target || previous.fingerprint !== fingerprint(request)) throw new RouteError("CONTEXT_MISMATCH");
      this.#anchor(code, target, request.anchor, false);
      return previous;
    }
    if (previous && previous.request.followRequestId === request.followRequestId
      && request.guidanceGeneration <= previous.request.guidanceGeneration) throw new RouteError("CONTEXT_MISMATCH");
    const origin = this.#locations.recentSample(code, requester, request.originRef);
    if (!fresh(origin, this.#now())) throw new RouteError("REFERENCE_EXPIRED");
    const anchor = this.#anchor(code, target, request.anchor, true);
    if (previous) this.#drop(previous, "CONTEXT_MISMATCH");
    const input: Input = { code, requester, target, request, fingerprint: fingerprint(request), origin: coordinates(origin), anchor,
      expiresAt: this.#now() + ROUTE_INPUT_TTL_MS, deadline: this.#clock() + ROUTE_INPUT_TTL_MS,
      attempts: 0, requestIds: new Set(), done: false, retryAt: 0 };
    input.timer = setTimeout(() => this.#drop(input, "REFERENCE_EXPIRED"), ROUTE_INPUT_TTL_MS).unref();
    this.#inputs.set(requester, input);
    return input;
  }

  #reserve(input: Input): void {
    if (this.#active.has(input.requester)) throw new RouteError("ROUTE_IN_PROGRESS");
    if (input.done) {
      throw input.lastError ? new RouteError(input.lastError.code, null, false) : new RouteError("CONTEXT_MISMATCH");
    }
    const now = this.#clock();
    const calls = (this.#accountCalls.get(input.requester) ?? []).filter((at) => now - at < 3_600_000);
    this.#providerCalls = this.#providerCalls.filter((at) => now - at < 3_600_000);
    let wait = Math.max(0, input.retryAt - now, this.#providerRetryAt - now,
      calls.length ? calls.at(-1)! + ROUTE_INTERVAL_MS - now : 0);
    for (const [times, period, limit] of [
      [calls, 60_000, this.#limits.accountPerMinute], [calls, 3_600_000, this.#limits.accountPerHour],
      [this.#providerCalls, 60_000, this.#limits.providerPerMinute], [this.#providerCalls, 3_600_000, this.#limits.providerPerHour],
    ] as const) {
      const recent = times.filter((at) => now - at < period);
      if (recent.length >= limit) wait = Math.max(wait, recent[recent.length - limit] + period - now);
    }
    if (wait > 0) throw new RouteError("RATE_LIMITED", Math.ceil(wait));
    calls.push(now);
    this.#accountCalls.set(input.requester, calls);
    this.#providerCalls.push(now);
    input.attempts++;
  }

  async calculate(code: string, requester: string, raw: unknown, authorize: () => string, signal?: AbortSignal): Promise<FollowRouteResponse> {
    const request = parseRouteRequest(raw);
    let input: Input | undefined;
    try {
      const { target, config } = this.#check(code, requester, request, authorize);
      input = this.#pin(code, requester, target, request);
      if (signal?.aborted) throw new RouteError("CONTEXT_MISMATCH");
      if (input.requestIds.has(request.requestId) && !this.#active.has(requester)) throw new RouteError("CONTEXT_MISMATCH");
      this.#reserve(input);
      input.requestIds.add(request.requestId);
      const controller = new AbortController();
      const active = { input, controller };
      this.#active.set(requester, active);
      const cancel = () => controller.abort(new RouteError("CONTEXT_MISMATCH"));
      signal?.addEventListener("abort", cancel, { once: true });
      const timeout = setTimeout(() => controller.abort(new RouteError("ROUTE_TIMEOUT", ROUTE_INTERVAL_MS)), ROUTE_TIMEOUT_MS);
      let rejectAborted: () => void = () => {};
      const aborted = new Promise<never>((_resolve, reject) => {
        rejectAborted = () => reject(controller.signal.reason);
        controller.signal.addEventListener("abort", rejectAborted, { once: true });
      });
      // The transport keeps the account slot until its cancellation settles.
      const transport = (async () => {
        controller.signal.throwIfAborted();
        return this.#provider({ ...input!.origin }, { ...input!.anchor }, controller.signal, config);
      })();
      const release = () => { if (this.#active.get(requester) === active) this.#active.delete(requester); };
      void transport.then(release, release);
      try {
        const result = await Promise.race([transport, aborted]);
        this.assertCurrent(code, requester, request, authorize);
        if (controller.signal.aborted) throw new RouteError("CONTEXT_MISMATCH");
        // A reply can be lost after the provider succeeds. A new HTTP attempt
        // may recompute the same pinned input within the three-call budget;
        // no completed geometry is retained or replayed.
        input.done = input.attempts >= 3;
        return { ...request, ...result, requestedOrigin: { ...input.origin }, requestedAnchor: { ...input.anchor }, serverNowMs: this.#now() };
      } catch (error) {
        // Late failures must not describe a no-longer-authorized calculation.
        this.#check(code, requester, request, authorize);
        if (this.#inputs.get(requester) !== input) throw new RouteError("CONTEXT_MISMATCH");
        this.#anchor(code, target, request.anchor, false);
        let failure = error instanceof RouteError ? error : new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
        if (failure.retryable && failure.code !== "RATE_LIMITED") {
          input.retryAt = this.#clock() + Math.max(ROUTE_INTERVAL_MS, failure.retryAfterMs ?? 0);
          if (failure.code === "PROVIDER_RATE_LIMITED") this.#providerRetryAt = Math.max(this.#providerRetryAt, input.retryAt);
          if (input.attempts >= 3) failure = new RouteError(failure.code, null, false);
        }
        input.lastError = failure;
        input.done = !failure.retryable;
        throw failure;
      } finally {
        clearTimeout(timeout);
        signal?.removeEventListener("abort", cancel);
        controller.signal.removeEventListener("abort", rejectAborted);
      }
    } catch (error) {
      const failure = error instanceof RouteError ? error : new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
      if (["UNAUTHENTICATED", "NOT_ROOM_MEMBER", "NOT_ACTIVE_SENDER", "CONSENT_REQUIRED_SELF", "CONSENT_REQUIRED_TARGET", "ROUTING_DISABLED", "FOLLOW_NOT_ACTIVE"].includes(failure.code)) {
        const current = this.#inputs.get(requester);
        if (current && current.code === code && current.request.followRequestId === request.followRequestId) this.#drop(current, failure.code);
      }
      if (input && this.#inputs.get(requester) === input && this.#clock() < input.deadline) {
        failure.inputExpiresAtMs = input.expiresAt;
      }
      throw failure;
    }
  }
}
