import assert from "node:assert/strict";
import { test } from "node:test";
import { FollowRouteService } from "../../src/routes.ts";
import { RouteError } from "../../src/route_contract.ts";
import { CallBudget } from "../../src/call_budget.ts";
import { continuous, recordedTraceContinuous, context, stopped } from "../../src/location_quality.ts";
import { at, planFixture } from "../helpers/plan_fixture.ts";
import { routeFixture, naverBody } from "../helpers/route_fixture.ts";
import { naverProvider } from "../../src/route_providers/naver.ts";

test("R16.1 a parked leader upload gap preserves the J trace and rejoin route", async (t) => {
  const f = planFixture(t);
  const saved = f.save("proceed"); f.enroll(saved);
  for (const m of [70, 100, 130]) f.step({ leader: m }, 30);
  f.pass(saved.plan!, "leader");
  for (const m of [70, 100, 130]) f.step({ follower: m }, 30);
  f.pass(saved.plan!, "follower");
  for (let m = 180; m <= 980; m += 50) f.step({ leader: m }, 50);
  f.rest({ leader: 1000 });
  const anchor = f.get().runtime!.traceStartRef!;
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "leader")!.phase, "completed");
  f.elapse(20_000);
  f.publish("leader", { ...at(1000), speed: 0 });
  const self = f.publish("follower", { ...at(130), speed: 0 });
  const runtime = f.get().runtime!;
  assert.notEqual(runtime.phase, "traceUnavailable");
  assert.deepEqual(runtime.traceStartRef, anchor);
  const service = new FollowRouteService(f.locations, { ...f.routeOptions, plans: f.plans });
  t.after(() => service.close());
  // Rejoin ahead of the follower; the old J is now behind it and would require
  // the opposite arrival direction that r17 deliberately rejects.
  const trail = f.locations.trail(f.room.code, "leader");
  const next = trail.findIndex((s) => Math.abs(s.lat - at(180).lat) < 1e-10);
  const forwardAnchor = { kind: "segment" as const,
    startRef: { stream: trail[next].stream, seq: trail[next].seq },
    endRef: { stream: trail[next + 1].stream, seq: trail[next + 1].seq }, fraction: .4 };
  const result = await service.calculate(f.room.code, "follower", {
    schemaVersion: 2, planId: saved.plan!.planId, planRevision: 1,
    followRequestId: f.relation.requestId, guidanceGeneration: 1,
    calculationId: "parked-gap", requestId: "parked-gap", routeKind: "traceRejoin",
    originRef: { stream: self.stream, seq: self.seq }, anchor: forwardAnchor,
  }, () => "leader");
  assert.equal(result.result, "route");
  assert.equal(f.calls.length, 1);
});

test("R16.1 stationary trace exception keeps strict movement/stop evidence and boundaries", () => {
  const first = { handle: "leader", stream: "1".repeat(16), seq: 0, ...at(0), acc: 3, at: 1000, receivedAt: 1000 };
  for (const gap of [20_000, 120_000]) {
    const last = { ...first, ...at(6), seq: 1, at: 1000 + gap, receivedAt: 1000 + gap };
    assert.equal(recordedTraceContinuous(first, last), true);
    assert.equal(continuous(first, last), false);
    const end = { ...last, seq: 2, at: last.at + 1000, receivedAt: last.receivedAt + 1000 };
    assert.equal(context([first, last, end], end.at), false);
    assert.equal(stopped([first, last, end], end.at), false);
  }
  const after = { ...first, seq: 1, at: 21_000, receivedAt: 21_000 };
  for (const bad of [
    { ...after, ...at(6.1) }, { ...after, at: 121_001, receivedAt: 121_001 },
    { ...after, seq: 2 }, { ...after, stream: "2".repeat(16) },
    { ...after, acc: 26 }, { ...after, acc: undefined },
  ]) assert.equal(recordedTraceContinuous(first, bad), false);
});

test("R16.2 a received upload with a lost response can be repeated without changing history", (t) => {
  const f = routeFixture(t);
  const { receivedAt: _receivedAt, ...original } = f.locations.position(f.room.code, "leader")!;
  const before = f.locations.trail(f.room.code, "leader");
  let accepted = 0; f.locations.on("accepted", () => accepted++);
  f.elapse(5000);
  assert.deepEqual(f.locations.accept(f.room.code, original), { ok: true, dropped: true });
  assert.deepEqual(f.locations.trail(f.room.code, "leader"), before);
  f.elapse(1000);
  const next = f.publish("leader", { ...at(200) });
  f.elapse(5000);
  assert.deepEqual(f.locations.accept(f.room.code, original), { ok: true, dropped: true });
  assert.equal(f.locations.position(f.room.code, "leader")!.seq, next.seq);
  assert.equal(f.locations.trail(f.room.code, "leader").length, before.length + 1);
  assert.equal(accepted, 1);
});

for (const kind of ["P0", "J", "D"]) {
  test(`R16.4 ${kind} within 25 m returns atAnchor without sending a provider request`, async (t) => {
    const f = planFixture(t);
    let request: unknown;
    if (kind === "P0") {
      f.elapse(1000); f.publish("leader", { ...at(10) }); f.publish("follower", { ...at(0) });
      request = f.request();
    } else {
      const saved = f.save("proceed", 10, kind === "D" ? 10 : 1000); f.enroll(saved);
      const self = f.locations.position(f.room.code, "follower")!;
      request = { schemaVersion: 2, planId: saved.plan!.planId, planRevision: 1,
        followRequestId: f.relation.requestId, guidanceGeneration: 1, calculationId: "near", requestId: "near",
        routeKind: kind === "D" ? "planDestination" : "planJoin",
        originRef: { stream: self.stream, seq: self.seq }, anchor: { kind: kind === "D" ? "destination" : "joinPoint" } };
    }
    let fetched = 0;
    f.setProvider(naverProvider(async () => {
      fetched++;
      const body = naverBody(at(0), at(10));
      body.route.traoptimal[0].summary.distance = 0;
      body.route.traoptimal[0].summary.duration = 1000;
      return Response.json(body);
    }));
    const service = new FollowRouteService(f.locations, { ...f.routeOptions, plans: f.plans });
    t.after(() => service.close());
    const result = await service.calculate(f.room.code, "follower", request, () => "leader");
    assert.equal(result.result, "atAnchor"); assert.deepEqual(result.points, []);
    assert.equal(fetched, 0); assert.equal(f.calls.length, 0);
  });
}

for (const speed of [2, 3, 10]) {
  test(`R16.4 proceed from near J is revalidated after leaving its radius (${speed} m/s)`, (t) => {
    const f = planFixture(t); f.rest({ leader: -200 });
    const saved = f.save("proceed", 0, 1000); f.enroll(saved); f.rest();
    const first = f.locations.position(f.room.code, "follower")!;
    assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.passedAtMs, null);
    for (let m = speed; m <= 30; m += speed) f.step({ follower: m }, speed);
    const samples = f.locations.recentSamples(f.room.code, "follower");
    const freshStart = samples.find((s) => s.at >= first.at && s.at >= samples.at(-1)!.at - 10_000)!;
    const refs = [freshStart, samples.at(-2)!, samples.at(-1)!].map(({ stream, seq }) => ({ stream, seq }));
    const passed = f.plans.pass(f.room.code, "leader", "follower", { requestId: "near-pass", planId: saved.plan!.planId,
      revision: 1, followRequestId: f.relation.requestId, pointKind: "joinPoint", ownRefs: refs });
    assert.notEqual(passed.runtime!.vehicles.find((v) => v.handle === "follower")!.passedAtMs, null);
    f.step(); f.step();
    assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, "destination");
  });
}

test("R16.4 wait near J uses ordinary stopped arrival without passage", (t) => {
  const f = planFixture(t); const saved = f.save("wait", 0, 1000); f.enroll(saved); f.rest();
  const follower = f.get().runtime!.vehicles.find((v) => v.handle === "follower")!;
  assert.equal(follower.phase, "atJoinWaiting"); assert.equal(follower.passedAtMs, null);
});

test("R16.4 the provider bypass is limited to 25 m", async (t) => {
  for (const meters of [25, 25.01]) {
    const f = routeFixture(t);
    f.elapse(1000); f.publish("leader", { ...at(meters) }); f.publish("follower", { ...at(0) });
    const service = new FollowRouteService(f.locations, f.routeOptions); t.after(() => service.close());
    const result = await service.calculate(f.room.code, "follower", f.request(), () => "leader");
    assert.equal(result.result, meters === 25 ? "atAnchor" : "route");
    assert.equal(f.calls.length, meters === 25 ? 0 : 1);
  }
});

test("R16.4 near J is not passage and spaced refs cannot hide invalid motion", (t) => {
  for (const movement of [[10, 15, 20], [0, 0, 30], [20, 10, 30], [3, 6, 9]]) {
    const f = planFixture(t); f.rest({ leader: -200 });
    const saved = f.save("proceed", 0, 1000); f.enroll(saved); f.rest();
    const first = f.locations.position(f.room.code, "follower")!;
    for (const meters of movement) f.step({ follower: meters }, 10);
    const samples = f.locations.recentSamples(f.room.code, "follower");
    assert.throws(() => f.plans.pass(f.room.code, "leader", "follower", { requestId: "invalid-near-pass",
      planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId, pointKind: "joinPoint",
      ownRefs: [first, samples.at(-2)!, samples.at(-1)!].map(({ stream, seq }) => ({ stream, seq })) }),
    (e: unknown) => e instanceof RouteError && e.code === "PASS_NOT_CONFIRMED");
    assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.passedAtMs, null);
  }
});

test("R16.4 a no-provider J result leaves the call budget available for the D branch", async (t) => {
  const f = planFixture(t); f.rest({ leader: -200 });
  const saved = f.save("proceed", 0, 1000); f.enroll(saved);
  const service = new FollowRouteService(f.locations, { ...f.routeOptions, plans: f.plans });
  t.after(() => service.close());
  const request = (destination: boolean) => {
    const self = f.locations.position(f.room.code, "follower")!;
    return { schemaVersion: 2, planId: saved.plan!.planId, planRevision: 1,
      followRequestId: f.relation.requestId, guidanceGeneration: destination ? 2 : 1,
      calculationId: destination ? "after-J" : "at-J", requestId: destination ? "after-J" : "at-J",
      routeKind: destination ? "planDestination" : "planJoin",
      originRef: { stream: self.stream, seq: self.seq }, anchor: { kind: destination ? "destination" : "joinPoint" } };
  };
  const near = await service.calculate(f.room.code, "follower", request(false), () => "leader");
  assert.equal(near.result, "atAnchor"); assert.equal(f.calls.length, 0);
  for (const m of [10, 20, 30]) f.step({ follower: m }, 10);
  f.pass(saved.plan!, "follower"); f.step(); f.step();
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, "destination");
  const onward = await service.calculate(f.room.code, "follower", request(true), () => "leader");
  assert.equal(onward.result, "route"); assert.equal(f.calls.length, 1);
});

test("R16.4 near guidance needs no provider quota and does not reset real-call cooldown", async (t) => {
  const f = routeFixture(t);
  f.elapse(1000); f.publish("leader", { ...at(10) }); f.publish("follower", { ...at(0) });
  const budget = new CallBudget({ clock: f.now });
  const previous = budget.reserve(["follower"]); previous.start("follower"); previous.release("follower");
  const service = new FollowRouteService(f.locations, { ...f.routeOptions, budget }); t.after(() => service.close());
  assert.equal((await service.calculate(f.room.code, "follower", f.request(), () => "leader")).result, "atAnchor");
  assert.equal(f.calls.length, 0);
  f.elapse(1000); f.publish("leader", { ...at(100) }); f.publish("follower", { ...at(0) });
  await assert.rejects(service.calculate(f.room.code, "follower", f.request(), () => "leader"),
    (e: unknown) => e instanceof RouteError && e.code === "RATE_LIMITED");
  assert.equal(f.calls.length, 0);
});
