import type { LocationInvalidation, RoomLocationStore } from "./locations.ts";
import { canonicalJson, distance, parseAnyRouteRequest, RouteError, sameRef, ROUTE_INPUT_TTL_MS,
  ROUTE_INTERVAL_MS, ROUTE_TIMEOUT_MS, ROUTE_ENDPOINT_GAP_METERS } from "./route_contract.ts";
import type { AnyRouteRequest, AnyRouteResponse, Point, RouteAnchor, RouteErrorCode } from "./route_contract.ts";
import { fresh, quality, recordedTraceContinuous } from "./location_quality.ts";
import { CallBudget, DEFAULT_ROUTE_LIMITS } from "./call_budget.ts";
import type { Reservation } from "./call_budget.ts";
import type { FollowPlanService } from "./follow_plans.ts";
import { atAnchor, naverProvider, routeConfig } from "./route_providers/naver.ts";
import type { RouteConfig, RouteProvider, RouteEndpoint } from "./route_providers/naver.ts";
import { RejoinEndpointError, validateTraceRejoinEndpoint } from "./trace_rejoin.ts";
import type { RejoinRejectionDiagnostic } from "./trace_rejoin.ts";

export { parseRouteRequest, RouteError } from "./route_contract.ts";
export type { FollowRouteRequest } from "./route_contract.ts";

// Shared provider budgets are deliberately conservative until the operator
// verifies the account quota. They can be lowered through server configuration.
export { DEFAULT_ROUTE_LIMITS } from "./call_budget.ts";
export interface RouteServiceOptions {
  config?: () => RouteConfig;
  provider?: RouteProvider;
  now?: () => number;
  monotonicNow?: () => number;
  limits?: Partial<typeof DEFAULT_ROUTE_LIMITS>;
  budget?: CallBudget;
  plans?: FollowPlanService;
}
interface Input {
  code: string;
  requester: string;
  target: string;
  request: AnyRouteRequest;
  fingerprint: string;
  origin: Point;
  anchor: Point;
  // Input geometry owned by this 120 s pin, never cached provider geometry.
  endpoint: RouteEndpoint;
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

function coordinates(fix: Point): Point { return { lat: fix.lat, lng: fix.lng }; }
function logRejoinRejection(d: RejoinRejectionDiagnostic): void {
  const number = (value: number | null) => value !== null && Number.isFinite(value) ? value.toFixed(1) : "na";
  if ("distanceMeters" in d) {
    process.stdout.write(`follow-rejoin-rejected point=${d.point} condition=${d.condition}`
      + ` distance_m=${number(d.distanceMeters)} limit_m=${number(d.limitMeters)}`
      + (d.reference ? ` reference=${d.reference}` : "") + "\n");
    return;
  }
  const forward = d.forwardMeters !== null && Number.isFinite(d.forwardMeters)
    ? `${d.forwardMeters >= 0 ? "+" : ""}${number(d.forwardMeters)}` : "na";
  process.stdout.write(`follow-rejoin-rejected point=${d.point} condition=${d.condition}`
    + ` trace_m=${number(d.traceDistanceMeters)} forward_m=${forward} angle_deg=${number(d.directionDifferenceDegrees)}`
    + ` target_m=${number(d.targetDistanceMeters)} ambiguous_segments=${d.ambiguousSegments}`
    + ` trace_points=${d.tracePointCount} trace_length_m=${number(d.traceLengthMeters)}\n`);
}
function fingerprint(request: AnyRouteRequest): string {
  const { requestId: _attempt, ...input } = request;
  return canonicalJson(input);
}

export class FollowRouteService {
  #locations: RoomLocationStore;
  #config: () => RouteConfig;
  #provider: RouteProvider;
  #now: () => number;
  #clock: () => number;
  #budget: CallBudget;
  #plans?: FollowPlanService;
  #planInvalidated: (event: { code: string; planId: string; requester?: string }) => void;
  #inputs = new Map<string, Input>();
  #active = new Map<string, ActiveCall>();
  #closed = false;
  #onInvalidated: (event: LocationInvalidation) => void;

  constructor(locations: RoomLocationStore, options: RouteServiceOptions = {}) {
    this.#locations = locations;
    this.#config = options.config ?? routeConfig;
    this.#provider = options.provider ?? naverProvider();
    this.#now = options.now ?? (() => Date.now());
    this.#clock = options.monotonicNow ?? (() => performance.now());
    this.#budget = options.budget ?? new CallBudget({ clock: this.#clock, limits: options.limits });
    this.#plans = options.plans;
    this.#planInvalidated = (event) => this.#invalidate((input) => input.code === event.code
      && input.request.schemaVersion === 2 && input.request.planId === event.planId
      && (!event.requester || input.requester === event.requester), "PLAN_CHANGED");
    this.#plans?.on("invalidated", this.#planInvalidated);
    this.#onInvalidated = (event) => this.#invalidate((input) => input.code === event.code
      && (event.requester ? input.requester === event.requester
        : event.handle ? input.requester === event.handle || input.target === event.handle : true), "FOLLOW_NOT_ACTIVE");
    locations.on("invalidated", this.#onInvalidated);
  }

  feature() {
    const enabled = !this.#closed && this.#config().provider === "naver";
    return { enabled, schemaVersions: this.#plans ? [1, 2] : [1], provider: enabled ? "naver" : null, routeOption: enabled ? "traoptimal" : null,
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
    this.#budget.sweep();
    this.#locations.pruneReferences();
    if (this.#config().provider !== "naver") this.#invalidate(() => true, "ROUTING_DISABLED");
  }

  close(): void {
    this.#closed = true;
    this.#invalidate(() => true, "ROUTING_DISABLED");
    this.#plans?.off("invalidated", this.#planInvalidated);
    this.#locations.off("invalidated", this.#onInvalidated);
  }

  assertCurrent(code: string, requester: string, request: AnyRouteRequest, authorize: () => string): void {
    const { target } = this.#check(code, requester, request, authorize);
    const input = this.#inputs.get(requester);
    if (!input || input.code !== code || input.target !== target || input.fingerprint !== fingerprint(request)) {
      throw new RouteError("CONTEXT_MISMATCH");
    }
    if (this.#clock() >= input.deadline) {
      this.#drop(input, "REFERENCE_EXPIRED");
      throw new RouteError("REFERENCE_EXPIRED");
    }
    this.#requestAnchor(code, requester, target, request, false);
  }

  #check(code: string, requester: string, request: AnyRouteRequest, authorize: () => string): { target: string; config: RouteConfig & { provider: "naver" } } {
    const target = authorize();
    const config = this.#config();
    if (this.#closed || config.provider !== "naver") throw new RouteError("ROUTING_DISABLED");
    const relation = this.#locations.relationOf(code, requester);
    if (request.schemaVersion === 1 && (relation?.requestId !== request.followRequestId || this.#locations.targetOf(code, requester) !== target
      || relation.target !== target)) throw new RouteError("FOLLOW_NOT_ACTIVE");
    if (!this.#locations.isSharing(code, requester) || !this.#locations.isSharing(code, target)
      || !fresh(this.#locations.position(code, requester), this.#now())
      || !fresh(this.#locations.position(code, target), this.#now())) throw new RouteError("LOCATION_NOT_READY");
    if (request.schemaVersion === 2 && this.#plans?.routeContext(code, requester, request).target !== target) throw new RouteError("PLAN_CHANGED");
    return { target, config };
  }

  #requestAnchor(code: string, requester: string, target: string, request: AnyRouteRequest, initial: boolean): Point {
    if (request.schemaVersion === 1) return this.#anchor(code, target, request.anchor, initial);
    if (!this.#plans) throw new RouteError("PLAN_NOT_READY");
    const plan = this.#plans.routeContext(code, requester, request);
    return request.anchor.kind === "segment" ? this.#anchor(code, target, request.anchor, false) : plan.anchor;
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
      if (!recordedTraceContinuous(trail[i - 1], trail[i])) throw new RouteError("TRACE_DISCONTINUITY");
    }
    const current = this.#locations.position(code, target);
    if (!current || !sameRef(trail.at(-1)!, current)) throw new RouteError("TRACE_DISCONTINUITY");
    if (anchor.kind === "sample") return coordinates(start);
    const end = trail[index + 1];
    if (distance(start, end) === 0) throw new RouteError("TRACE_DISCONTINUITY");
    return { lat: start.lat + (end.lat - start.lat) * anchor.fraction, lng: start.lng + (end.lng - start.lng) * anchor.fraction };
  }

  #pin(code: string, requester: string, target: string, request: AnyRouteRequest): Input {
    let previous = this.#inputs.get(requester);
    if (previous && this.#clock() >= previous.deadline) {
      this.#drop(previous, "REFERENCE_EXPIRED");
      if (previous.request.calculationId === request.calculationId) throw new RouteError("REFERENCE_EXPIRED");
      previous = undefined;
    }
    if (previous && previous.request.calculationId === request.calculationId) {
      if (previous.code !== code || previous.target !== target || previous.fingerprint !== fingerprint(request)) throw new RouteError("CONTEXT_MISMATCH");
      this.#requestAnchor(code, requester, target, request, false);
      return previous;
    }
    if (previous && previous.request.followRequestId === request.followRequestId && previous.request.schemaVersion === request.schemaVersion
      && (request.schemaVersion === 1 || previous.request.schemaVersion === 2 && previous.request.planId === request.planId)
      && request.guidanceGeneration <= previous.request.guidanceGeneration) throw new RouteError("CONTEXT_MISMATCH");
    const origin = this.#locations.recentSample(code, requester, request.originRef);
    if (!fresh(origin, this.#now())) throw new RouteError("REFERENCE_EXPIRED");
    const anchor = this.#requestAnchor(code, requester, target, request, true);
    const endpoint = this.#endpoint({ code, target, request, anchor });
    if (previous) this.#drop(previous, "CONTEXT_MISMATCH");
    const input: Input = { code, requester, target, request, fingerprint: fingerprint(request), origin: coordinates(origin), anchor, endpoint,
      expiresAt: this.#now() + ROUTE_INPUT_TTL_MS, deadline: this.#clock() + ROUTE_INPUT_TTL_MS,
      attempts: 0, requestIds: new Set(), done: false, retryAt: 0 };
    input.timer = setTimeout(() => this.#drop(input, "REFERENCE_EXPIRED"), ROUTE_INPUT_TTL_MS).unref();
    this.#inputs.set(requester, input);
    return input;
  }

  #reserve(input: Input): Reservation | null {
    if (this.#active.has(input.requester)) throw new RouteError("ROUTE_IN_PROGRESS");
    if (input.done) throw input.lastError ? new RouteError(input.lastError.code, null, false) : new RouteError("CONTEXT_MISMATCH");
    if (input.retryAt > this.#clock()) throw new RouteError("RATE_LIMITED", Math.ceil(input.retryAt - this.#clock()));
    // A local near-goal result is not a provider call. Existing real-call
    // cooldowns stay intact for the next request that actually needs routing.
    return distance(input.origin, input.anchor) <= ROUTE_ENDPOINT_GAP_METERS
      ? null : this.#budget.reserve([input.requester]);
  }

  #endpoint(input: Pick<Input, "code" | "target" | "request" | "anchor">): RouteEndpoint {
    const request = input.request;
    const rejoining = request.schemaVersion === 1 ? request.mode === "B" : request.routeKind === "traceRejoin";
    if (!rejoining || request.anchor.kind !== "segment") {
      return request.schemaVersion === 2 && request.routeKind === "planDestination" ? "destination" : "reference";
    }
    const anchor = request.anchor;
    const trail = this.#locations.trail(input.code, input.target);
    const index = trail.findIndex((s) => sameRef(s, anchor.startRef));
    if (index < 0 || !trail[index + 1] || !sameRef(trail[index + 1], anchor.endRef)) throw new RouteError("TRACE_DISCONTINUITY");
    // Match the app's splitFollowTrace branch, including its continuous prefix
    // for ambiguity checks but never joining separate GPS sections with a line.
    let first = index, last = index + 1;
    while (first > 0 && recordedTraceContinuous(trail[first - 1], trail[first])) first--;
    while (last + 1 < trail.length && recordedTraceContinuous(trail[last], trail[last + 1])) last++;
    let minimum = 0;
    for (let i = first; i <= index; i++) {
      const length = distance(trail[i], trail[i + 1]);
      if (length >= .01) minimum += length * (i === index ? anchor.fraction : 1);
    }
    return { kind: "traceRejoin", points: trail.slice(first, last + 1).map(coordinates), minimum, anchor: { ...input.anchor } };
  }

  async calculate(code: string, requester: string, raw: unknown, authorize: () => string, signal?: AbortSignal): Promise<AnyRouteResponse> {
    const request = parseAnyRouteRequest(raw);
    let input: Input | undefined;
    try {
      const { target, config } = this.#check(code, requester, request, authorize);
      input = this.#pin(code, requester, target, request);
      if (signal?.aborted) throw new RouteError("CONTEXT_MISMATCH");
      if (input.requestIds.has(request.requestId) && !this.#active.has(requester)) throw new RouteError("CONTEXT_MISMATCH");
      const reservation = this.#reserve(input);
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
        input!.attempts++;
        if (reservation === null) {
          return atAnchor(input!.origin, input!.anchor);
        }
        reservation.start(requester);
        return this.#provider({ ...input!.origin }, { ...input!.anchor }, controller.signal, config,
          input!.endpoint);
      })();
      const release = () => { reservation?.release(requester); if (this.#active.get(requester) === active) this.#active.delete(requester); };
      void transport.then(release, release);
      try {
        const result = await Promise.race([transport, aborted]);
        this.assertCurrent(code, requester, request, authorize);
        if (controller.signal.aborted) throw new RouteError("CONTEXT_MISMATCH");
        const endpoint = input.endpoint;
        if (typeof endpoint === "object" && result.result !== "atAnchor") {
          validateTraceRejoinEndpoint(result.actualEnd, result.points, endpoint, "actualEnd");
          validateTraceRejoinEndpoint(result.points.at(-1), result.points, endpoint, "pathEnd");
        }
        // A reply can be lost after the provider succeeds. A new HTTP attempt
        // may recompute the same pinned input within the three-call budget;
        // no completed geometry is retained or replayed.
        input.done = input.attempts >= 3;
        const { timing: _timing, ...wireResult } = result as typeof result & { timing?: unknown };
        return { ...request, ...wireResult, requestedOrigin: { ...input.origin }, requestedAnchor: { ...input.anchor }, serverNowMs: this.#now() };
      } catch (error) {
        if (error instanceof RejoinEndpointError) logRejoinRejection(error.diagnostic);
        // Provider protection survives a later context/trace rejection. Keep
        // calculation-specific retry/error state below the live checks.
        if (error instanceof RouteError && error.code === "PROVIDER_RATE_LIMITED" && error.retryable) {
          this.#budget.defer(Math.max(ROUTE_INTERVAL_MS, error.retryAfterMs ?? 0));
        }
        // Late failures must not describe a no-longer-authorized calculation.
        this.#check(code, requester, request, authorize);
        if (this.#inputs.get(requester) !== input) throw new RouteError("CONTEXT_MISMATCH");
        this.#requestAnchor(code, requester, target, request, false);
        let failure = error instanceof RouteError ? error : new RouteError("PROVIDER_UNAVAILABLE", ROUTE_INTERVAL_MS);
        if (failure.retryable && failure.code !== "RATE_LIMITED") {
          input.retryAt = this.#clock() + Math.max(ROUTE_INTERVAL_MS, failure.retryAfterMs ?? 0);
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
