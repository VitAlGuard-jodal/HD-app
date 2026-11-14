import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAnyRouteRequest, RouteError } from "../../src/route_contract.ts";
import type { PlanRouteRequest } from "../../src/route_contract.ts";
import { createApp } from "../../src/app.ts";
import { FollowRouteService } from "../../src/routes.ts";
import { tokenHash } from "../../src/auth.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { RoomLocationStore } from "../../src/locations.ts";
import { FollowPlanService } from "../../src/follow_plans.ts";
import { updateUserConsent } from "../../src/store.ts";
import { dispatch, naverConfig } from "../helpers/route_fixture.ts";
import { at, pin, planFixture } from "../helpers/plan_fixture.ts";

function error(code: string) { return (e: unknown) => e instanceof RouteError && e.code === code; }
test("r10: editing stays available between 5-second parked uploads with receipt delay", (t) => {
  const f = planFixture(t);
  for (let i = 0; i < 3; i++) {
    f.elapse(5000);
    f.publish("leader", { ...at(0), speed: 0, at: f.now() - 200 });
  }
  // Like the app, the server sees only the uploaded fixes, not every 1 Hz sensor fix.
  assert.doesNotThrow(() => f.plans.assertEditable(f.room.code, "leader"));
  f.elapse(4999);
  assert.doesNotThrow(() => f.plans.assertEditable(f.room.code, "leader"));
  assert.equal(f.save().plan!.status, "ready");
});
function parkedStep(f: ReturnType<typeof planFixture>, changes: Record<string, number> = {}, elapsed = 5000) {
  for (const [handle, meters] of Object.entries(changes)) f.positions.set(handle, meters);
  f.elapse(elapsed);
  for (const [handle, meters] of f.positions) f.publish(handle, { ...at(meters), speed: 0, at: f.now() - 200 });
}
for (const first of ["leader", "follower"]) test(`r10: 5-second wait arrival (${first} first) permits departure preparation`, (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  for (let i = 0; i < 3; i++) parkedStep(f, { [first]: 100 });
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === first)!.phase, "atJoinWaiting");
  for (let i = 0; i < 3; i++) parkedStep(f, { leader: 100, follower: 100 });
  f.elapse(4999);
  const ready = f.get();
  assert.ok(ready.runtime!.vehicles.every((v) => v.phase === "atJoinWaiting"));
  const announced = f.plans.depart(f.room.code, "leader", { operationId: "parked-depart", planId: saved.plan!.planId,
    planRevision: 1, expectedRuntimeRevision: ready.runtime!.runtimeRevision });
  assert.equal(announced.runtime!.departureAnnouncedAtMs, f.now());
  assert.equal(announced.runtime!.departedAtMs, null);
  assert.equal(announced.runtime!.traceStartRef, null);
});
for (const announced of [false, true]) test(`r10: first 1-second movement after parked evidence captures departure (announced=${announced})`, (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  for (let i = 0; i < 3; i++) parkedStep(f, { leader: 100, follower: 100 });
  const waiting = f.locations.position(f.room.code, "leader")!;
  if (announced) f.plans.depart(f.room.code, "leader", { operationId: "prepare", planId: saved.plan!.planId,
    planRevision: 1, expectedRuntimeRevision: f.get().runtime!.runtimeRevision });
  f.elapse(4000); // Motion starts just before the next parked upload would be due.
  for (const meters of [120, 140, 160]) f.step({ leader: meters, follower: meters }, 20);
  const after = f.get().runtime!;
  assert.equal(after.phase, "departed");
  assert.deepEqual(after.traceStartRef, { kind: "sample", ref: { stream: waiting.stream, seq: waiting.seq } });
});
for (const leaderMeters of [0, 100]) test(`r10: proceed follower first rechecks the parked leader outside/at J (${leaderMeters})`, (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (let i = 0; i < 3; i++) parkedStep(f, { leader: leaderMeters });
  for (const meters of [70, 100, 130]) {
    f.elapse(1000); f.publish("follower", { ...at(meters), speed: 30, at: f.now() - 200 });
  }
  f.pass(saved.plan!, "follower");
  assert.equal(f.get().runtime!.vehicles[1].branch, "pending");
  f.elapse(2000);
  assert.equal(f.get().runtime!.vehicles[1].branch, "pending", "the 2 s leader freshness limit still applies");
  f.publish("leader", { ...at(leaderMeters), speed: 0, at: f.now() - 200 });
  assert.equal(f.get().runtime!.vehicles[1].branch, leaderMeters === 0 ? "destination" : "pending");
});
test("r10: a fresh follower with broken stop evidence must re-establish wait arrival before preparation", (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  for (let i = 0; i < 3; i++) parkedStep(f, { leader: 100, follower: 100 });
  f.elapse(5000);
  f.publish("leader", { ...at(100), speed: 0, at: f.now() - 200 });
  const follower = f.locations.position(f.room.code, "follower")!;
  f.publish("follower", { ...at(100), seq: follower.seq + 2, speed: 0, at: f.now() - 200 });
  const current = f.get();
  assert.equal(current.runtime!.vehicles[1].phase, "toJoin");
  assert.throws(() => f.plans.depart(f.room.code, "leader", { operationId: "broken-wait", planId: saved.plan!.planId,
    planRevision: 1, expectedRuntimeRevision: current.runtime!.runtimeRevision }), error("DEPARTURE_NOT_READY"));
  for (let i = 0; i < 2; i++) parkedStep(f);
  assert.equal(f.get().runtime!.vehicles[1].phase, "atJoinWaiting");
});
test("r10: pruning and route-reference lookups preserve bounded parked evidence without extending route origins", (t) => {
  const f = planFixture(t);
  for (let i = 0; i < 3; i++) parkedStep(f);
  const oldest = f.locations.recentSamples(f.room.code, "leader").at(-3)!;
  f.elapse(4999);
  assert.equal(f.locations.recentSample(f.room.code, "leader", oldest), undefined);
  f.locations.pruneReferences();
  assert.doesNotThrow(() => f.plans.assertEditable(f.room.code, "leader"));
  f.elapse(20_002);
  f.locations.pruneReferences();
  assert.deepEqual(f.locations.recentSamples(f.room.code, "leader"), []);
});
for (const policy of ["wait", "proceed"] as const) test(`r10: parked J=D arrival completes each vehicle (${policy})`, (t) => {
  const f = planFixture(t); f.enroll(f.save(policy, 100, 100));
  for (let i = 0; i < 3; i++) parkedStep(f, { leader: 100 });
  assert.equal(f.get().runtime!.vehicles[0].phase, "completed");
  assert.equal(f.get().runtime!.vehicles[1].phase, "toJoin");
  for (let i = 0; i < 3; i++) parkedStep(f, { follower: 100 });
  assert.equal(f.get().runtime!.phase, "completed");
  assert.equal(f.get().runtime!.traceStartRef, null);
  assert.equal(f.get().runtime!.departedAtMs, null);
});
test("r10: parked allowance cannot authorize a sparse moving pass or departure", (t) => {
  for (const policy of ["wait", "proceed"] as const) {
    const f = planFixture(t); const saved = f.save(policy); f.enroll(saved);
    if (policy === "wait") for (let i = 0; i < 3; i++) parkedStep(f, { leader: 100, follower: 100 });
    for (const meters of policy === "wait" ? [120, 140, 160] : [70, 100, 130]) {
      f.elapse(5000);
      f.publish("leader", { ...at(meters), speed: 20, at: f.now() - 200 });
      f.publish("follower", { ...at(100), speed: 0, at: f.now() - 200 });
    }
    assert.equal(f.get().runtime!.departedAtMs, null);
    assert.equal(f.get().runtime!.traceStartRef, null);
    if (policy === "proceed") assert.throws(() => f.pass(saved.plan!, "leader"), error("PASS_NOT_CONFIRMED"));
  }
});
test("r10: parked HTTP search, recommendation, save, policy, participation and cancellation share the stop gate", async (t) => {
  const f = planFixture(t); f.plans.close();
  let searches = 0;
  const app = createApp({ ...f, routeOptions: f.routeOptions, geocodingOptions: {
    config: () => naverConfig, provider: async () => { searches++; f.elapse(400); return []; },
  } });
  for (let i = 0; i < 3; i++) parkedStep(f);
  f.elapse(4000);
  const api = (handle: string, path: string, body: unknown, method = "POST") =>
    dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/${f.room.code}/${path}`, method }).done;
  const search = await api("leader", "geocoding", { requestId: "parked-search", query: "시험로 123" });
  assert.equal(search.statusCode, 200); assert.equal(searches, 1);
  const recommendation = await api("leader", "follow-plans/self/recommend", { requestId: "parked-recommend", draftGeneration: 1,
    planId: null, expectedRevision: 0, destination: pin(1000), participantFollowRequestIds: [f.relation.requestId] });
  assert.equal(recommendation.statusCode, 200); assert.equal(f.calls.length, 2);
  const input = { operationId: "parked-save", expectedPlanId: null, expectedRevision: 0, destination: pin(1000), joinPoint: pin(100),
    policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true };
  const saved = await api("leader", "follow-plans/self", input, "PUT");
  assert.equal(saved.statusCode, 200);
  const plan = saved.json().plan;
  const changed = await api("leader", "follow-plans/self", { ...input, operationId: "parked-policy", expectedPlanId: plan.planId,
    expectedRevision: 1, policy: "proceed" }, "PUT");
  assert.equal(changed.statusCode, 200); assert.equal(changed.json().plan.policy, "proceed");
  for (const enabled of [true, false]) {
    const result = await api("follower", "follow-plans/leader/participation", { operationId: `parked-enroll-${enabled}`,
      planId: plan.planId, planRevision: 2, followRequestId: f.relation.requestId, enabled }, "PUT");
    assert.equal(result.statusCode, 200);
  }
  const removed = await api("leader", "follow-plans/self", { operationId: "parked-delete", planId: plan.planId, expectedRevision: 2 }, "DELETE");
  assert.equal(removed.statusCode, 200); assert.equal(removed.json().plan, null);
});
function route(f: ReturnType<typeof planFixture>, kind: PlanRouteRequest["routeKind"], handle = "leader"): PlanRouteRequest {
  const { plan } = f.get(); const fix = f.locations.position(f.room.code, handle)!;
  return { schemaVersion: 2, planId: plan!.planId, planRevision: plan!.revision,
    followRequestId: handle === "leader" ? null : f.relation.requestId, guidanceGeneration: 1, calculationId: "calc", requestId: "request",
    routeKind: kind, originRef: { stream: fix.stream, seq: fix.seq }, anchor: { kind: kind === "planJoin" ? "joinPoint" : "destination" } };
}
test("participant events ignore pending requests and duplicate relations, including preexisting accepted followers", (t) => {
  const locations = new RoomLocationStore();
  const existing = locations.requestFollow("ABC234", "existing", "leader");
  locations.respondFollow("ABC234", "leader", existing.requestId, true);
  const plans = new FollowPlanService(locations, { eligible: () => true });
  t.after(() => plans.close());
  const events: { code: string; leaderHandle: string; participants: ReturnType<FollowPlanService["participants"]> }[] = [];
  plans.on("participants-changed", (event) => events.push(event));
  locations.emit("relations-changed", { code: "ABC234", target: "leader" });
  assert.deepEqual(events, []);

  const pending = locations.requestFollow("ABC234", "follower", "other");
  locations.requestFollow("ABC234", "follower", "other");
  locations.emit("relations-changed", { code: "ABC234", target: "other" });
  locations.respondFollow("ABC234", "other", pending.requestId, false);
  locations.requestFollow("ABC234", "follower", "other");
  locations.unfollow("ABC234", "follower");
  assert.deepEqual(events, []);

  const accepted = locations.requestFollow("ABC234", "follower", "leader");
  assert.equal(accepted.accepted, true);
  assert.equal(events.length, 1);
  assert.deepEqual(events[0], { code: "ABC234", leaderHandle: "leader", participants: plans.participants("ABC234", "leader") });
  locations.requestFollow("ABC234", "follower", "leader");
  locations.emit("relations-changed", { code: "ABC234", target: "leader" });
  assert.equal(events.length, 1);
  locations.unfollow("ABC234", "follower");
  assert.equal(events.length, 2);
  assert.deepEqual(events[1].participants.map((p) => p.followRequestId), [existing.requestId]);
  locations.unfollow("ABC234", "existing");
  assert.equal(events.length, 3);
  assert.deepEqual(events[2].participants, []);
  locations.unfollow("ABC234", "existing");
  locations.emit("relations-changed", { code: "ABC234", target: "leader" });
  assert.equal(events.length, 3);
});
test("participant change detection is isolated by room and leader and resets when a room is cleared", (t) => {
  const locations = new RoomLocationStore();
  const plans = new FollowPlanService(locations, { eligible: () => true });
  t.after(() => plans.close());
  const events: { code: string; leaderHandle: string; participants: ReturnType<FollowPlanService["participants"]> }[] = [];
  plans.on("participants-changed", (event) => events.push(event));
  for (const [code, leader, follower] of [["ABC234", "leader", "follower"], ["DEF567", "leader", "follower"], ["ABC234", "other", "third"]]) {
    const pending = locations.requestFollow(code, follower, leader);
    const before = events.length;
    locations.respondFollow(code, leader, pending.requestId, true);
    assert.equal(events.length, before + 1);
    assert.deepEqual(events.at(-1), { code, leaderHandle: leader, participants: plans.participants(code, leader) });
  }
  assert.equal(events.length, 3);
  for (const [code, target] of [["ABC234", "leader"], ["DEF567", "leader"], ["ABC234", "other"]]) {
    locations.emit("relations-changed", { code, target });
  }
  assert.equal(events.length, 3);
  locations.clear("ABC234");
  locations.emit("relations-changed", { code: "ABC234", target: "leader" });
  locations.emit("relations-changed", { code: "ABC234", target: "other" });
  locations.emit("relations-changed", { code: "DEF567", target: "leader" });
  assert.equal(events.length, 3);
  const pending = locations.requestFollow("ABC234", "follower", "leader");
  assert.equal(events.length, 3);
  locations.respondFollow("ABC234", "leader", pending.requestId, true);
  assert.equal(events.length, 4);
  assert.equal(events[3].participants[0].followRequestId, pending.requestId);
});
for (const version of ["5", "6"]) test(`in-process follow SSE: pending and repeated requests stay quiet; plan participants require consent ${version}`, async (t) => {
  const f = planFixture(t); f.plans.close(); f.locations.clear(f.room.code);
  updateUserConsent(f.db, f.users[0].id, { privacyVersion: version, locationVersion: version });
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  const events = new Map<string, { name: string; data: any }[]>();
  for (const handle of ["leader", "follower", "third"]) {
    events.set(handle, []);
    t.after(f.hub.subscribe(f.room.code, handle, tokenHash(f.tokens.get(handle)!), (name, data) => events.get(handle)!.push({ name, data })));
  }
  const api = (handle: string, path: string, body?: unknown, method = "POST") =>
    dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/${f.room.code}/${path}`, method }).done;
  const pending = await api("follower", "follow", { target: "leader" });
  assert.equal(pending.statusCode, 202); assert.equal(pending.json().accepted, false);
  assert.deepEqual(events.get("leader")!.map((e) => e.name), ["follow-request"]);
  assert.equal(events.get("leader")![0].data.requestId, pending.json().requestId);
  events.get("leader")!.length = 0;
  const accepted = await api("leader", "follow/respond", { requestId: pending.json().requestId, accepted: true });
  assert.equal(accepted.statusCode, 202);
  assert.deepEqual(events.get("leader")!.map((e) => e.name), version === "6" ? ["follow-plan-participants", "follow-cancelled"] : ["follow-cancelled"]);
  assert.deepEqual(events.get("follower")!.map((e) => e.name), ["trail", "follow-response"]);
  assert.deepEqual(events.get("third"), []);
  if (version === "6") assert.equal(events.get("leader")![0].data.acceptedPlanFollowers[0].followRequestId, pending.json().requestId);
  const extra = await api("third", "follow", { target: "leader" });
  assert.equal(extra.statusCode, 202); assert.equal(extra.json().accepted, true);
  for (const received of events.values()) received.length = 0;
  f.elapse(1000);
  const repeated = await api("third", "follow", { target: "leader" });
  assert.equal(repeated.statusCode, 202); assert.equal(repeated.json().requestId, extra.json().requestId);
  f.locations.emit("relations-changed", { code: f.room.code, target: "leader" });
  for (const received of events.values()) assert.deepEqual(received, []);
  const removed = await api("follower", "follow", undefined, "DELETE");
  assert.equal(removed.statusCode, 202);
  assert.deepEqual(events.get("leader")!.map((e) => e.name), version === "6" ? ["follow-plan-participants", "follow-cancelled"] : ["follow-cancelled"]);
});
test("plan update, progress and clear events are silent on replay and unchanged inputs", (t) => {
  const f = planFixture(t);
  const events: string[] = [];
  f.plans.on("change", ({ event }) => events.push(event));
  const input = { operationId: "create", expectedPlanId: null, expectedRevision: 0, destination: pin(1000), joinPoint: pin(100),
    policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true };
  const saved = f.plans.save(f.room.code, "leader", input);
  assert.deepEqual(events, ["follow-plan-updated"]); events.length = 0;
  f.plans.save(f.room.code, "leader", input);
  assert.deepEqual(events, []);
  const enrollment = { operationId: "enroll", planId: saved.plan!.planId, planRevision: 1, followRequestId: f.relation.requestId, enabled: true };
  f.plans.participate(f.room.code, "leader", "follower", enrollment);
  assert.deepEqual(events, ["follow-plan-progress"]); events.length = 0;
  f.plans.participate(f.room.code, "leader", "follower", enrollment);
  f.plans.participate(f.room.code, "leader", "follower", { ...enrollment, operationId: "still-enrolled" });
  assert.deepEqual(events, []);
  const fix = f.locations.position(f.room.code, "follower")!;
  const status = { planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId,
    originRef: { stream: fix.stream, seq: fix.seq }, stage: "toJoin", etaSeconds: 100, calculatedAtMs: f.now() };
  f.plans.guidanceStatus(f.room.code, "leader", "follower", status);
  assert.deepEqual(events, ["follow-plan-progress"]); events.length = 0;
  const revision = f.get().runtime!.runtimeRevision;
  f.plans.guidanceStatus(f.room.code, "leader", "follower", status);
  f.plans.sweep(); f.get();
  f.locations.emit("relations-changed", { code: f.room.code, target: "leader" });
  assert.deepEqual(events, []); assert.equal(f.get().runtime!.runtimeRevision, revision);
  const deletion = { operationId: "delete", planId: saved.plan!.planId, expectedRevision: 1 };
  f.plans.remove(f.room.code, "leader", deletion);
  assert.deepEqual(events, ["follow-plan-cleared"]); events.length = 0;
  f.plans.remove(f.room.code, "leader", deletion);
  f.locations.emit("invalidated", { code: f.room.code, handle: "leader" });
  f.plans.sweep();
  assert.deepEqual(events, []);
});
test("r8 acceptance sends P0 trail before response, then continuous parked and moving location events", async (t) => {
  const f = planFixture(t); f.plans.close(); f.locations.clear(f.room.code);
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  const events: { name: string; data: any }[] = [];
  t.after(f.hub.subscribe(f.room.code, "follower", tokenHash(f.tokens.get("follower")!), (name, data) => events.push({ name, data })));
  const api = (handle: string, path: string, body: unknown) => dispatch(app, f.tokens.get(handle)!, body,
    { path: `/v1/rooms/${f.room.code}/${path}` }).done;
  const pending = (await api("follower", "follow", { target: "leader" })).json();
  assert.equal(pending.accepted, false);
  const publish = async (seq: number, meters: number, speed: number) => {
    const response = await api("leader", "location", { stream: "2222222222222222", seq, ...at(meters), at: f.now(), src: "vehicle", speed });
    assert.equal(response.statusCode, 202); assert.equal(response.json().dropped, false);
  };
  f.elapse(5000); await publish(0, 160, 0);
  events.length = 0;
  await api("leader", "follow/respond", { requestId: pending.requestId, accepted: true });
  assert.deepEqual(events.map((e) => e.name), ["trail", "follow-response"]);
  const trail = [...events[0].data.points];
  assert.equal(trail.length, 1); assert.equal(trail[0].seq, 0); assert.equal(trail[0].src, "vehicle");
  assert.equal(events[0].data.revision, events[1].data.revision);
  events.length = 0;
  let seq = 0;
  for (let second = 5; second <= 65; second += 5) { f.elapse(5000); await publish(++seq, 160, 0); }
  for (let second = 1; second <= 18; second++) { f.elapse(1000); await publish(++seq, 160 + second * 13.9, 13.9); }
  trail.push(...events.filter((e) => e.name === "location").map((e) => e.data));
  assert.equal(trail.length, 32);
  for (let i = 1; i < trail.length; i++) {
    assert.equal(trail[i].stream, trail[i - 1].stream);
    assert.equal(trail[i].seq, trail[i - 1].seq + 1);
    assert.ok(trail[i].at > trail[i - 1].at && trail[i].at - trail[i - 1].at <= 10000);
    assert.ok(trail[i].revision > (trail[i - 1].revision ?? 0));
    assert.equal(trail[i].src, "vehicle");
  }
});
test("gate 1: strict schema 2 preserves schema 1 and explicit owner-null references", (t) => {
  const f = planFixture(t); f.enroll(f.save());
  const input = route(f, "planJoin"); assert.deepEqual(parseAnyRouteRequest(input), input);
  for (const body of [{ ...input, mode: "B" }, { ...input, followRequestId: undefined }, { ...input, routeKind: "planDestination" },
    { ...input, planRevision: 0 }, { ...input, originRef: { ...input.originRef, seq: -1 } }]) assert.throws(() => parseAnyRouteRequest(body), error("INVALID_REQUEST"));
  assert.equal(parseAnyRouteRequest(f.request()).schemaVersion, 1);
});
test("gate 1: CAS, operation replay, locked enrollment, deletion and a new plan identity", (t) => {
  const f = planFixture(t);
  const input = { operationId: "create", expectedPlanId: null, expectedRevision: 0, destination: pin(1000), joinPoint: pin(100),
    policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true };
  const saved = f.plans.save(f.room.code, "leader", input);
  assert.deepEqual(f.plans.save(f.room.code, "leader", input), saved);
  assert.deepEqual(f.plans.save(f.room.code, "leader", Object.fromEntries(Object.entries(input).reverse())), saved);
  assert.throws(() => f.plans.save(f.room.code, "leader", { ...input, policy: "proceed" }), error("CONTEXT_MISMATCH"));
  f.enroll(saved);
  assert.throws(() => f.plans.save(f.room.code, "leader", { ...input, operationId: "edit", expectedPlanId: saved.plan!.planId, expectedRevision: 1 }), error("PLAN_LOCKED"));
  const deletion = { operationId: "delete", planId: saved.plan!.planId, expectedRevision: 1 };
  assert.equal(f.plans.remove(f.room.code, "leader", deletion).plan, null);
  assert.equal(f.plans.remove(f.room.code, "leader", deletion).plan, null);
  assert.equal(f.locations.targetOf(f.room.code, "follower"), "leader");
  assert.throws(() => f.plans.save(f.room.code, "leader", input), error("PLAN_CHANGED"));
  assert.notEqual(f.save().plan!.planId, saved.plan!.planId);
  assert.throws(() => f.plans.remove(f.room.code, "leader", deletion), error("PLAN_CHANGED"));
});

test("runtime changes only on state changes; readiness expires and stale runtime CAS cannot announce departure", (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved); f.rest({ leader: 100, follower: 100 });
  const ready = f.get(); let progress = 0; f.plans.on("change", (e) => { if (e.event === "follow-plan-progress") progress++; });
  for (let i = 0; i < 5; i++) f.step();
  assert.equal(progress, 0); assert.equal(f.get().runtime!.runtimeRevision, ready.runtime!.runtimeRevision);
  assert.throws(() => f.plans.depart(f.room.code, "leader", { operationId: "old-runtime", planId: saved.plan!.planId,
    planRevision: 1, expectedRuntimeRevision: 0 }), error("RUNTIME_CHANGED"));
  const input = { operationId: "prepare", planId: saved.plan!.planId, planRevision: 1, expectedRuntimeRevision: ready.runtime!.runtimeRevision };
  f.plans.depart(f.room.code, "leader", input);
  const preparedRevision = f.get().runtime!.runtimeRevision;
  f.plans.depart(f.room.code, "leader", input); assert.equal(f.get().runtime!.runtimeRevision, preparedRevision);
  for (let i = 0; i < 60; i++) f.step();
  assert.equal(f.get().runtime!.departureAnnouncedAtMs, null); assert.equal(f.get().runtime!.departedAtMs, null);
});
test("multicar readiness excludes invitations but requires every enrollment; no new enrollment after departure", (t) => {
  const f = planFixture(t); f.rest({ third: 0 });
  const third = f.locations.requestFollow(f.room.code, "third", "leader");
  const saved = f.save("wait", 100, 1000, "leader", [f.relation.requestId, third.requestId]); f.enroll(saved);
  f.rest({ leader: 100, follower: 100 });
  const ready = f.get();
  f.plans.depart(f.room.code, "leader", { operationId: "prepare", planId: saved.plan!.planId, planRevision: 1, expectedRuntimeRevision: ready.runtime!.runtimeRevision });
  for (const m of [120, 140, 160]) f.step({ leader: m }, 20);
  f.rest();
  assert.throws(() => f.enroll(saved, "third"), error("PLAN_DEPARTED"));
  assert.equal(f.get().runtime!.enrollments.length, 1);
});
test("trace context: references before J, broken streams, missing history and advisory status cannot forge permission", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  const original = f.locations.trail(f.room.code, "leader")[0];
  for (const m of [70, 100, 130]) f.step({ leader: m }, 30); f.pass(saved.plan!, "leader");
  for (const m of [70, 100, 130]) f.step({ follower: m }, 30); f.pass(saved.plan!, "follower");
  const start = f.get().runtime!.traceStartRef!; assert.equal(start.kind, "segment");
  const input = { ...route(f, "planJoin", "follower"), routeKind: "traceRejoin" as const, anchor: start as Extract<typeof start, { kind: "segment" }> };
  assert.equal(f.plans.routeContext(f.room.code, "follower", input).target, "leader");
  const old = { ...input, anchor: { kind: "segment" as const, startRef: { stream: original.stream, seq: original.seq }, endRef: { stream: original.stream, seq: original.seq + 1 }, fraction: 1 } };
  assert.throws(() => f.plans.routeContext(f.room.code, "follower", old), error("TRACE_UNAVAILABLE"));
  const before = f.get().runtime!;
  const current = f.locations.position(f.room.code, "follower")!;
  f.plans.guidanceStatus(f.room.code, "leader", "follower", { planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId,
    originRef: { stream: current.stream, seq: current.seq }, stage: "onTrace" });
  const after = f.get().runtime!;
  assert.equal(after.vehicles.find((v) => v.handle === "follower")!.branch, "trace");
  assert.equal(after.vehicles.find((v) => v.handle === "follower")!.phase, "tracePriming");
  assert.deepEqual(after.traceStartRef, before.traceStartRef);
  f.elapse(1000); f.publish("leader", { ...at(140), speed: 10, stream: "f".repeat(16), seq: 0 });
  assert.equal(f.get().runtime!.phase, "traceUnavailable");
  assert.throws(() => f.plans.routeContext(f.room.code, "follower", input), error("TRACE_UNAVAILABLE"));
});
test("trace window pruning cannot rebase an old J to a new first point", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (const m of [70, 100, 130]) f.step({ leader: m }, 30); f.pass(saved.plan!, "leader");
  for (const m of [70, 100, 130]) f.step({ follower: m }, 30); f.pass(saved.plan!, "follower");
  const anchor = f.get().runtime!.traceStartRef!;
  // Build the bounded server history without paying for thousands of snapshots.
  f.locations.removeAllListeners("accepted");
  for (let i = 0; i < 7210; i++) f.step({ leader: 200 + i }, 1);
  f.plans.sweep();
  assert.equal(f.get().runtime!.phase, "traceUnavailable"); assert.deepEqual(f.get().runtime!.traceStartRef, anchor);
});
test("proceed ordering never calls an observed-but-unconfirmed leader passage a fresh non-passage", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (const m of [70, 100, 130]) f.step({ leader: m, follower: m }, 30);
  f.pass(saved.plan!, "follower");
  for (let i = 0; i < 12; i++) f.step({ leader: 200 + i * 10 });
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, "pending");
});
test("gate 2: wait arrival in either order, announced departure is not motion, real trace starts at a waiting sample", (t) => {
  for (const first of ["leader", "follower"]) {
    const f = planFixture(t); const saved = f.save(); f.enroll(saved);
    f.rest({ [first]: 100 });
    assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === first)!.phase, "atJoinWaiting");
    assert.equal(f.get().runtime!.traceStartRef, null);
    f.rest({ leader: 100, follower: 100 });
    const before = f.get(); const revision = before.plan!.revision;
    const announced = f.plans.depart(f.room.code, "leader", { operationId: "depart", planId: saved.plan!.planId,
      planRevision: revision, expectedRuntimeRevision: before.runtime!.runtimeRevision });
    assert.equal(announced.runtime!.departedAtMs, null); assert.equal(announced.runtime!.traceStartRef, null);
    assert.deepEqual(f.plans.routeContext(f.room.code, "leader", route(f, "planDestination")).anchor, at(1000));
    for (const m of [120, 140, 160]) f.step({ leader: m, follower: m - 5 }, 20);
    const after = f.get(); assert.equal(after.plan!.revision, revision); assert.equal(after.runtime!.phase, "departed");
    assert.equal(after.runtime!.vehicles.find((v) => v.handle === "follower")!.phase, "tracePriming");
    assert.equal(after.runtime!.traceStartRef!.kind, "sample");
    assert.ok(after.runtime!.runtimeRevision > before.runtime!.runtimeRevision);
  }
});
test("gate 2: approach movement cannot depart; leaving before everyone arrives is leftEarly", (t) => {
  const f = planFixture(t); f.enroll(f.save());
  for (const m of [30, 60, 100]) f.step({ leader: m }, 20);
  assert.equal(f.get().runtime!.departedAtMs, null);
  f.rest({ leader: 100 });
  for (const m of [120, 140, 160]) f.step({ leader: m }, 20);
  assert.equal(f.get().runtime!.phase, "leftEarly"); assert.equal(f.get().runtime!.traceStartRef, null);
  assert.deepEqual(f.plans.routeContext(f.room.code, "follower", route(f, "planJoin", "follower")).anchor, at(100));
});
test("gate 2: implicit departure captures the cohort; a waiting follower who leaves before preparation must return to J", (t) => {
  const f = planFixture(t); f.enroll(f.save()); f.rest({ follower: 100 }); f.rest({ follower: 140 });
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.phase, "toJoin");
  f.rest({ leader: 100, follower: 100 });
  for (const m of [120, 140, 160]) f.step({ leader: m }, 20);
  assert.equal(f.get().runtime!.phase, "departed");
});
test("gate 3: proceed leader first yields real trace; follower first stays on D after leader passes", (t) => {
  for (const first of ["leader", "follower"]) {
    const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
    for (const m of [70, 100, 130]) f.step({ [first]: m }, 30);
    f.pass(saved.plan!, first);
    const second = first === "leader" ? "follower" : "leader";
    if (first === "follower") {
      f.step(); f.step();
      assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === first)!.branch, "destination");
      assert.deepEqual(f.plans.routeContext(f.room.code, first, route(f, "planDestination", first)).anchor, at(1000));
    }
    for (const m of [70, 100, 130]) f.step({ [second]: m }, 30);
    f.pass(saved.plan!, second);
    assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, first === "leader" ? "trace" : "destination");
    assert.equal(f.get().runtime!.leaderPassRef!.kind, "segment");
  }
});
test("gate 3: near or stale leader evidence leaves order pending; new leader pass resolves the grace window", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (const m of [70, 100, 130]) f.step({ leader: m, follower: m }, 30);
  f.pass(saved.plan!, "follower");
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, "pending");
  f.pass(saved.plan!, "leader");
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.branch, "trace");
});
test("gate 3: J=D completes each vehicle independently without trace or departure", (t) => {
  const f = planFixture(t); f.enroll(f.save("wait", 100, 100));
  f.rest({ leader: 100 });
  assert.equal(f.get().runtime!.vehicles[0].phase, "completed"); assert.notEqual(f.get().runtime!.phase, "completed");
  f.rest({ follower: 100 });
  assert.equal(f.get().runtime!.phase, "completed"); assert.equal(f.get().runtime!.traceStartRef, null);
});
test("gate 3: client cannot fabricate passage using replay, preactivation, reversed, jumped or stationary samples", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  assert.throws(() => f.pass(saved.plan!, "leader"), error("PASS_NOT_CONFIRMED"));
  f.rest({ leader: 100 }); assert.throws(() => f.pass(saved.plan!, "leader"), error("PASS_NOT_CONFIRMED"));
  for (const m of [70, 100, 70]) f.step({ leader: m }, 30);
  assert.throws(() => f.pass(saved.plan!, "leader"), error("PASS_NOT_CONFIRMED"));
  for (const m of [-1000, 0, 1000]) f.step({ leader: m }, 30);
  assert.throws(() => f.pass(saved.plan!, "leader"), error("PASS_NOT_CONFIRMED"));
});
test("authority: pending requests and invitations are not enrollment, independent groups cannot read or route each other", (t) => {
  const f = planFixture(t); f.rest({ third: 0 });
  const second = f.save("wait", 200, 2000, "third", []); const first = f.save();
  assert.equal(first.runtime!.enrollments.length, 0);
  assert.throws(() => f.plans.get(f.room.code, "third", "leader"), error("PLAN_NOT_PARTICIPANT"));
  assert.equal(f.plans.snapshots(f.room.code, "follower").length, 1);
  assert.equal(f.plans.snapshots(f.room.code, "third")[0].plan!.planId, second.plan!.planId);
  f.enroll(first); const input = route(f, "planJoin", "follower");
  f.locations.unfollow(f.room.code, "follower"); const freshRelation = f.locations.requestFollow(f.room.code, "follower", "leader");
  assert.notEqual(freshRelation.requestId, f.relation.requestId);
  assert.throws(() => f.plans.routeContext(f.room.code, "follower", input), error("PLAN_NOT_PARTICIPANT"));
  assert.equal(f.get().runtime!.enrollments.length, 0);
});
test("lifetime: stop proof, r6 vehicle quality, consent removal, 10 s suspension and device invalidation", (t) => {
  const f = planFixture(t); f.rest({}, { acc: undefined, src: "vehicle" });
  const saved = f.save(); f.enroll(saved);
  f.elapse(10_001); const delayed = f.get(); assert.equal(delayed.plan!.planId, saved.plan!.planId);
  assert.equal(delayed.runtime!.vehicles[0].condition, "locationDelayed");
  assert.throws(() => f.plans.assertEditable(f.room.code, "leader"), error("LOCATION_NOT_READY"));
  f.rest({}, { speed: undefined, acc: undefined, src: undefined });
  assert.throws(() => f.plans.assertEditable(f.room.code, "leader"), error("LOCATION_NOT_READY"));
  f.rest(); f.revoked.add("follower"); f.plans.invalidateConsent("follower");
  assert.equal(f.get().runtime!.enrollments.length, 0);
  f.locations.resetDevice(f.room.code, "leader"); assert.equal(f.get().plan, null);
});
test("HTTP manual plan and schema 2: both vehicles use fixed J, owner is not room creator, snapshots and no-store", async (t) => {
  const f = planFixture(t); f.plans.close();
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  async function api(handle: string, path: string, body?: unknown, method = "POST") {
    return (await dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/ABC234/${path}`, method }).done);
  }
  const body = { operationId: "manual-wait", expectedPlanId: null, expectedRevision: 0, destination: pin(1000), joinPoint: pin(100),
    policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true };
  const saved = await api("leader", "follow-plans/self", body, "PUT"); assert.equal(saved.statusCode, 200);
  assert.equal(saved.headers.get("cache-control"), "no-store");
  const plan = saved.json().plan;
  assert.equal((await api("follower", "follow-plans/leader/participation", { operationId: "join", planId: plan.planId,
    planRevision: plan.revision, followRequestId: f.relation.requestId, enabled: true }, "PUT")).statusCode, 200);
  for (const handle of ["leader", "follower"]) {
    const fix = f.locations.position(f.room.code, handle)!;
    const result = await api(handle, "follow-route", { schemaVersion: 2, planId: plan.planId, planRevision: plan.revision,
      followRequestId: handle === "leader" ? null : f.relation.requestId, guidanceGeneration: 1, calculationId: "manual", requestId: "attempt",
      routeKind: "planJoin", originRef: { stream: fix.stream, seq: fix.seq }, anchor: { kind: "joinPoint" } });
    assert.equal(result.statusCode, 200, JSON.stringify(result.json())); assert.deepEqual(result.json().requestedAnchor, at(100));
  }
  assert.equal((await api("third", "follow-plans/leader", undefined, "GET")).statusCode, 403);
  assert.equal((await api("leader", "follow-plans/third", body, "PUT")).json().error.code, "PLAN_NOT_OWNER");
  const positions = (await api("follower", "positions", undefined, "GET")).json();
  assert.equal(positions.followPlans.length, 1); assert.deepEqual(positions.followRoute.schemaVersions, [1, 2]);
  assert.equal((await api("leader", "follow-plans/self/participants", undefined, "GET")).json().participants.length, 1);
});

test("pass evidence reconstructs intervening high-frequency samples and rejects duplicate references", (t) => {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (let i = 0; i < 5; i++) { f.elapse(500); f.publish("leader", { ...at(70 + i * 15), speed: 30 }); }
  const samples = f.locations.recentSamples(f.room.code, "leader").slice(-5);
  const ownRefs = [0, 2, 4].map((i) => ({ stream: samples[i].stream, seq: samples[i].seq }));
  const request = { planId: saved.plan!.planId, revision: 1, followRequestId: null, requestId: "fast", pointKind: "joinPoint", ownRefs };
  assert.throws(() => f.plans.pass(f.room.code, "leader", "leader", { ...request, ownRefs: [ownRefs[0], ownRefs[0], ownRefs[2]] }), error("PASS_NOT_CONFIRMED"));
  assert.equal(f.plans.pass(f.room.code, "leader", "leader", request).runtime!.vehicles[0].phase, "toDestination");
});
test("advisory approach ETA remains fixed while stopped, expires at 60 s, and cannot manufacture trace or arrival", (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  const fix = f.locations.position(f.room.code, "follower")!;
  const input = { planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId,
    originRef: { stream: fix.stream, seq: fix.seq }, stage: "toJoin", etaSeconds: 100, calculatedAtMs: f.now() };
  f.plans.guidanceStatus(f.room.code, "leader", "follower", input);
  assert.throws(() => f.plans.guidanceStatus(f.room.code, "leader", "follower", { ...input, stage: "onTrace" }), error("TRACE_UNAVAILABLE"));
  for (let i = 0; i < 30; i++) f.step();
  const v = f.get().runtime!.vehicles.find((v) => v.handle === "follower")!;
  assert.equal(v.etaSeconds, 100); assert.equal(v.branch, "pending"); assert.equal(v.arrivedAtMs, null);
  for (let i = 0; i < 30; i++) f.step();
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.etaSeconds, null);
  assert.equal(f.get().runtime!.vehicles.find((v) => v.handle === "follower")!.calculatedAtMs, input.calculatedAtMs,
    "retain the calculation timestamp so the group can show refresh-needed instead of silently losing the ETA");
});
test("r8 approach ETA clears at authoritative arrival and rejects late approach reports", (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  const fix = f.locations.position(f.room.code, "follower")!;
  const input = { planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId,
    originRef: { stream: fix.stream, seq: fix.seq }, stage: "toJoin", etaSeconds: 100, calculatedAtMs: f.now() };
  f.plans.guidanceStatus(f.room.code, "leader", "follower", input);
  f.rest({ follower: 100 });
  const v = f.get().runtime!.vehicles.find((v) => v.handle === "follower")!;
  assert.equal(v.phase, "atJoinWaiting"); assert.equal(v.etaSeconds, null); assert.equal(v.calculatedAtMs, null);
  assert.equal(v.reportedStage, null);
  assert.throws(() => f.plans.guidanceStatus(f.room.code, "leader", "follower", input), error("PLAN_NOT_READY"));
});
test("r8 guidance ETA validates clocks, references and paired fields without changing authoritative state", (t) => {
  const f = planFixture(t); const saved = f.save(); f.enroll(saved);
  const fix = f.locations.position(f.room.code, "follower")!;
  const base = { planId: saved.plan!.planId, revision: 1, followRequestId: f.relation.requestId,
    originRef: { stream: fix.stream, seq: fix.seq }, stage: "toJoin", etaSeconds: 100, calculatedAtMs: f.now() };
  for (const change of [
    { etaSeconds: -1 }, { etaSeconds: 604801 }, { etaSeconds: NaN },
    { calculatedAtMs: f.now() + 1 }, { calculatedAtMs: f.now() - 60000 },
    { calculatedAtMs: f.now() + .5 }, { etaSeconds: undefined }, { calculatedAtMs: undefined },
    { arrived: true }, { stage: "atJoinWaiting" },
  ]) assert.throws(() => f.plans.guidanceStatus(f.room.code, "leader", "follower", { ...base, ...change }), error("INVALID_REQUEST"));
  assert.throws(() => f.plans.guidanceStatus(f.room.code, "leader", "follower", { ...base,
    originRef: { stream: fix.stream, seq: fix.seq + 100 } }), error("REFERENCE_EXPIRED"));
  const before = f.get().runtime!;
  const reported = f.plans.guidanceStatus(f.room.code, "leader", "follower", base).runtime!;
  const { reportedStage, etaSeconds, calculatedAtMs, ...vehicle } = reported.vehicles[1];
  const { reportedStage: _stage, etaSeconds: _eta, calculatedAtMs: _at, ...previous } = before.vehicles[1];
  assert.deepEqual(vehicle, previous);
  assert.equal(reported.phase, before.phase); assert.equal(reported.departureCohort, null);
  assert.equal(reported.traceStartRef, null); assert.equal(reported.departedAtMs, null);
  assert.throws(() => f.plans.guidanceStatus(f.room.code, "leader", "follower", { ...base, calculatedAtMs: f.now() - 1 }), error("INVALID_REQUEST"));
  f.elapse(10001); f.plans.sweep();
  const delayed = f.get().runtime!.vehicles[1];
  assert.equal(delayed.condition, "locationDelayed"); assert.equal(delayed.etaSeconds, null); assert.equal(delayed.calculatedAtMs, null);
});
for (const requester of ["leader", "follower"]) test(`r8 HTTP approach ETA from ${requester} reaches only its group and survives snapshots`, async (t) => {
  const f = planFixture(t); f.plans.close();
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  const api = (who: string, path: string, body?: unknown, method = "PUT", device?: string) =>
    dispatch(app, f.tokens.get(who)!, body, { path: `/v1/rooms/${f.room.code}/${path}`, method, device }).done;
  const saved = (await api("leader", "follow-plans/self", { operationId: "eta-save", expectedPlanId: null, expectedRevision: 0,
    destination: pin(1000), joinPoint: pin(100), policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true })).json();
  await api("follower", "follow-plans/leader/participation", { operationId: "eta-enroll", planId: saved.plan.planId,
    planRevision: 1, followRequestId: f.relation.requestId, enabled: true });
  const events = new Map<string, { name: string; data: any }[]>();
  for (const handle of ["leader", "follower", "third"]) {
    events.set(handle, []);
    t.after(f.hub.subscribe(f.room.code, handle, tokenHash(f.tokens.get(handle)!), (name, data) => events.get(handle)!.push({ name, data })));
  }
  const fix = f.locations.position(f.room.code, requester)!;
  const input = { planId: saved.plan.planId, revision: 1, followRequestId: requester === "leader" ? null : f.relation.requestId,
    originRef: { stream: fix.stream, seq: fix.seq }, stage: "toJoin", etaSeconds: 120, calculatedAtMs: f.now() };
  const response = await api(requester, "follow-plans/leader/guidance-status", input);
  assert.equal(response.statusCode, 200);
  for (const handle of ["leader", "follower"]) {
    const progress = events.get(handle)!.filter((e) => e.name === "follow-plan-progress");
    assert.equal(progress.length, 1);
    const runtime = progress[0].data.runtime ?? progress[0].data;
    assert.equal(runtime.vehicles.find((v: any) => v.handle === requester).etaSeconds, 120);
  }
  assert.deepEqual(events.get("third"), []);
  const revision = response.json().runtime.runtimeRevision;
  assert.equal((await api(requester, "follow-plans/leader/guidance-status", input)).json().runtime.runtimeRevision, revision);
  for (const method of ["plan", "positions"]) {
    const snapshot = (await api("follower", method === "plan" ? "follow-plans/leader" : "positions", undefined, "GET")).json();
    const runtime = method === "plan" ? snapshot.runtime : snapshot.followPlans[0].runtime;
    assert.equal(runtime.vehicles.find((v: any) => v.handle === requester).etaSeconds, 120);
  }
  assert.equal((await api("third", "follow-plans/leader/guidance-status", input)).statusCode, 403);
  const staleDevice = await api(requester, "follow-plans/leader/guidance-status", input, "PUT", "a".repeat(32));
  assert.equal(staleDevice.json().error.code, "NOT_ACTIVE_SENDER");
});
test("schema 1 to schema 2 scopes generations separately and pins inputs across the shared 30-second budget", async (t) => {
  const f = planFixture(t); const service = new FollowRouteService(f.locations, { ...f.routeOptions, plans: f.plans }); t.after(() => service.close());
  await service.calculate(f.room.code, "follower", f.request({ guidanceGeneration: 100 }), () => "leader");
  f.enroll(f.save()); const input = route(f, "planJoin", "follower");
  await assert.rejects(service.calculate(f.room.code, "follower", input, () => "leader"), (e: unknown) =>
    e instanceof RouteError && e.code === "RATE_LIMITED" && e.inputExpiresAtMs === f.now() + 120_000);
  for (let i = 0; i < 30; i++) f.step();
  const result = await service.calculate(f.room.code, "follower", { ...input, requestId: "after-budget" }, () => "leader");
  assert.deepEqual(result.requestedAnchor, at(100)); assert.equal(result.schemaVersion, 2); assert.equal(f.calls.length, 2);
});
test("in-process SSE: authorized snapshots, state-only events, empty restart and old-device writes", async (t) => {
  const f = planFixture(t); f.plans.close(); const app = createApp({ ...f, routeOptions: f.routeOptions });
  const api = (handle: string, path: string, body?: unknown, method = "POST", device?: string) =>
    dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/ABC234/${path}`, method, device }).done;
  const events = new Map<string, { name: string; data: any }[]>();
  for (const h of ["leader", "follower", "third"]) {
    events.set(h, []); const hash = tokenHash(f.tokens.get(h)!);
    const off = f.hub.subscribe(f.room.code, h, hash, (name, data) => { events.get(h)!.push({ name, data }); }); t.after(off);
  }
  const saved = (await api("leader", "follow-plans/self", { operationId: "save", expectedPlanId: null, expectedRevision: 0,
    destination: pin(1000), joinPoint: pin(100), policy: "wait", participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true }, "PUT")).json();
  assert.ok(events.get("leader")!.some((e) => e.name === "follow-plan-updated"));
  assert.ok(events.get("follower")!.some((e) => e.name === "follow-plan-updated"));
  assert.ok(!events.get("third")!.some((e) => e.name === "follow-plan-updated"));
  await api("follower", "follow-plans/leader/participation", { operationId: "enroll", planId: saved.plan.planId,
    planRevision: 1, followRequestId: f.relation.requestId, enabled: true }, "PUT");
  const readHello = () => {
    const stream = dispatch(app, f.tokens.get("follower")!, undefined, { path: "/v1/rooms/ABC234/events?resume=1", method: "GET" });
    const frame = Buffer.concat(stream.response.chunks).toString();
    const hello = JSON.parse(frame.split("\n").find((line) => line.startsWith("data: "))!.slice(6));
    stream.response.destroy(); return hello;
  };
  const first = readHello(); const second = readHello();
  assert.deepEqual(first.followPlans, second.followPlans); assert.equal(first.followPlans[0].runtime.enrollments.length, 1);
  assert.equal(first.meetingPlan.enabled, true); assert.equal(first.geocoding.enabled, false);
  const currentHash = tokenHash(f.tokens.get("leader")!); f.hub.claim(f.room.code, "leader", `${currentHash}:${"a".repeat(32)}`, currentHash);
  const removed = (await api("leader", "follow-plans/self", { operationId: "delete", planId: saved.plan.planId, expectedRevision: 1 }, "DELETE")).json();
  assert.equal(removed.error.code, "NOT_ACTIVE_SENDER");
  assert.deepEqual(readHello().followPlans, []);
  const freshStore = new RoomLocationStore(f.now), freshHub = new RoomEventHub();
  const restarted = createApp({ db: f.db, hub: freshHub, locations: freshStore, routeOptions: f.routeOptions });
  t.after(() => freshHub.close());
  const stream = dispatch(restarted, f.tokens.get("follower")!, undefined, { path: "/v1/rooms/ABC234/events?resume=1", method: "GET" });
  const frame = Buffer.concat(stream.response.chunks).toString();
  const hello = JSON.parse(frame.split("\n").find((line) => line.startsWith("data: "))!.slice(6));
  assert.deepEqual(hello.followPlans, []); assert.equal(hello.followTarget, null);
  stream.response.destroy();
});
