import type { TestContext } from "node:test";
import { FollowPlanService } from "../../src/follow_plans.ts";
import type { FollowPlan, PlanSnapshot } from "../../src/follow_plan_contract.ts";
import type { LocationFix } from "../../src/locations.ts";
import { routeFixture } from "./route_fixture.ts";

// Synthetic straight road; these coordinates are not captured provider data.
export function at(meters: number, east = 0) { return { lat: 37.5 + meters / 111195, lng: 127 + east / 88217 }; }
export function pin(meters: number) { return { ...at(meters), label: "시험 지점", source: "map" as const }; }
export function planFixture(t: TestContext) {
  const f = routeFixture(t);
  const revoked = new Set<string>();
  const plans = new FollowPlanService(f.locations, { now: f.now, monotonicNow: f.now, eligible: (_code, h) => !revoked.has(h) });
  t.after(() => plans.close());
  let op = 0;
  const positions = new Map<string, number>([["leader", 0], ["follower", 0]]);
  function step(changes: Record<string, number> = {}, speed = 0, overrides: Partial<LocationFix> = {}) {
    for (const [h, m] of Object.entries(changes)) positions.set(h, m);
    f.elapse(1000);
    for (const [h, m] of positions) f.publish(h, { ...at(m), speed, ...overrides });
  }
  function rest(changes: Record<string, number> = {}, overrides: Partial<LocationFix> = {}) {
    for (let i = 0; i < 3; i++) step(changes, 0, overrides);
  }
  rest();
  const save = (policy: "wait" | "proceed" = "wait", join = 100, destination = 1000, leader = "leader", ids = [f.relation.requestId]) =>
    plans.save(f.room.code, leader, { operationId: `save-${++op}`, expectedPlanId: null, expectedRevision: 0,
      destination: pin(destination), joinPoint: pin(join), policy, participantFollowRequestIds: ids, waitingPlaceConfirmed: true });
  function enroll(snapshot: PlanSnapshot, handle = "follower", enabled = true) {
    const plan = snapshot.plan!;
    return plans.participate(f.room.code, plan.leaderHandle, handle, { operationId: `enroll-${++op}`, planId: plan.planId,
      planRevision: plan.revision, followRequestId: f.locations.relationOf(f.room.code, handle)!.requestId, enabled });
  }
  function get(leader = "leader") { return plans.get(f.room.code, leader, leader); }
  function pass(plan: FollowPlan, handle: string, pointKind = "joinPoint") {
    return plans.pass(f.room.code, plan.leaderHandle, handle, { requestId: `pass-${++op}`, planId: plan.planId, revision: plan.revision,
      followRequestId: handle === plan.leaderHandle ? null : f.locations.relationOf(f.room.code, handle)!.requestId,
      pointKind, ownRefs: f.locations.recentSamples(f.room.code, handle).slice(-3).map(({ stream, seq }) => ({ stream, seq })) });
  }
  return { ...f, plans, revoked, step, rest, save, enroll, get, pass, positions };
}
