import assert from "node:assert/strict";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { FollowRouteService } from "../../src/routes.ts";
import { distance, RouteError } from "../../src/route_contract.ts";
import type { Point, ProviderRoute } from "../../src/route_contract.ts";
import { naverProvider, parseNaverRoute } from "../../src/route_providers/naver.ts";
import { RejoinEndpointError } from "../../src/trace_rejoin.ts";
import { at } from "../helpers/plan_fixture.ts";
import { naverBody, routeFixture } from "../helpers/route_fixture.ts";

function fixture(t: TestContext) {
  const f = routeFixture(t); f.elapse(2000); f.publish("leader", { ...at(0) });
  const fixes = [];
  for (let m = 20; m <= 600; m += 20) { f.elapse(1000); fixes.push(f.publish("leader", { ...at(m) })); }
  const start = fixes[9], next = fixes[10];
  const self = f.publish("follower", { ...at(200, 200) });
  const request = f.request({ mode: "B", anchor: { kind: "segment",
    startRef: { stream: start.stream, seq: start.seq }, endRef: { stream: next.stream, seq: next.seq }, fraction: 0 } });
  const service = new FollowRouteService(f.locations, f.routeOptions); t.after(() => service.close());
  const lines: string[] = [];
  const write = process.stdout.write.bind(process.stdout);
  t.mock.method(process.stdout, "write", (value: string | Uint8Array) => {
    if (typeof value === "string" && value.startsWith("follow-rejoin-rejected ")) { lines.push(value); return true; }
    return write(value);
  });
  const providerResult = (actualEnd: Point, pathEnd = actualEnd, before = at(240, 35)): ProviderRoute => ({
    result: "route", provider: "naver", routeOption: "traoptimal", points: [self, before, pathEnd],
    meters: distance(self, before) + distance(before, pathEnd), seconds: 12,
    actualStart: self, actualEnd, startGapMeters: 0, endGapMeters: distance(at(200), actualEnd),
  });
  return { ...f, self, request, lines, providerResult,
    run: () => service.calculate(f.room.code, "follower", request, () => "leader") };
}

for (const point of ["actualEnd", "pathEnd"] as const) {
  test(`R19.4 ${point} rejection emits one numeric-only diagnostic`, async (t) => {
    const f = fixture(t);
    f.setProvider(async () => f.providerResult(point === "actualEnd" ? at(280, 35) : at(280), at(280, 35)));
    await assert.rejects(f.run(), (e: unknown) => {
      assert.ok(e instanceof RouteError);
      assert.equal(e.code, "ENDPOINT_MISMATCH");
      assert.deepEqual(Object.keys(e.body(f.request).error).sort(), ["code", "retryAfterMs", "retryable"]);
      assert.doesNotMatch(JSON.stringify(e.body(f.request)), /trace_m|diagnostic|traceLength/);
      return true;
    });
    assert.equal(f.lines.length, 1);
    assert.match(f.lines[0], new RegExp(`^follow-rejoin-rejected point=${point} condition=trace_distance `));
    assert.match(f.lines[0], /trace_m=35\.0 forward_m=\+80\.0 angle_deg=0\.0 target_m=87\.3 /);
    assert.match(f.lines[0], /ambiguous_segments=0 trace_points=32 trace_length_m=711\.2\n$/);
    assert.doesNotMatch(f.lines[0], /\blat\b|\blng\b|\bhandle\b|\baddress\b|leader|follower|ABC234|127\./);
  });
}

test("R19.4 a Naver parser endpoint rejection reaches the same diagnostic log", async (t) => {
  const f = fixture(t);
  f.setProvider(naverProvider(async () => {
    const end = at(210, 5), before = at(250, 5);
    const body = naverBody(f.self, end);
    body.route.traoptimal[0].path = [f.self, before, end].map((p) => [p.lng, p.lat]);
    body.route.traoptimal[0].summary.distance = Math.ceil(distance(f.self, before) + distance(before, end));
    return Response.json(body);
  }));
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /point=actualEnd condition=arrival_direction /);
  assert.match(f.lines[0], /forward_m=\+10\.0 angle_deg=180\.0 /);
  assert.doesNotMatch(f.lines[0], /\blat\b|\blng\b|leader|follower|ABC234|127\./);
});

test("R19.4 an accepted endpoint emits no rejection diagnostic", async (t) => {
  const f = fixture(t);
  f.setProvider(async () => f.providerResult(at(280, 5), at(280, 5), at(240, 5)));
  assert.equal((await f.run()).result, "route");
  assert.deepEqual(f.lines, []);
});

for (const [meters, offset, condition, signed] of [[190, 24, "before_minimum", "-10.0"], [330, 0, "after_maximum", "+130.0"]] as const) {
  test(`R19.4 ${condition} preserves the signed forward distance`, async (t) => {
    const f = fixture(t);
    // The lower-bound case remains outside the target's 25 m radius (26 m).
    f.setProvider(async () => f.providerResult(at(meters, offset), at(meters, offset), at(meters - 40, offset)));
    await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
    assert.equal(f.lines.length, 1);
    assert.ok(f.lines[0].includes(`condition=${condition} `));
    assert.ok(f.lines[0].includes(`forward_m=${signed} `));
  });
}

test("R19.4 ambiguity reports competing projections rather than every trace segment", async (t) => {
  const f = fixture(t);
  f.elapse(5000); f.publish("leader", { ...at(280) });
  f.setProvider(async () => f.providerResult(at(280), at(280), at(240)));
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /condition=ambiguous /);
  assert.match(f.lines[0], /ambiguous_segments=1 trace_points=33 trace_length_m=1031\.2/);
});

test("R19b.3 the ambiguity key names segments and retains the existing segment count", async (t) => {
  const f = fixture(t);
  f.elapse(5000); f.publish("leader", { ...at(280) });
  f.elapse(1000); f.publish("leader", { ...at(260) });
  f.setProvider(async () => f.providerResult(at(280), at(280), at(240)));
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /condition=ambiguous /);
  // One later visit contributes both adjacent segments at their shared point.
  assert.match(f.lines[0], /ambiguous_segments=2 trace_points=34 trace_length_m=1051\.2/);
  assert.doesNotMatch(f.lines[0], /ambiguous_candidates|\blat\b|\blng\b|leader|follower|ABC234|127\./);
});

test("R19.4 missing endpoint metadata logs unavailable metrics without coordinates", async (t) => {
  const f = fixture(t);
  f.setProvider(async () => ({ ...f.providerResult(at(280)), actualEnd: null }));
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /point=actualEnd condition=missing_point trace_m=na forward_m=na angle_deg=na target_m=na /);
  assert.doesNotMatch(f.lines[0], /\blat\b|\blng\b|leader|follower|ABC234|127\./);
});

test("R19.4 diagnostics measure the pinned trace, not continuous points added while waiting", async (t) => {
  const f = fixture(t);
  const pending = Promise.withResolvers<ProviderRoute>(); f.setProvider(() => pending.promise);
  const started = f.nextCall(); const run = f.run();
  const rejected = assert.rejects(run, (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  await started;
  f.elapse(1000); f.publish("leader", { ...at(620) });
  pending.resolve(f.providerResult(at(280, 35)));
  await rejected;
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /trace_points=32 trace_length_m=711\.2/);
});

test("R19.4 a rejected provider summary endpoint is identified separately", async (t) => {
  const f = fixture(t);
  f.setProvider(naverProvider(async () => {
    const end = at(280), before = at(240), summaryEnd = at(280, 35);
    const body = naverBody(f.self, end);
    body.route.traoptimal[0].summary.goal.location = [summaryEnd.lng, summaryEnd.lat];
    body.route.traoptimal[0].path = [f.self, before, end].map((p) => [p.lng, p.lat]);
    body.route.traoptimal[0].summary.distance = Math.ceil(distance(f.self, before) + distance(before, end));
    return Response.json(body);
  }));
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "ENDPOINT_MISMATCH");
  assert.equal(f.lines.length, 1);
  assert.match(f.lines[0], /point=summaryEnd condition=trace_distance /);
});

for (const changed of ["trace", "configuration"] as const) {
  test(`R19b.1 a later ${changed} failure cannot erase the endpoint diagnostic`, async (t) => {
    const f = fixture(t);
    const pending = Promise.withResolvers<Response>();
    f.setProvider(naverProvider(() => pending.promise));
    const started = f.nextCall(); const run = f.run();
    const rejected = assert.rejects(run, (e: unknown) => e instanceof RouteError
      && e.code === (changed === "trace" ? "TRACE_DISCONTINUITY" : "ROUTING_DISABLED"));
    await started;
    if (changed === "trace") { f.elapse(1000); f.publish("leader", { ...at(1200) }); }
    else f.setConfig({ provider: "disabled" });
    const end = at(280, 35), before = at(240, 35);
    const body = naverBody(f.self, end);
    body.route.traoptimal[0].path = [f.self, before, end].map((p) => [p.lng, p.lat]);
    body.route.traoptimal[0].summary.distance = Math.ceil(distance(f.self, before) + distance(before, end));
    pending.resolve(Response.json(body));
    await rejected;
    assert.equal(f.lines.length, 1);
    assert.match(f.lines[0], /point=actualEnd condition=trace_distance /);
    assert.doesNotMatch(f.lines[0], /\blat\b|\blng\b|leader|follower|ABC234|127\./);
  });
}

const gapCases = [
  ["summaryStart", "summary_start_gap", 30, 25, undefined],
  ["summaryEnd", "summary_end_gap", 200, 145, undefined],
  ["actualStart", "start_gap", 30, 25, undefined],
  ["actualEnd", "end_gap", 200, 145, undefined],
  ["zeroRoutePoint", "zero_route_point", 200, 25, "origin"],
  ["zeroRoutePoint", "zero_route_point", 200, 25, "anchor"],
] as const;

for (const [point, condition, meters, limit, reference] of gapCases) {
  test(`R19b.2 ${point}/${reference ?? condition} gap rejection has one safe diagnostic`, async (t) => {
    const f = fixture(t);
    const goal = at(200), end = at(280);
    const body = naverBody(f.self, end);
    const r = body.route.traoptimal[0];
    let points: Point[] = [f.self, at(240), end];
    r.summary.goal.location = [goal.lng, goal.lat];
    if (point === "summaryStart") r.summary.start.location = [at(200, 230).lng, at(200, 230).lat];
    if (point === "summaryEnd") r.summary.goal.location = [at(400).lng, at(400).lat];
    if (point === "actualStart") points = [at(200, 230), at(240), end];
    if (point === "actualEnd") points = [f.self, at(360), at(400)];
    if (point === "zeroRoutePoint") {
      points = reference === "origin" ? [goal, at(210)] : [f.self, at(210, 200)];
      r.summary.distance = 0; r.summary.duration = 0;
    } else r.summary.distance = Math.ceil(points.slice(1).reduce((sum, p, i) => sum + distance(points[i], p), 0));
    r.path = points.map((p) => [p.lng, p.lat]);
    f.setProvider(naverProvider(async () => Response.json(body)));
    await assert.rejects(f.run(), (e: unknown) => {
      assert.ok(e instanceof RouteError); assert.equal(e.code, "ENDPOINT_MISMATCH");
      assert.deepEqual(Object.keys(e.body(f.request).error).sort(), ["code", "retryAfterMs", "retryable"]);
      assert.doesNotMatch(JSON.stringify(e.body(f.request)), /diagnostic|distanceMeters|limitMeters/);
      return true;
    });
    assert.equal(f.lines.length, 1);
    assert.ok(f.lines[0].startsWith(`follow-rejoin-rejected point=${point} condition=${condition} `));
    assert.ok(f.lines[0].includes(`distance_m=${meters.toFixed(1)} limit_m=${limit.toFixed(1)}`));
    if (reference) assert.ok(f.lines[0].includes(`reference=${reference}`));
    assert.doesNotMatch(f.lines[0], /\blat\b|\blng\b|\baddress\b|\bhandle\b|leader|follower|ABC234|127\./);

    for (const endpoint of ["reference", "destination"] as const) {
      assert.throws(() => parseNaverRoute(body, f.self, goal, endpoint), (e: unknown) =>
        e instanceof RouteError && !(e instanceof RejoinEndpointError) && e.code === "ENDPOINT_MISMATCH");
    }
    assert.equal(f.lines.length, 1, "ordinary point routes do not add diagnostic logs");
  });
}
