import type { LocationFix, LocationInvalidation, RoomLocationStore } from "./locations.ts";
import type { FollowPlanService } from "./follow_plans.ts";
import { parseRecommend } from "./follow_plan_contract.ts";
import type { RecommendRequest } from "./follow_plan_contract.ts";
import { fresh } from "./location_quality.ts";
import { distance, RouteError, ROUTE_POINT_LIMIT, ROUTE_TIMEOUT_MS } from "./route_contract.ts";
import type { Point, ProviderRoute } from "./route_contract.ts";
import { CallBudget } from "./call_budget.ts";
import type { Reservation } from "./call_budget.ts";
import { naverProvider, routeConfig } from "./route_providers/naver.ts";
import type { RouteConfig, RouteProvider, TimedProviderRoute } from "./route_providers/naver.ts";

const SAMPLE_LIMIT = 100_000;
interface Vertex extends Point { s: number; x: number; y: number }
interface Prepared { vertices: Vertex[]; grid: Map<string, number[]>; length: number; route: ProviderRoute }
interface Match { s: number; gap: number }
export interface RecommendationInput { handle: string; followRequestId: string | null; origin: LocationFix }
export interface RecommendationCandidate {
  result: "candidate" | "destinationOnly"; reason: "NO_COMMON_CORRIDOR" | "NEAR_DESTINATION" | null;
  joinPoint: Point & { label: string; source: "recommendation" };
  arrivals: { handle: string; followRequestId: string | null; etaToJoinSeconds: number; waitSeconds: number; etaQuality: "guide" | "rough" }[];
  earliestArrivalSeconds: number; latestArrivalSeconds: number; remainingToDestinationMeters: number;
  remainingToDestinationSeconds: number; etaQuality: "guide" | "rough";
}
export interface RecommendationOptions {
  now?: () => number; monotonicNow?: () => number; config?: () => RouteConfig; provider?: RouteProvider;
  eligible: (code: string, handle: string) => boolean;
}
function gridKey(x: number, y: number) { return `${x},${y}`; }
function timing(route: ProviderRoute, s: number, length: number): { seconds: number; quality: "guide" | "rough" } {
  const data = (route as Partial<TimedProviderRoute>).timing;
  if (data?.quality === "guide" && data.knots.length >= 2) {
    let low = 1, high = data.knots.length - 1;
    while (low < high) { const middle = (low + high) >>> 1; if (data.knots[middle].meters < s) low = middle + 1; else high = middle; }
    const a = data.knots[low - 1], b = data.knots[low];
    return { seconds: a.seconds + (b.seconds - a.seconds) * Math.max(0, Math.min(1, (s - a.meters) / (b.meters - a.meters))), quality: "guide" };
  }
  return { seconds: length ? route.seconds * Math.max(0, Math.min(1, s / length)) : 0, quality: "rough" };
}
export const etaAtDistance = timing;

// Geometry is local to a running batch. Dense points are only for comparison;
// the original provider polyline is never replaced, cached or returned here.
export async function recommendCorridor(routes: ProviderRoute[], inputs: RecommendationInput[], destination: Point,
  checkpoint: () => void = () => {}): Promise<RecommendationCandidate> {
  if (routes.length !== inputs.length || routes.length < 2 || routes.length > 8) throw new RouteError("INVALID_REQUEST");
  const latScale = 111195, lngScale = latScale * Math.cos(destination.lat * Math.PI / 180);
  let count = 0, work = 0;
  async function yieldWork() {
    if (++work % 512 === 0) { await new Promise<void>((resolve) => setImmediate(resolve)); checkpoint(); }
  }
  const prepared: Prepared[] = [];
  for (const route of routes) {
    checkpoint();
    if (route.points.length > ROUTE_POINT_LIMIT) throw new RouteError("RECOMMENDATION_TOO_LARGE");
    const vertices: Vertex[] = [];
    const add = (p: Point, s: number) => {
      if (++count > SAMPLE_LIMIT) throw new RouteError("RECOMMENDATION_TOO_LARGE");
      vertices.push({ ...p, s, x: (p.lng - destination.lng) * lngScale, y: (p.lat - destination.lat) * latScale });
    };
    let length = 0;
    if (route.points.length) add(route.points[0], 0);
    for (let i = 1; i < route.points.length; i++) {
      const a = route.points[i - 1], b = route.points[i], meters = distance(a, b);
      const parts = Math.ceil(meters / 20);
      if (count + parts > SAMPLE_LIMIT) throw new RouteError("RECOMMENDATION_TOO_LARGE");
      for (let j = 1; j <= parts; j++) {
        add({ lat: a.lat + (b.lat - a.lat) * j / parts, lng: a.lng + (b.lng - a.lng) * j / parts }, length + meters * j / parts);
        await yieldWork();
      }
      length += meters;
    }
    const grid = new Map<string, number[]>();
    for (let i = 1; i < vertices.length; i++) {
      const a = vertices[i - 1], b = vertices[i];
      const x0 = Math.floor(Math.min(a.x, b.x) / 20), x1 = Math.floor(Math.max(a.x, b.x) / 20);
      const y0 = Math.floor(Math.min(a.y, b.y) / 20), y1 = Math.floor(Math.max(a.y, b.y) / 20);
      if ((x1 - x0 + 1) * (y1 - y0 + 1) > 100) throw new RouteError("RECOMMENDATION_TOO_LARGE");
      for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) {
        const key = gridKey(x, y); const list = grid.get(key) ?? [];
        list.push(i - 1); grid.set(key, list);
      }
      await yieldWork();
    }
    prepared.push({ vertices, grid, length, route });
  }
  function match(route: Prepared, p: Vertex, dx: number, dy: number, maxGap = 20): Match | null {
    const candidates = new Set<number>();
    const x = Math.floor(p.x / 20), y = Math.floor(p.y / 20);
    for (let ix = x - 2; ix <= x + 2; ix++) for (let iy = y - 2; iy <= y + 2; iy++) {
      for (const index of route.grid.get(gridKey(ix, iy)) ?? []) {
        candidates.add(index);
        // Pathological loops in one cell must not turn this into all-pairs work.
        if (candidates.size > 256) return null;
      }
    }
    const matches: Match[] = [];
    for (const index of candidates) {
      const a = route.vertices[index], b = route.vertices[index + 1];
      const sx = b.x - a.x, sy = b.y - a.y, length2 = sx * sx + sy * sy;
      if (!length2 || (sx * dx + sy * dy) / Math.sqrt(length2 * (dx * dx + dy * dy)) < Math.SQRT1_2) continue;
      const f = Math.max(0, Math.min(1, ((p.x - a.x) * sx + (p.y - a.y) * sy) / length2));
      const gap = Math.hypot(a.x + sx * f - p.x, a.y + sy * f - p.y);
      if (gap <= maxGap) matches.push({ s: a.s + (b.s - a.s) * f, gap });
    }
    if (!matches.length) return null;
    matches.sort((a, b) => a.gap - b.gap);
    // Adjacent segments may both contain an endpoint. Distant visits to the
    // same corridor are ambiguous even when a monotonic pointer could pick one.
    if (matches.some((m) => Math.abs(m.s - matches[0].s) > 40)) return null;
    return matches[0];
  }
  const lead = prepared[0], vertices = lead.vertices;
  const valid = new Array<boolean>(Math.max(0, vertices.length - 1)).fill(false);
  const detourBarrier = new Array<boolean>(valid.length).fill(false);
  const extraDistance: number[][] = new Array(valid.length);
  const mappedPositions: number[][] = new Array(valid.length);
  const next = prepared.slice(1).map((p) => p.length);
  const nextLeader = prepared.slice(1).map(() => lead.length);
  for (let i = valid.length - 1; i >= 0; i--) {
    const a = vertices[i], b = vertices[i + 1];
    const mid: Vertex = { lat: (a.lat + b.lat) / 2, lng: (a.lng + b.lng) / 2, s: (a.s + b.s) / 2, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    const matches = prepared.slice(1).map((p) => match(p, mid, b.x - a.x, b.y - a.y));
    valid[i] = matches.every((m, j) => m !== null && m.s <= next[j] + .01);
    if (valid[i]) {
      // A follower can leave and re-enter only 20 m farther along the leader's
      // route after a long detour. Leader-only overlap would miss that break.
      extraDistance[i] = matches.map((m, j) => Math.max(0, next[j] - m!.s - (nextLeader[j] - mid.s)));
      mappedPositions[i] = matches.map((m) => m!.s);
      detourBarrier[i] = extraDistance[i].some((gap) => gap > 40);
      matches.forEach((m, j) => { next[j] = m!.s; nextLeader[j] = mid.s; });
    }
    await yieldWork();
  }
  let unmatched = 0, run = 0, longestRun = 0, candidate = -1;
  const extraUnmatched = prepared.slice(1).map(() => 0);
  const badPrefix = [0];
  for (let i = 0; i < valid.length; i++) badPrefix.push(badPrefix[i] + (valid[i] ? 0 : vertices[i + 1].s - vertices[i].s));
  let frontEnd = valid.length;
  for (let i = valid.length - 1; i >= 0; i--) {
    if (detourBarrier[i]) break;
    const length = vertices[i + 1].s - vertices[i].s;
    if (valid[i]) run = 0; else { unmatched += length; run += length; }
    longestRun = Math.max(longestRun, run);
    if (longestRun > 40 + .001) break;
    const remaining = lead.length - vertices[i].s;
    while (frontEnd > i + 1 && vertices[frontEnd - 1].s - vertices[i].s >= Math.min(200, remaining)) frontEnd--;
    const frontLength = vertices[frontEnd].s - vertices[i].s;
    extraDistance[i]?.forEach((gap, j) => { extraUnmatched[j] += gap; });
    if (valid[i] && unmatched <= remaining * .05 + .001 && badPrefix[frontEnd] - badPrefix[i] <= frontLength * .05 + .001
      && prepared.slice(1).every((p, j) => unmatched + extraUnmatched[j] <= (p.length - mappedPositions[i][j] + length / 2) * .05 + .001)
      && prepared.slice(1).every((p) => match(p, vertices[i], vertices[i + 1].x - vertices[i].x, vertices[i + 1].y - vertices[i].y))) candidate = i;
    await yieldWork();
  }
  let selected = candidate >= 0 ? vertices[candidate] : null;
  let selectedSegment = candidate;
  if (selected) {
    // Matching a 20 m segment can include a participant just beyond its start.
    // Clamp J to the latest current position on this same forward corridor,
    // using the original fix (provider snapping can itself be behind the car).
    let floor = selected.s;
    for (let i = 0; i < inputs.length; i++) {
      const start = prepared[i].vertices[0], next = prepared[i].vertices[1];
      if (!start || !next) continue;
      const origin = inputs[i].origin;
      const p: Vertex = { lat: origin.lat, lng: origin.lng, s: 0,
        x: (origin.lng - destination.lng) * lngScale, y: (origin.lat - destination.lat) * latScale };
      // Origin snapping allows 25 m; corridor-to-corridor matching stays 20 m.
      const projected = match(lead, p, next.x - start.x, next.y - start.y, 25);
      if (projected) floor = Math.max(floor, projected.s);
    }
    let shiftedSegment = candidate;
    while (shiftedSegment + 1 < vertices.length - 1 && vertices[shiftedSegment + 1].s < floor) shiftedSegment++;
    const a = vertices[shiftedSegment], b = vertices[shiftedSegment + 1];
    const t = (floor - a.s) / (b.s - a.s);
    const shifted = { lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t,
      x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, s: floor };
    // A clamp can land in a tolerated gap between valid samples. Retain the
    // verified candidate unless this exact point still belongs to every road.
    if (valid[shiftedSegment] && !detourBarrier[shiftedSegment]
      && prepared.slice(1).every((p) => match(p, shifted, b.x - a.x, b.y - a.y))) {
      selected = shifted;
      selectedSegment = shiftedSegment;
    }
  }
  const nearDestination = selected !== null && lead.length - selected.s <= 100;
  if (nearDestination) selected = null;
  let positions = prepared.map((p) => p.length);
  if (selected) {
    const start = vertices[selectedSegment], end = vertices[selectedSegment + 1];
    const matches = prepared.slice(1).map((p) => match(p, selected!, end.x - start.x, end.y - start.y));
    if (matches.some((m) => !m)) selected = null;
    else positions = [selected.s, ...matches.map((m) => m!.s)];
  }
  const estimates = prepared.map((p, i) => timing(p.route, positions[i], p.length));
  const earliest = Math.min(...estimates.map((e) => e.seconds)), latest = Math.max(...estimates.map((e) => e.seconds));
  checkpoint();
  return { result: selected ? "candidate" : "destinationOnly", reason: selected ? null : nearDestination ? "NEAR_DESTINATION" : "NO_COMMON_CORRIDOR",
    joinPoint: { lat: selected?.lat ?? destination.lat, lng: selected?.lng ?? destination.lng, label: selected ? "겹치는 구간 기준 추천" : "목적지에서 만나요", source: "recommendation" },
    arrivals: inputs.map((input, i) => ({ handle: input.handle, followRequestId: input.followRequestId,
      etaToJoinSeconds: estimates[i].seconds, waitSeconds: latest - estimates[i].seconds, etaQuality: estimates[i].quality })),
    earliestArrivalSeconds: earliest, latestArrivalSeconds: latest, remainingToDestinationMeters: selected ? lead.length - selected.s : 0,
    remainingToDestinationSeconds: selected ? Math.max(0, lead.route.seconds - estimates[0].seconds) : 0,
    etaQuality: estimates.every((e) => e.quality === "guide") ? "guide" : "rough" };
}

interface Batch { code: string; leader: string; request: RecommendRequest; inputs: RecommendationInput[]; controller: AbortController }
export class MeetingRecommendationService {
  #locations: RoomLocationStore; #plans: FollowPlanService; #budget: CallBudget; #options: RecommendationOptions;
  #now: () => number; #clock: () => number; #provider: RouteProvider; #config: () => RouteConfig;
  #active = new Map<string, Batch>(); #last = new Map<string, number>(); #closed = false;
  // Request-scoped final-write guards; weak keys retain no completed response.
  #replyChecks = new WeakMap<object, () => void>();
  #invalidate: (e: LocationInvalidation) => void;
  #planInvalidated: (e: { code: string; leaderHandle?: string; planId: string; requester?: string }) => void;
  constructor(locations: RoomLocationStore, plans: FollowPlanService, budget: CallBudget, options: RecommendationOptions) {
    this.#locations = locations; this.#plans = plans; this.#budget = budget; this.#options = options;
    this.#now = options.now ?? (() => Date.now()); this.#clock = options.monotonicNow ?? (() => performance.now());
    this.#provider = options.provider ?? naverProvider(fetch, this.#now, true); this.#config = options.config ?? routeConfig;
    this.#invalidate = (e) => {
      for (const batch of this.#active.values()) if (batch.code === e.code && (!e.handle && !e.requester
        || batch.inputs.some((i) => i.handle === (e.handle ?? e.requester)))) batch.controller.abort(new RouteError("RECOMMENDATION_STALE"));
    };
    this.#planInvalidated = (e) => {
      for (const batch of this.#active.values()) if (batch.code === e.code && (batch.request.planId === e.planId
        || batch.leader === e.leaderHandle)) batch.controller.abort(new RouteError("PLAN_CHANGED"));
    };
    locations.on("invalidated", this.#invalidate); plans.on("invalidated", this.#planInvalidated);
  }
  feature() { return { enabled: !this.#closed && this.#config().provider === "naver", maxVehicles: 8, previewTtlMs: 60_000 }; }
  assertCurrent(reply: object): void { const check = this.#replyChecks.get(reply); if (!check) throw new RouteError("RECOMMENDATION_STALE"); check(); }
  assertFailureCurrent(error: object): void { this.#replyChecks.get(error)?.(); }
  #check(batch: Batch, authorize: () => void, initial = false, checkSignal = true): void {
    authorize();
    if (!this.feature().enabled) throw new RouteError("ROUTING_DISABLED");
    this.#plans.validateRecommendation(batch.code, batch.leader, batch.request);
    const accepted = this.#locations.acceptedFollowersOf(batch.code, batch.leader);
    const consentMissing: string[] = [];
    for (const input of batch.inputs) {
      if (input.followRequestId !== null && !accepted.some((r) => r.requestId === input.followRequestId && r.requester === input.handle)) throw new RouteError("RECOMMENDATION_STALE");
      if (!this.#options.eligible(batch.code, input.handle)) {
        if (input.followRequestId === null) throw new RouteError("CONSENT_REQUIRED_SELF");
        consentMissing.push(input.followRequestId);
      }
    }
    if (consentMissing.length) { const e = new RouteError("CONSENT_REQUIRED_PARTICIPANT"); e.participantFollowRequestIds = consentMissing; throw e; }
    for (const input of batch.inputs) {
      const current = this.#locations.position(batch.code, input.handle);
      if (!this.#locations.isSharing(batch.code, input.handle) || !fresh(current, this.#now())) throw new RouteError(initial ? "LOCATION_NOT_READY" : "RECOMMENDATION_STALE");
      if (current.stream !== input.origin.stream || distance(current, input.origin) > 50) throw new RouteError("RECOMMENDATION_STALE");
    }
    if (checkSignal) batch.controller.signal.throwIfAborted();
  }
  async recommend(code: string, leader: string, raw: unknown, authorize: () => void, signal?: AbortSignal) {
    const request = parseRecommend(raw); authorize(); this.#plans.validateRecommendation(code, leader, request);
    if (!request.participantFollowRequestIds.length) throw new RouteError("NO_PARTICIPANTS");
    if (request.participantFollowRequestIds.length > 7) throw new RouteError("TOO_MANY_PARTICIPANTS");
    const accepted = this.#locations.acceptedFollowersOf(code, leader);
    const inputs = [{ handle: leader, followRequestId: null }, ...request.participantFollowRequestIds.map((id) => ({
      handle: accepted.find((r) => r.requestId === id)!.requester, followRequestId: id,
    }))].map((i) => ({ ...i, origin: this.#locations.position(code, i.handle)! }));
    const controller = new AbortController();
    const batch: Batch = { code, leader, request, inputs, controller };
    this.#check(batch, authorize, true);
    if (this.#active.has(leader)) throw new RouteError("ROUTE_IN_PROGRESS");
    const now = this.#clock(), last = this.#last.get(leader);
    if (last !== undefined && now - last < 30_000) throw new RouteError("RATE_LIMITED", Math.ceil(last + 30_000 - now));
    if (signal?.aborted) throw new RouteError("RECOMMENDATION_STALE");
    const reservation = this.#budget.reserve(inputs.map((i) => i.handle));
    this.#active.set(leader, batch); this.#last.set(leader, now);
    const cancel = () => controller.abort(new RouteError("RECOMMENDATION_STALE"));
    signal?.addEventListener("abort", cancel, { once: true });
    const timeout = setTimeout(() => controller.abort(new RouteError("ROUTE_TIMEOUT", null, false)), 15_000);
    const output: ProviderRoute[] = new Array(inputs.length);
    let completed = false;
    let cursor = 0;
    const checkpoint = () => { this.#check(batch, authorize); if (this.#clock() - now >= 15_000) throw new RouteError("ROUTE_TIMEOUT", null, false); };
    try {
      await Promise.all(Array.from({ length: Math.min(4, inputs.length) }, async () => {
        while (cursor < inputs.length) {
          const index = cursor++; checkpoint();
          output[index] = await this.#call(batch, index, reservation, authorize);
        }
      }));
      checkpoint();
      const candidate = await recommendCorridor(output, inputs, request.destination, checkpoint);
      checkpoint();
      const reply = { requestId: request.requestId, draftGeneration: request.draftGeneration, planId: request.planId,
        expectedRevision: request.expectedRevision, ...candidate, calculatedAtMs: this.#now(), expiresAtMs: this.#now() + 60_000,
        inputSnapshots: inputs.map((i) => ({ handle: i.handle, followRequestId: i.followRequestId,
          originRef: { stream: i.origin.stream, seq: i.origin.seq }, atMs: i.origin.at, receivedAtMs: i.origin.receivedAt })), serverNowMs: this.#now() };
      this.#replyChecks.set(reply, () => { if (signal?.aborted) throw new RouteError("RECOMMENDATION_STALE"); checkpoint(); });
      completed = true; return reply;
    } catch (error) {
      // Recheck before sending an old success OR failure. Cancellation is not a
      // destination-only result and partial route results are never returned.
      if (!controller.signal.aborted) this.#check(batch, authorize);
      const failure = error instanceof RouteError ? error : new RouteError("PROVIDER_UNAVAILABLE", null, false);
      this.#replyChecks.set(failure, () => this.#check(batch, authorize, false, false));
      throw failure;
    } finally {
      if (!completed) controller.abort(new RouteError("RECOMMENDATION_STALE"));
      reservation.releaseUnused();
      clearTimeout(timeout); signal?.removeEventListener("abort", cancel);
      if (this.#active.get(leader) === batch) this.#active.delete(leader);
      output.length = 0;
    }
  }
  async #call(batch: Batch, index: number, reservation: Reservation, authorize: () => void): Promise<ProviderRoute> {
    this.#check(batch, authorize);
    const config = this.#config(); if (config.provider !== "naver") throw new RouteError("ROUTING_DISABLED");
    const input = batch.inputs[index], controller = new AbortController();
    const cancel = () => controller.abort(batch.controller.signal.reason);
    batch.controller.signal.addEventListener("abort", cancel, { once: true });
    const timeout = setTimeout(() => controller.abort(new RouteError("ROUTE_TIMEOUT", null, false)), ROUTE_TIMEOUT_MS);
    const aborted = Promise.withResolvers<never>();
    const reject = () => aborted.reject(controller.signal.reason);
    controller.signal.addEventListener("abort", reject, { once: true });
    reservation.start(input.handle);
    const transport = (async () => this.#provider({ lat: input.origin.lat, lng: input.origin.lng },
      { lat: batch.request.destination.lat, lng: batch.request.destination.lng }, controller.signal, config, "destination"))();
    const release = () => reservation.release(input.handle);
    void transport.then(release, release);
    try {
      const result = await Promise.race([transport, aborted.promise]); this.#check(batch, authorize); return result;
    } catch (error) {
      if (error instanceof RouteError && error.code === "PROVIDER_RATE_LIMITED") this.#budget.defer(Math.max(30_000, error.retryAfterMs ?? 0));
      batch.controller.abort(error instanceof RouteError ? error : new RouteError("PROVIDER_UNAVAILABLE", null, false));
      throw batch.controller.signal.reason;
    } finally {
      clearTimeout(timeout); batch.controller.signal.removeEventListener("abort", cancel); controller.signal.removeEventListener("abort", reject);
    }
  }
  invalidateConsent(handle: string): void {
    for (const batch of this.#active.values()) if (batch.inputs.some((i) => i.handle === handle)) batch.controller.abort(new RouteError("CONSENT_REQUIRED_PARTICIPANT"));
  }
  sweep(): void { for (const [h, at] of this.#last) if (this.#clock() - at >= 30_000 && !this.#active.has(h)) this.#last.delete(h); }
  close(): void {
    this.#closed = true; for (const batch of this.#active.values()) batch.controller.abort(new RouteError("ROUTING_DISABLED"));
    this.#locations.off("invalidated", this.#invalidate); this.#plans.off("invalidated", this.#planInvalidated); this.#last.clear();
  }
}
