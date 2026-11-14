import assert from "node:assert/strict";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { FollowRouteService } from "../../src/routes.ts";
import { distance, RouteError } from "../../src/route_contract.ts";
import type { Point } from "../../src/route_contract.ts";
import { naverProvider, parseNaverRoute } from "../../src/route_providers/naver.ts";
import { projectTraceRejoinEndpoint } from "../../src/trace_rejoin.ts";
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
    [-.01, 0, 0, false], [80, 25.01, 0, false], [80, 0, 60, true],
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
