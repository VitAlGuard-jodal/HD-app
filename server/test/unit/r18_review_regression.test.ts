import assert from "node:assert/strict";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { FollowRouteService } from "../../src/routes.ts";
import { createApp } from "../../src/app.ts";
import { updateUserConsent } from "../../src/store.ts";
import { CallBudget } from "../../src/call_budget.ts";
import { LOCATION_TRAIL_LIMIT } from "../../src/locations.ts";
import { distance, RouteError } from "../../src/route_contract.ts";
import type { Point, ProviderRoute } from "../../src/route_contract.ts";
import { naverProvider } from "../../src/route_providers/naver.ts";
import { routeFixture, naverBody, dispatch } from "../helpers/route_fixture.ts";
import { at, pin, planFixture } from "../helpers/plan_fixture.ts";

const error = (code: string) => (e: unknown) => e instanceof RouteError && e.code === code;
function body(start: Point, end: Point, before = at(240)) {
  const value = naverBody(start, end);
  value.route.traoptimal[0].path = [start, before, end].map((p) => [p.lng, p.lat]);
  value.route.traoptimal[0].summary.distance = Math.ceil(distance(start, before) + distance(before, end));
  return value;
}
function road(origin: Point, anchor: Point, end = at(280), before = at(240)): ProviderRoute {
  const points = [origin, before, end];
  return { result: "route", provider: "naver", routeOption: "traoptimal", points,
    meters: distance(origin, points[1]) + distance(points[1], points[2]), seconds: 12,
    actualStart: origin, actualEnd: points[2], startGapMeters: 0, endGapMeters: distance(anchor, points[2]) };
}
function traceFixture(t: TestContext, prefix: "gap" | "loop" | "none" = "none", tail = 600) {
  const f = routeFixture(t);
  const put = (meters: number, east = 0, elapsed = 1000) => {
    f.elapse(elapsed); return f.publish("leader", { ...at(meters, east) });
  };
  if (prefix === "gap") {
    put(600, 0, 11000); put(0, 0, 20000);
  } else {
    put(0, 0, 2000);
    if (prefix === "loop") {
      for (let m = 20; m <= 400; m += 20) put(m);
      for (let e = 20; e <= 100; e += 20) put(400, e);
      for (let m = 380; m >= 0; m -= 20) put(m, 100);
      for (let e = 80; e >= 0; e -= 20) put(0, e);
    }
  }
  const branch = [];
  for (let m = 20; m <= tail; m += 20) branch.push(put(m));
  const start = branch.find((s) => distance(s, at(200)) < .01)!;
  const next = branch.find((s) => s.seq === start.seq + 1)!;
  const self = f.publish("follower", { ...at(200, 200) });
  const anchor = { kind: "segment" as const, startRef: { stream: start.stream, seq: start.seq },
    endRef: { stream: next.stream, seq: next.seq }, fraction: 0 };
  f.setProvider(naverProvider(async () => Response.json(body(self, at(280)))));
  const service = new FollowRouteService(f.locations, f.routeOptions); t.after(() => service.close());
  const request = f.request({ mode: "B", anchor });
  return { ...f, service, request, put, self, run: () => service.calculate(f.room.code, "follower", request, () => "leader") };
}

test("R18.2 a gap before the anchor cannot add phantom competing trace segments", async (t) => {
  const f = traceFixture(t, "gap");
  const result = await f.run();
  assert.equal(result.result, "route");
  assert.ok(distance(result.actualEnd!, at(280)) < .01);
  assert.equal(f.calls.length, 1);
});

test("R18.2 competing visits in the same continuous branch still hold", async (t) => {
  const f = traceFixture(t, "loop");
  await assert.rejects(f.run(), error("ENDPOINT_MISMATCH"));
});

test("R18.4 missing trace endpoints fail before consuming provider budget or attempts", async (t) => {
  const f = routeFixture(t); f.elapse(1000);
  const start = f.publish("leader", { ...at(100) });
  const budget = new CallBudget({ clock: f.now });
  const service = new FollowRouteService(f.locations, { ...f.routeOptions, budget }); t.after(() => service.close());
  const request = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: start.stream, seq: start.seq },
    endRef: { stream: start.stream, seq: start.seq + 1 }, fraction: .5 } });
  for (let i = 0; i < 3; i++) {
    await assert.rejects(service.calculate(f.room.code, "follower", { ...request, requestId: `missing-${i}` }, () => "leader"), error("TRACE_DISCONTINUITY"));
  }
  assert.equal(f.calls.length, 0);
  const available = budget.reserve(["follower"]); available.releaseUnused();
  f.elapse(2000); f.publish("leader", { ...at(200) });
  const result = await service.calculate(f.room.code, "follower", { ...request, requestId: "now-present" }, () => "leader");
  assert.equal(result.result, "route"); assert.equal(f.calls.length, 1);
});

test("R18.3 a later continuous loop cannot change the in-flight endpoint judgement", async (t) => {
  const f = traceFixture(t, "none", 280);
  const pending = Promise.withResolvers<ProviderRoute>();
  f.setProvider(() => pending.promise);
  const started = f.nextCall(); const result = f.run(); await started;
  // Four continuous updates inside the provider's five-second deadline.
  f.put(280, 20); f.put(300, 20); f.put(300); f.put(280);
  f.publish("follower", { ...at(200, 200) });
  pending.resolve(road(f.self, at(200)));
  assert.equal((await result).result, "route");
  f.service.assertCurrent(f.room.code, "follower", f.request, () => "leader");
  assert.equal(f.calls.length, 1);
});

for (const local of [false, true]) {
  test(`R18.3 ring pruning cannot invalidate a pinned ${local ? "atAnchor" : "provider"} result`, async (t) => {
    const f = traceFixture(t);
    const anchor = f.request.anchor;
    assert.equal(anchor.kind, "segment"); if (anchor.kind !== "segment") return;
    const trail = f.locations.trail(f.room.code, "leader");
    const index = trail.findIndex((s) => s.seq === anchor.startRef.seq);
    for (let n = trail.length - index; n < LOCATION_TRAIL_LIMIT; n++) f.put(600);
    assert.equal(f.locations.trail(f.room.code, "leader")[0].seq, anchor.startRef.seq);
    const self = f.publish("follower", { ...at(200, local ? 0 : 200) });
    const request = { ...f.request, originRef: { stream: self.stream, seq: self.seq } };
    const pending = Promise.withResolvers<ProviderRoute>(); f.setProvider(() => pending.promise);
    const started = f.nextCall();
    const result = f.service.calculate(f.room.code, "follower", request, () => "leader");
    if (!local) await started;
    f.put(600);
    assert.notEqual(f.locations.trail(f.room.code, "leader")[0].seq, anchor.startRef.seq);
    if (!local) pending.resolve(road(self, at(200)));
    assert.equal((await result).result, local ? "atAnchor" : "route");
    f.service.assertCurrent(f.room.code, "follower", request, () => "leader");
    assert.equal(f.calls.length, local ? 0 : 1);
  });
}

test("R18.3 freezing geometry must not freeze live authorization", async (t) => {
  const f = traceFixture(t);
  const pending = Promise.withResolvers<ProviderRoute>(); f.setProvider(() => pending.promise);
  let allowed = true;
  const authorize = () => { if (!allowed) throw new RouteError("CONSENT_REQUIRED_TARGET"); return "leader"; };
  const started = f.nextCall();
  const result = f.service.calculate(f.room.code, "follower", f.request, authorize);
  const rejected = assert.rejects(result, error("CONSENT_REQUIRED_TARGET"));
  await started; allowed = false; pending.resolve(road(f.self, at(200))); await rejected;
});

for (const revoke of [false, true]) {
  test(`R18.3 schema 2 HTTP keeps pinned geometry and live consent (revoke=${revoke})`, async (t) => {
    const f = planFixture(t); f.plans.close();
    const app = createApp({ ...f, routeOptions: f.routeOptions });
    const api = (handle: string, path: string, body?: unknown, method = "POST") =>
      dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/${f.room.code}/${path}`, method }).done;
    const saved = await api("leader", "follow-plans/self", { operationId: "frozen-plan", expectedPlanId: null,
      expectedRevision: 0, destination: pin(1000), joinPoint: pin(100), policy: "proceed",
      participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: false }, "PUT");
    assert.equal(saved.statusCode, 200); const plan = saved.json().plan;
    assert.equal((await api("follower", "follow-plans/leader/participation", { operationId: "enroll",
      planId: plan.planId, planRevision: 1, followRequestId: f.relation.requestId, enabled: true }, "PUT")).statusCode, 200);
    for (const handle of ["leader", "follower"]) {
      for (const m of [70, 100, 130]) f.step({ [handle]: m }, 30);
      const reply = await api(handle, "follow-plans/leader/pass-evidence", { requestId: `pass-${handle}`,
        planId: plan.planId, revision: 1, followRequestId: handle === "leader" ? null : f.relation.requestId,
        pointKind: "joinPoint", ownRefs: f.locations.recentSamples(f.room.code, handle).slice(-3).map(({ stream, seq }) => ({ stream, seq })) });
      assert.equal(reply.statusCode, 200);
    }
    for (let m = 180; m <= 580; m += 50) f.step({ leader: m }, 50);
    f.step({ leader: 600 }, 20);
    const current = (await api("leader", "follow-plans/leader", undefined, "GET")).json();
    const anchor = current.runtime.traceStartRef;
    const trail = f.locations.trail(f.room.code, "leader");
    const index = trail.findIndex((s) => s.seq === anchor.startRef.seq);
    // Seed the bounded history without thousands of unrelated runtime snapshots.
    f.locations.removeAllListeners("accepted");
    for (let n = trail.length - index; n < LOCATION_TRAIL_LIMIT; n++) {
      f.elapse(1000); f.publish("leader", { ...at(600) });
    }
    const self = f.publish("follower", { ...at(100, 200) });
    assert.equal(f.locations.trail(f.room.code, "leader")[0].seq, anchor.startRef.seq);
    const pending = Promise.withResolvers<ProviderRoute>(); f.setProvider(() => pending.promise);
    const started = f.nextCall();
    const reply = api("follower", "follow-route", { schemaVersion: 2, planId: plan.planId, planRevision: 1,
      followRequestId: f.relation.requestId, guidanceGeneration: 1, calculationId: "frozen", requestId: "frozen",
      routeKind: "traceRejoin", originRef: { stream: self.stream, seq: self.seq }, anchor });
    await started;
    f.elapse(1000); f.publish("leader", { ...at(600) });
    if (revoke) updateUserConsent(f.db, f.users.find((u) => u.handle === "leader")!.id,
      { privacyVersion: "5", locationVersion: "5" });
    pending.resolve(road(self, at(100), at(180), at(140)));
    const result = await reply;
    if (revoke) {
      // Owner consent loss may clear the plan during the live context check.
      assert.ok([403, 409].includes(result.statusCode));
      assert.ok(["CONSENT_REQUIRED_TARGET", "PLAN_CHANGED"].includes(result.json().error.code));
      assert.equal(result.json().points, undefined);
      return;
    }
    assert.equal(result.statusCode, 200, JSON.stringify(result.json()));
    assert.deepEqual(result.json().anchor, anchor);
    // Finishing the old calculation does not restore a pruned runtime trace.
    const now = (await api("leader", "follow-plans/leader", undefined, "GET")).json();
    assert.equal(now.runtime.phase, "traceUnavailable");
  });
}

test("R18.3 retrying the same calculation retains its original trace snapshot", async (t) => {
  const f = traceFixture(t, "none", 280); const requestedAt = f.now();
  f.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30000); });
  await assert.rejects(f.run(), error("PROVIDER_UNAVAILABLE"));
  f.put(280, 20); f.put(300, 20); f.put(300); f.put(280);
  while (f.now() - requestedAt < 30000) f.put(280);
  f.publish("follower", { ...at(200, 200) });
  f.setProvider(naverProvider(async () => Response.json(body(f.self, at(280)))));
  const result = await f.service.calculate(f.room.code, "follower", { ...f.request, requestId: "retry" }, () => "leader");
  assert.equal(result.result, "route");
  assert.deepEqual(result.requestedOrigin, { lat: f.self.lat, lng: f.self.lng });
  assert.equal(f.calls.length, 2);
});
