import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { tokenHash } from "../../src/auth.ts";
import { at, pin, planFixture } from "../helpers/plan_fixture.ts";
import { naverConfig } from "../helpers/route_fixture.ts";

async function fixture(t: TestContext, searchEnabled = false) {
  const f = planFixture(t); f.plans.close();
  const server = createServer(createApp({ ...f, routeOptions: f.routeOptions, geocodingOptions: {
    config: () => searchEnabled ? naverConfig : { provider: "disabled" }, provider: async () => [],
  } }));
  t.after(async () => { await new Promise<void>((resolve) => { server.close(() => resolve()); server.closeAllConnections(); }); });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject); server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve(); });
  });
  const address = server.address(); assert.ok(address && typeof address !== "string");
  const base = `http://127.0.0.1:${address.port}/v1/rooms/ABC234/`;
  async function api(path: string, body?: unknown, method = "POST", handle = "leader") {
    const response = await fetch(base + path, { method, signal: AbortSignal.timeout(5000), headers: {
      authorization: `Bearer ${f.tokens.get(handle)}`, "content-type": "application/json",
    }, ...(method === "GET" ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, headers: response.headers, body: await response.json() as any };
  }
  async function plan(policy = "wait", join = 100, destination = 1000) {
    const saved = await api("follow-plans/self", { operationId: "manual-plan", expectedPlanId: null, expectedRevision: 0,
      destination: pin(destination), joinPoint: pin(join), policy, participantFollowRequestIds: [f.relation.requestId], waitingPlaceConfirmed: true }, "PUT");
    assert.equal(saved.status, 200); assert.equal(saved.headers.get("cache-control"), "no-store");
    const p = saved.body.plan;
    const enrollment = await api("follow-plans/leader/participation", { operationId: "enroll", planId: p.planId,
      planRevision: p.revision, followRequestId: f.relation.requestId, enabled: true }, "PUT", "follower");
    assert.equal(enrollment.status, 200); return p;
  }
  function route(p: any, kind: string, handle: string) {
    const fix = f.locations.position(f.room.code, handle)!;
    return { schemaVersion: 2, planId: p.planId, planRevision: p.revision, followRequestId: handle === "leader" ? null : f.relation.requestId,
      guidanceGeneration: kind === "planJoin" ? 1 : 2, calculationId: kind, requestId: kind,
      routeKind: kind, originRef: { stream: fix.stream, seq: fix.seq }, anchor: { kind: kind === "planJoin" ? "joinPoint" : "destination" } };
  }
  return { ...f, server, base, api, plan, route };
}
test("HTTP wait contract: enrollment, both J routes, ready versus departure, and owner D route", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t); const p = await f.plan();
  for (const h of ["leader", "follower"]) {
    const reply = await f.api("follow-route", f.route(p, "planJoin", h), "POST", h);
    assert.equal(reply.status, 200); assert.deepEqual(reply.body.requestedAnchor, at(100));
    assert.equal(reply.body.schemaVersion, 2); assert.equal(reply.body.mode, undefined);
  }
  f.rest({ leader: 100, follower: 100 });
  const current = (await f.api("follow-plans/leader", undefined, "GET")).body;
  const prepared = await f.api("follow-plans/self/depart", { operationId: "depart", planId: p.planId, planRevision: p.revision,
    expectedRuntimeRevision: current.runtime.runtimeRevision });
  assert.equal(prepared.status, 200); assert.equal(prepared.body.runtime.traceStartRef, null);
  for (const m of [120, 140, 160]) f.step({ leader: m, follower: m - 5 }, 20);
  for (let i = 0; i < 30; i++) f.step();
  const result = await f.api("follow-route", f.route(p, "planDestination", "leader"));
  assert.equal(result.status, 200); assert.deepEqual(result.body.requestedOrigin, at(160)); assert.deepEqual(result.body.requestedAnchor, at(1000));
  const snapshot = (await f.api("follow-plans/leader", undefined, "GET")).body;
  assert.equal(snapshot.runtime.phase, "departed"); assert.equal(snapshot.plan.revision, 1);
  assert.equal(snapshot.runtime.vehicles.find((v: any) => v.handle === "follower").branch, "trace");
});
test("HTTP proceed contract: follower first gets a sticky D branch and latest origin", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t); const p = await f.plan("proceed");
  const pass = async (h: string) => {
    const ownRefs = f.locations.recentSamples(f.room.code, h).slice(-3).map(({ stream, seq }) => ({ stream, seq }));
    return f.api(`follow-plans/leader/pass-evidence`, { requestId: `pass-${h}`, planId: p.planId, revision: p.revision,
      followRequestId: h === "leader" ? null : f.relation.requestId, ownRefs, pointKind: "joinPoint" }, "POST", h);
  };
  for (const m of [70, 100, 130]) f.step({ follower: m }, 30);
  assert.equal((await pass("follower")).status, 200); f.step(); f.step();
  const result = await f.api("follow-route", f.route(p, "planDestination", "follower"), "POST", "follower");
  assert.equal(result.status, 200); assert.deepEqual(result.body.requestedOrigin, at(130));
  for (const m of [70, 100, 130]) f.step({ leader: m }, 30);
  const later = await pass("leader"); assert.equal(later.status, 200);
  assert.equal(later.body.runtime.vehicles.find((v: any) => v.handle === "follower").branch, "destination");
});
test("HTTP recommendations and addresses: unsaved draft, real call count, independent capability and preview identity", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t, true);
  const result = await f.api("follow-plans/self/recommend", { requestId: "recommend", draftGeneration: 9,
    planId: null, expectedRevision: 0, destination: pin(1000), participantFollowRequestIds: [f.relation.requestId] });
  assert.equal(result.status, 200); assert.equal(result.body.draftGeneration, 9); assert.equal(result.body.requestId, "recommend");
  assert.equal(result.body.expiresAtMs - result.body.calculatedAtMs, 60_000); assert.equal(f.calls.length, 2);
  assert.equal((await f.api("follow-plans/self", undefined, "GET")).body.plan, null);
  const address = await f.api("geocoding", { requestId: "search", query: "인위적 주소 1" });
  assert.equal(address.status, 200); assert.deepEqual(address.body.results, []); assert.equal(address.headers.get("cache-control"), "no-store");
  const snapshot = (await f.api("positions", undefined, "GET")).body;
  assert.equal(snapshot.geocoding.enabled, true); assert.equal(snapshot.meetingRecommendation.enabled, true);
});
test("HTTP/SSE snapshots are group scoped; resume preserves runtime and clearing does not restart following", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t); const deliveries = new Map<string, { name: string; data: any }[]>();
  for (const h of ["leader", "follower", "third"]) {
    deliveries.set(h, []); const hash = tokenHash(f.tokens.get(h)!);
    const off = f.hub.subscribe(f.room.code, h, hash, (name, data) => { deliveries.get(h)!.push({ name, data }); }); t.after(off);
  }
  const p = await f.plan();
  assert.ok(deliveries.get("leader")!.some((e) => e.name === "follow-plan-updated"));
  assert.ok(deliveries.get("follower")!.some((e) => e.name === "follow-plan-progress"));
  assert.ok(!deliveries.get("third")!.some((e) => e.name.startsWith("follow-plan")));
  assert.equal((await f.api("positions", undefined, "GET", "third")).body.followPlans.length, 0);
  const controller = new AbortController(); t.after(() => controller.abort());
  const stream = await fetch(f.base + "events?resume=1", { signal: controller.signal,
    headers: { authorization: `Bearer ${f.tokens.get("follower")}` } });
  const first = await stream.body!.getReader().read(); const frame = new TextDecoder().decode(first.value);
  const hello = JSON.parse(frame.split("\n").find((line) => line.startsWith("data: "))!.slice(6));
  assert.equal(hello.followPlans[0].plan.planId, p.planId); assert.equal(hello.followPlans[0].runtime.enrollments.length, 1);
  assert.equal(hello.geocoding.enabled, false); controller.abort();
  const deleted = await f.api("follow-plans/self", { operationId: "cancel", planId: p.planId, expectedRevision: 1 }, "DELETE");
  assert.equal(deleted.status, 200); assert.equal(f.locations.targetOf(f.room.code, "follower"), "leader");
  assert.equal((await f.api("positions", undefined, "GET", "follower")).body.followPlans.length, 0);
  assert.ok(deliveries.get("follower")!.some((e) => e.name === "follow-plan-cleared"));
});
