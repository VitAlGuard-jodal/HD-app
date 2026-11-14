import assert from "node:assert/strict";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { FollowRouteService } from "../../src/routes.ts";
import { distance, RouteError } from "../../src/route_contract.ts";
import type { Point } from "../../src/route_contract.ts";
import { naverProvider, parseNaverRoute } from "../../src/route_providers/naver.ts";
import { projectTraceRejoinEndpoint, RejoinEndpointError, validateTraceRejoinEndpoint } from "../../src/trace_rejoin.ts";
import { naverBody } from "../helpers/route_fixture.ts";
import { at, planFixture } from "../helpers/plan_fixture.ts";

function fixture(t: TestContext, schema: 1 | 2, end: Point, before: Point) {
  const f = planFixture(t); const saved = f.save("proceed"); f.enroll(saved);
  for (const m of [70, 100, 130]) f.step({ leader: m }, 30); f.pass(saved.plan!, "leader");
  for (const m of [70, 100, 130]) f.step({ follower: m }, 30); f.pass(saved.plan!, "follower");
  for (let m = 180; m <= 600; m += 20) f.step({ leader: m }, 20);
  const trail = f.locations.trail(f.room.code, "leader");
  const start = trail.find((s) => distance(s, at(200)) < .01)!;
  const next = trail.find((s) => s.seq === start.seq + 1)!;
  const anchor = { kind: "segment" as const, startRef: { stream: start.stream, seq: start.seq },
    endRef: { stream: next.stream, seq: next.seq }, fraction: 0 };
  f.elapse(5000); f.publish("leader", { ...at(600), speed: 0 });
  const self = f.publish("follower", { ...at(200, 200), speed: 0 });
  f.setProvider(naverProvider(async () => {
    const shape = [self, before, end];
    const body = naverBody(self, end);
    body.route.traoptimal[0].path = shape.map((p) => [p.lng, p.lat]);
    body.route.traoptimal[0].summary.distance = Math.ceil(shape.slice(1).reduce((n, p, i) => n + distance(shape[i], p), 0));
    return Response.json(body);
  }));
  const service = new FollowRouteService(f.locations, { ...f.routeOptions, plans: f.plans });
  t.after(() => service.close());
  const request = schema === 1 ? f.request({ mode: "B", anchor }) : {
    schemaVersion: 2, planId: saved.plan!.planId, planRevision: 1, followRequestId: f.relation.requestId,
    guidanceGeneration: 1, calculationId: "rejoin", requestId: "rejoin", routeKind: "traceRejoin",
    originRef: { stream: self.stream, seq: self.seq }, anchor,
  };
  return { ...f, request, run: () => service.calculate(f.room.code, "follower", request, () => "leader") };
}

const r20Scale = 6371000 * Math.PI / 180;
const r20Point = (x: number, y = 0): Point => ({ lat: y / r20Scale, lng: x / r20Scale });

test("R20b the opposite U-turn leg 215 m behind is rejected by the lower bound", () => {
  const target = { kind: "traceRejoin" as const,
    points: [r20Point(0), r20Point(200), r20Point(200, 15), r20Point(0, 15)],
    minimum: 315, anchor: r20Point(100, 15) };
  const end = r20Point(100, 2), route = [r20Point(60, 2), end];
  assert.throws(() => validateTraceRejoinEndpoint(end, route, target, "actualEnd"), (e: unknown) => {
    assert.ok(e instanceof RejoinEndpointError);
    assert.equal(e.diagnostic.condition, "before_minimum");
    assert.ok("forwardMeters" in e.diagnostic);
    assert.ok(Math.abs(e.diagnostic.forwardMeters! + 215) < .000001);
    assert.ok(Math.abs(e.diagnostic.targetDistanceMeters! - 13) < .000001);
    assert.ok(Math.abs(e.diagnostic.directionDifferenceDegrees!) < .000001);
    return true;
  });
  const sameLeg = r20Point(108, 15);
  const accepted = projectTraceRejoinEndpoint(sameLeg, [r20Point(148, 15), sameLeg], target)!;
  assert.ok(accepted);
  assert.ok(Math.abs(accepted.along - target.minimum + 8) < .000001);
  assert.ok(Math.abs(accepted.bearing - 270) < .000001);
});

for (const [behind, allowed] of [[8, true], [10, true], [10.01, false], [15, false]] as const) {
  test(`R20b a near endpoint ${behind} m behind has the bounded acceptance ${allowed}`, () => {
    const target = { kind: "traceRejoin" as const, points: [r20Point(0), r20Point(400)], minimum: 100, anchor: r20Point(100) };
    const end = r20Point(100 - behind, 5.7), route = [r20Point(60 - behind, 5.7), end];
    assert.ok(distance(end, target.anchor) < 25);
    assert.equal(projectTraceRejoinEndpoint(end, route, target) !== null, allowed);
    if (!allowed) assert.throws(() => validateTraceRejoinEndpoint(end, route, target, "actualEnd"), (e: unknown) =>
      e instanceof RejoinEndpointError && e.diagnostic.condition === "before_minimum");
  });
}

test("R20 an endpoint 5.7 m beside the target may project 0.001 m behind minimum", () => {
  const target = { kind: "traceRejoin" as const, points: [r20Point(0), r20Point(400)], minimum: 100, anchor: r20Point(100) };
  const end = r20Point(99.999, 5.7);
  const before = r20Point(59.999, 5.7 - 40 * Math.tan(1.4 * Math.PI / 180));
  assert.doesNotThrow(() => validateTraceRejoinEndpoint(end, [before, end], target, "actualEnd"));
  const p = projectTraceRejoinEndpoint(end, [before, end], target)!;
  assert.ok(Math.abs(p.along - target.minimum + .001) < .000001);
  assert.ok(Math.abs(p.gap - 5.7) < .000001);
});

test("R20 an endpoint 30 m from the target and 10 m behind still fails before_minimum", () => {
  const target = { kind: "traceRejoin" as const, points: [r20Point(0), r20Point(400)], minimum: 10, anchor: r20Point(10) };
  // A projection onto the trace's start is 20 m from this endpoint; the target
  // is another 10 m ahead, so the point is outside the existing 25 m radius.
  const end = r20Point(-20), route = [r20Point(-40), end];
  assert.throws(() => validateTraceRejoinEndpoint(end, route, target, "actualEnd"), (e: unknown) => {
    assert.ok(e instanceof RejoinEndpointError);
    assert.equal(e.diagnostic.condition, "before_minimum");
    assert.ok("forwardMeters" in e.diagnostic);
    assert.ok(Math.abs(e.diagnostic.forwardMeters! + 10) < .000001);
    assert.ok(Math.abs(e.diagnostic.targetDistanceMeters! - 30) < .000001);
    return true;
  });
});

test("R20 an opposite endpoint inside 25 m stays rejected even behind minimum", () => {
  const target = { kind: "traceRejoin" as const, points: [r20Point(0), r20Point(400)], minimum: 100, anchor: r20Point(100) };
  const end = r20Point(99.999, 5.7), route = [r20Point(139.999, 5.7), end];
  assert.equal(projectTraceRejoinEndpoint(end, route, target), null);
  assert.throws(() => validateTraceRejoinEndpoint(end, route, target, "actualEnd"), (e: unknown) =>
    e instanceof RejoinEndpointError && e.diagnostic.condition === "arrival_direction");
});

test("R20 the near-target radius does not bypass the upper bound or ambiguity", () => {
  const upper = { kind: "traceRejoin" as const, minimum: 50, anchor: r20Point(50, 20),
    points: [r20Point(0, 20), r20Point(100, 20), r20Point(100, 100), r20Point(0, 100), r20Point(0), r20Point(100)] };
  const ambiguous = { kind: "traceRejoin" as const, minimum: 50, anchor: r20Point(50),
    points: [r20Point(0), r20Point(100), r20Point(100, 100), r20Point(0, 100), r20Point(0, 4), r20Point(100, 4)] };
  const end = r20Point(50), route = [r20Point(30), end];
  for (const [target, condition] of [[upper, "after_maximum"], [ambiguous, "ambiguous"]] as const) {
    assert.ok(distance(end, target.anchor) <= 25);
    assert.throws(() => validateTraceRejoinEndpoint(end, route, target, "actualEnd"), (e: unknown) =>
      e instanceof RejoinEndpointError && e.diagnostic.condition === condition);
  }
});

test("R17 a curved trace validates the actual arrival without changing the requested summary goal", () => {
  const origin = at(200, 200), goal = at(200), end = at(240, 80), before = at(240, 40);
  const body = naverBody(origin, end);
  body.route.traoptimal[0].summary.goal.location = [goal.lng, goal.lat];
  body.route.traoptimal[0].path = [origin, before, end].map((p) => [p.lng, p.lat]);
  body.route.traoptimal[0].summary.distance = Math.ceil(distance(origin, before) + distance(before, end));
  const result = parseNaverRoute(body, origin, goal, { kind: "traceRejoin", minimum: 0, anchor: goal,
    points: [goal, at(240), at(240, 100)] });
  assert.deepEqual(result.actualEnd, end);
});

test("R17 trace endpoint boundaries keep 120 m forward, 25 m lateral and 60 degree heading limits", () => {
  const scale = 6371000 * Math.PI / 180;
  const p = (along: number, offset = 0) => ({ lat: offset / scale, lng: along / scale });
  const target = { kind: "traceRejoin" as const, points: [p(0), p(400)], minimum: 100, anchor: p(100) };
  for (const [advance, offset, angle, allowed] of [
    [0, 0, 0, true], [120, 25, 0, true], [120.01, 0, 0, false],
    [-.01, 0, 0, true], [-25, 0, 0, false], [-25.01, 0, 0, false],
    [80, 25.01, 0, false], [80, 0, 60, true],
    [80, 0, 60.01, false], [10, 0, 90, true], [10, 0, 120, false], [10, 0, 180, false],
  ] as const) {
    const end = p(100 + advance, offset);
    const before = p(100 + advance - 20 * Math.cos(angle * Math.PI / 180), offset - 20 * Math.sin(angle * Math.PI / 180));
    assert.equal(projectTraceRejoinEndpoint(end, [before, end], target) !== null, allowed,
      `advance=${advance}, offset=${offset}, angle=${angle}`);
  }
  const competing = { ...target, points: [p(0), p(400), p(400, 100), p(0, 100), p(0, 4), p(400, 4)] };
  assert.equal(projectTraceRejoinEndpoint(p(180, 2), [p(160, 2), p(180, 2)], competing), null);
});

for (const schema of [1, 2] as const) {
  test(`R20 schema ${schema} accepts the near-target endpoint behind the zero boundary`, async (t) => {
    const f = fixture(t, schema, at(199.999, 5.7), at(159.999, 5.7));
    const result = await f.run();
    assert.equal(result.result, "route");
    assert.deepEqual(result.anchor, f.request.anchor);
    assert.ok(distance(result.actualEnd!, result.requestedAnchor) < 25);
    assert.equal(f.calls.length, 1);
  });
  test(`R17 schema ${schema} accepts a forward endpoint on the trace beyond the target point`, async (t) => {
    const f = fixture(t, schema, at(280, 5), at(240, 5));
    const result = await f.run();
    assert.equal(result.result, "route");
    assert.deepEqual(result.anchor, f.request.anchor);
    assert.ok(distance(result.requestedAnchor, at(200)) < .01);
    assert.deepEqual(result.actualEnd, at(280, 5));
    assert.ok(result.endGapMeters! > 25);
    assert.equal(f.calls.length, 1);
  });
  test(`R17 schema ${schema} rejects an opposite arrival even inside the old 25 m circle`, async (t) => {
    const f = fixture(t, schema, at(210, 5), at(250, 5));
    await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  });
}
