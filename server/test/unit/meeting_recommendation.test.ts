import assert from "node:assert/strict";
import { test } from "node:test";
import { CallBudget } from "../../src/call_budget.ts";
import { etaAtDistance, MeetingRecommendationService, recommendCorridor } from "../../src/meeting_recommendation.ts";
import type { RecommendationInput } from "../../src/meeting_recommendation.ts";
import { distance, RouteError } from "../../src/route_contract.ts";
import type { Point, ProviderRoute } from "../../src/route_contract.ts";
import { naverProvider, parseNaverRecommendationRoute } from "../../src/route_providers/naver.ts";
import { naverBody, naverConfig } from "../helpers/route_fixture.ts";
import { at, pin, planFixture } from "../helpers/plan_fixture.ts";

const error = (code: string) => (e: unknown) => e instanceof RouteError && e.code === code;
function road(points: Point[], seconds = 100): ProviderRoute {
  const meters = points.reduce((m, p, i) => m + (i ? distance(points[i - 1], p) : 0), 0);
  return { result: "route", provider: "naver", routeOption: "traoptimal", points, meters, seconds,
    actualStart: points[0], actualEnd: points.at(-1)!, startGapMeters: 0, endGapMeters: 0 };
}
function inputs(n: number): RecommendationInput[] {
  return Array.from({ length: n }, (_, i) => ({ handle: `car-${i}`, followRequestId: i ? `follow-${i}` : null,
    origin: { ...at(0), stream: "1".repeat(16), seq: 0, at: 0, receivedAt: 0, handle: `car-${i}`, acc: 3 } }));
}
test("recommendation geometry: full identical routes, long segments and multi-car common suffix", async () => {
  const lead = road([at(0), at(2000)]);
  const identical = await recommendCorridor([lead, lead], inputs(2), at(2000));
  assert.equal(identical.result, "candidate"); assert.ok(distance(identical.joinPoint, at(0)) < .01);
  const routes = [lead, road([at(-200, 300), at(500, 300), at(500), at(2000)]),
    road([at(-100, -300), at(1000, -300), at(1000), at(2000)])];
  const common = await recommendCorridor(routes, inputs(3), at(2000));
  assert.equal(common.result, "candidate"); assert.ok(distance(common.joinPoint, at(1000)) < 45);
  assert.ok(common.remainingToDestinationMeters > 950 && common.remainingToDestinationMeters < 1050);
  assert.equal(common.arrivals.length, 3); assert.equal(common.etaQuality, "rough");
  for (const v of common.arrivals) assert.equal(v.waitSeconds, common.latestArrivalSeconds - v.etaToJoinSeconds);
});
test("recommendation geometry: 837 m remaining is retained; only 100 m along route collapses to D", async () => {
  const lead = road([at(0), at(2000)]);
  const mid = await recommendCorridor([lead, road([at(0, 300), at(1163, 300), at(1163), at(2000)])], inputs(2), at(2000));
  assert.equal(mid.result, "candidate"); assert.ok(mid.remainingToDestinationMeters > 800 && mid.remainingToDestinationMeters < 900);
  const end = await recommendCorridor([lead, road([at(0, 300), at(1980, 300), at(1980), at(2000)])], inputs(2), at(2000));
  assert.equal(end.result, "destinationOnly");
});
test("recommendation geometry: early 1 km overlap followed by a split is not a common suffix", async () => {
  const routes = [road([at(0), at(3000)]), road([at(0), at(1200), at(1250, 100), at(2950, 100), at(3000)])];
  const result = await recommendCorridor(routes, inputs(2), at(3000));
  assert.equal(result.result, "destinationOnly");
});
test("recommendation geometry measures follower detours even when they re-enter only 20 m farther along the leader route", async () => {
  const result = await recommendCorridor([road([at(0), at(2000)]),
    road([at(0), at(1000), at(1000, 400), at(1020, 400), at(1020), at(2000)])], inputs(2), at(2000));
  assert.equal(result.result, "candidate");
  assert.ok(result.remainingToDestinationMeters < 1010 && result.remainingToDestinationMeters > 900);
});
test("recommendation geometry: parallel separation, reverse travel, crossings and ambiguous loops are not early joins", async () => {
  const lead = road([at(0), at(2000)]);
  for (const other of [road([at(0, 35), at(1950, 35), at(2000)]),
    road([at(1500), at(0), at(0, 200), at(2000, 200), at(2000)]),
    road([at(1000, -1000), at(1000, 1000), at(2000, 1000), at(2000)]),
    road([at(0), at(1800), at(1800, 100), at(0, 100), at(0), at(2000)])]) {
    const result = await recommendCorridor([lead, other], inputs(2), at(2000));
    assert.ok(result.result === "destinationOnly" || result.remainingToDestinationMeters < 250);
  }
});
test("recommendation geometry: bounded work and cancellation yield to the event loop", async () => {
  const large = road([at(0), at(2_000_001)]);
  await assert.rejects(recommendCorridor([large, large], inputs(2), at(2_000_001)), error("RECOMMENDATION_TOO_LARGE"));
  let cancel = false;
  setImmediate(() => { cancel = true; });
  const medium = road([at(0), at(20_000)]);
  await assert.rejects(recommendCorridor([medium, medium], inputs(2), at(20_000), () => {
    if (cancel) throw new RouteError("RECOMMENDATION_STALE");
  }), error("RECOMMENDATION_STALE"));
});
test("guide ETA: original duplicate indices, milliseconds, interpolation and summary tail", () => {
  const value = naverBody(at(0), at(300)) as any;
  const r = value.route.traoptimal[0];
  r.path = [at(0), at(100), at(100), at(200), at(300)].map((p) => [p.lng, p.lat]);
  r.summary.duration = 60_000;
  r.guide = [{ pointIndex: 2, duration: 10_000 }, { pointIndex: 3, duration: 20_000 }];
  const parsed = parseNaverRecommendationRoute(value, at(0), at(300));
  assert.equal(parsed.points.length, 4); assert.equal(parsed.timing.quality, "guide");
  assert.deepEqual(parsed.timing.knots.map((k) => k.seconds), [0, 10, 30, 60]);
  assert.ok(Math.abs(etaAtDistance(parsed, parsed.timing.knots[1].meters / 2, 300).seconds - 5) < 1e-6);
  assert.ok(Math.abs(etaAtDistance(parsed, parsed.timing.knots[2].meters + (parsed.timing.knots[3].meters - parsed.timing.knots[2].meters) / 2, 300).seconds - 45) < 1e-6);
  for (const guide of [undefined, [{ pointIndex: 2, duration: -1 }], [{ pointIndex: 3, duration: 10 }, { pointIndex: 1, duration: 10 }],
    [{ pointIndex: 0, duration: 1000 }], [{ pointIndex: 4, duration: 100 }], [{ pointIndex: 99, duration: 100 }]]) {
    r.guide = guide; assert.equal(parseNaverRecommendationRoute(value, at(0), at(300)).timing.quality, "rough");
  }
});
test("common budget: atomic all-account reservation, unused release, actual failed calls count, 30 s boundary", () => {
  let now = 0; const budget = new CallBudget({ clock: () => now, limits: { providerPerMinute: 3 } });
  const batch = budget.reserve(["a", "b", "c"]);
  assert.throws(() => budget.reserve(["a"]), error("ROUTE_IN_PROGRESS"));
  assert.throws(() => budget.reserve(["d"]), error("RATE_LIMITED"));
  batch.start("a"); batch.release("a"); batch.releaseUnused();
  const next = budget.reserve(["b", "c"]); next.releaseUnused();
  now = 29_999; assert.throws(() => budget.reserve(["a", "b"]), error("RATE_LIMITED"));
  const unblocked = budget.reserve(["b"]); unblocked.releaseUnused();
  now = 30_000; const ready = budget.reserve(["a", "b"]); ready.start("a"); ready.start("b"); ready.release("a"); ready.release("b");
  assert.throws(() => budget.reserve(["d"]), error("RATE_LIMITED"));
});

function recommendationFixture(t: Parameters<typeof planFixture>[0]) {
  const f = planFixture(t); const budget = new CallBudget({ clock: f.now });
  const service = new MeetingRecommendationService(f.locations, f.plans, budget,
    { ...f.routeOptions, monotonicNow: f.now, eligible: (_code, h) => !f.revoked.has(h) });
  t.after(() => service.close());
  const input = () => ({ requestId: "recommend", draftGeneration: 1, planId: null, expectedRevision: 0,
    destination: pin(1000), participantFollowRequestIds: [f.relation.requestId] });
  return { ...f, budget, service, input, run: (body = input()) => service.recommend(f.room.code, "leader", body, () => {}) };
}
test("recommendation: no plan or enrollment needed; N vehicles means N calls, response is a candidate and account cooldown remains", async (t) => {
  const f = recommendationFixture(t); const result = await f.run();
  assert.equal(f.calls.length, 2); assert.equal(result.result, "candidate"); assert.equal(f.get().plan, null);
  assert.equal(result.expiresAtMs - result.calculatedAtMs, 60_000); assert.equal(result.inputSnapshots.length, 2);
  assert.throws(() => f.budget.reserve(["follower"]), error("RATE_LIMITED"));
  await assert.rejects(f.run(), error("RATE_LIMITED"));
  f.step({ follower: 100 }); assert.throws(() => f.service.assertCurrent(result), error("RECOMMENDATION_STALE"));
});
test("recommendation: zero, too many, old consent and bad/stale input fail before any provider call", async (t) => {
  const f = recommendationFixture(t);
  await assert.rejects(f.run({ ...f.input(), participantFollowRequestIds: [] }), error("NO_PARTICIPANTS"));
  f.revoked.add("follower"); await assert.rejects(f.run(), error("CONSENT_REQUIRED_PARTICIPANT")); f.revoked.clear();
  f.elapse(1000); f.publish("follower", { acc: undefined });
  await assert.rejects(f.run(), error("LOCATION_NOT_READY"));
  assert.equal(f.calls.length, 0);
  f.rest();
  const ids = [f.relation.requestId];
  for (let i = 0; i < 7; i++) {
    const h = `extra${i}`; f.rest({ [h]: 0 }); ids.push(f.locations.requestFollow(f.room.code, h, "leader").requestId);
  }
  await assert.rejects(f.run({ ...f.input(), participantFollowRequestIds: ids }), error("TOO_MANY_PARTICIPANTS"));
  assert.equal(f.calls.length, 0);
});
test("recommendation: cancellation aborts all running calls and late success/failure cannot return a candidate", async (t) => {
  for (const change of ["consent", "leave", "plan", "move"]) {
    const f = recommendationFixture(t); const pending = Promise.withResolvers<ProviderRoute>();
    f.setProvider(() => pending.promise); const started = f.nextCall(); const run = f.run();
    await started;
    if (change === "consent") { f.revoked.add("follower"); f.service.invalidateConsent("follower"); }
    if (change === "leave") f.locations.unfollow(f.room.code, "follower");
    if (change === "plan") f.save();
    if (change === "move") f.step({ follower: 100 });
    pending.resolve(road([at(0), at(1000)]));
    await assert.rejects(run, (e: unknown) => e instanceof RouteError && ["RECOMMENDATION_STALE", "CONSENT_REQUIRED_PARTICIPANT", "PLAN_CHANGED"].includes(e.code));
    assert.ok(f.calls.every((c) => c.signal.aborted));
  }
});
test("recommendation: supplier failure is not destinationOnly and a new request after cooldown recomputes", async (t) => {
  const f = recommendationFixture(t);
  f.setProvider(async () => { throw new RouteError("NO_ROUTE"); });
  await assert.rejects(f.run(), error("NO_ROUTE"));
  for (let i = 0; i < 30; i++) f.step();
  f.setProvider(naverProvider(async (url) => {
    const u = new URL(String(url)); const [lng, lat] = u.searchParams.get("start")!.split(",").map(Number);
    return Response.json(naverBody({ lat, lng }, at(1000)));
  }));
  const before = f.calls.length; await f.run({ ...f.input(), requestId: "new" });
  assert.equal(f.calls.length - before, 2);
});

test("batch concurrency is four; partial failure releases unstarted reservations but charges started transports", async (t) => {
  const f = recommendationFixture(t); const ids = [f.relation.requestId];
  for (let i = 0; i < 6; i++) { const h = `extra${i}`; f.rest({ [h]: 0 }); ids.push(f.locations.requestFollow(f.room.code, h, "leader").requestId); }
  const requests: ReturnType<typeof Promise.withResolvers<ProviderRoute>>[] = [];
  f.setProvider((_origin, _destination, signal) => {
    const pending = Promise.withResolvers<ProviderRoute>(); requests.push(pending);
    signal.addEventListener("abort", () => pending.reject(signal.reason), { once: true }); return pending.promise;
  });
  const pending = f.run({ ...f.input(), participantFollowRequestIds: ids });
  const rejected = assert.rejects(pending, error("NO_ROUTE"));
  await Promise.resolve(); assert.equal(f.calls.length, 4);
  requests[0].reject(new RouteError("NO_ROUTE")); await rejected;
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(f.calls.length, 4);
  assert.throws(() => f.budget.reserve(["leader"]), error("RATE_LIMITED"));
  const unused = f.budget.reserve(["extra2", "extra3", "extra4", "extra5"]); unused.releaseUnused();
});
test("batch checks all participants atomically before reserving or transmitting and shares ordinary route budget", async (t) => {
  const f = recommendationFixture(t);
  const ordinary = f.budget.reserve(["follower"]); ordinary.start("follower"); ordinary.release("follower");
  await assert.rejects(f.run(), error("RATE_LIMITED")); assert.equal(f.calls.length, 0);
  // An unsuccessful atomic reservation must not consume the leader's slot.
  const leader = f.budget.reserve(["leader"]); leader.releaseUnused();
});
test("batch cancels a slow provider at five seconds without retrying or returning partial geometry", async (t) => {
  const f = recommendationFixture(t); t.mock.timers.enable({ apis: ["setTimeout"] });
  f.setProvider((_a, _b, signal) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true })));
  const run = f.run(); const failed = assert.rejects(run, error("ROUTE_TIMEOUT"));
  t.mock.timers.tick(5000); await failed; assert.equal(f.calls.length, 2); assert.ok(f.calls.every((c) => c.signal.aborted));
});
