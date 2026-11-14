import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { revokeToken, tokenHash } from "../../src/auth.ts";
import { FollowRouteService } from "../../src/routes.ts";
import { parseRouteRequest, RouteError, ROUTE_INPUT_TTL_MS, ROUTE_POINT_LIMIT, ROUTE_RESPONSE_LIMIT } from "../../src/route_contract.ts";
import type { FollowRouteRequest, ProviderRoute, RouteErrorCode } from "../../src/route_contract.ts";
import { naverProvider, parseNaverRoute, routeConfig } from "../../src/route_providers/naver.ts";
import { leaveRoom, updateUserConsent } from "../../src/store.ts";
import { destination, dispatch, leaderStream, naverBody, naverConfig, origin, routeFixture, selfStream } from "../helpers/route_fixture.ts";

function error(code: RouteErrorCode) { return (value: unknown) => value instanceof RouteError && value.code === code; }
function serviceFixture(t: TestContext, limits = {}) {
  const f = routeFixture(t, { limits });
  const service = new FollowRouteService(f.locations, f.routeOptions);
  t.after(() => service.close());
  const run = (input = f.request(), signal?: AbortSignal) => service.calculate(f.room.code, "follower", input, () => "leader", signal);
  return { ...f, service, run };
}
function httpFixture(t: TestContext) {
  const f = routeFixture(t);
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  const post = (input: unknown = f.request(), handle = "follower", options: Parameters<typeof dispatch>[3] = {}) =>
    dispatch(app, f.tokens.get(handle) ?? "invalid", input, options);
  return { ...f, app, post };
}

test("vehicle fixes without metre accuracy pass A routing", async (t) => {
  const f = serviceFixture(t);
  f.elapse(1000);
  f.publish("leader", { acc: undefined, src: "vehicle" });
  f.publish("follower", { acc: undefined, src: "vehicle" });
  const result = await f.run();
  assert.equal(result.result, "route");
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0].origin, origin);
  assert.deepEqual(f.calls[0].destination, destination);
});

for (const mode of ["A", "B"] as const) test(`vehicle location POST, snapshot and ${mode} route preserve the contract`, async (t) => {
  const f = httpFixture(t);
  f.elapse(1000);
  for (const handle of ["leader", "follower"]) {
    const current = f.locations.position(f.room.code, handle)!;
    const { acc: _acc, receivedAt: _receivedAt, ...sample } = current;
    const response = await f.post({ ...sample, src: "vehicle", seq: 1, at: f.now() }, handle,
      { path: `/v1/rooms/${f.room.code}/location` }).done;
    assert.equal(response.statusCode, 202);
  }
  const snapshot = (await f.post(undefined, "follower", { method: "GET", path: `/v1/rooms/${f.room.code}/positions` }).done).json();
  for (const fix of snapshot.positions) {
    assert.equal(fix.src, "vehicle");
    assert.equal(Object.hasOwn(fix, "acc"), false);
  }
  assert.equal(snapshot.trails.leader.at(-1).src, "vehicle");
  let input = f.request();
  if (mode === "B") {
    f.elapse(1000);
    f.publish("leader", { seq: 2, lat: destination.lat + .0001, acc: undefined, src: "vehicle" });
    input = f.request({ mode, anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 1 },
      endRef: { stream: leaderStream, seq: 2 }, fraction: .5 } });
  }
  const result = await f.post(input).done;
  assert.equal(result.statusCode, 200);
  assert.equal(result.json().mode, mode);
  assert.equal(f.calls.length, 1);
  // Source and assumed allowance never reach the external provider.
  assert.deepEqual(Object.keys(f.calls[0].origin).sort(), ["lat", "lng"]);
  assert.deepEqual(Object.keys(f.calls[0].destination).sort(), ["lat", "lng"]);
});

test("phone/vehicle accuracy gates agree for both current participants", async (t) => {
  for (const handle of ["leader", "follower"]) for (const src of [undefined, "vehicle"] as const) {
    for (const acc of [undefined, 0, 25, 25.01]) {
      const f = serviceFixture(t);
      f.elapse(1000);
      f.publish(handle, { src, acc });
      const allowed = acc === undefined ? src === "vehicle" : acc <= 25;
      if (allowed) assert.equal((await f.run()).result, "route");
      else await assert.rejects(f.run(), error("LOCATION_NOT_READY"));
      assert.equal(f.calls.length, allowed ? 1 : 0, `${handle} src=${src} acc=${acc}`);
    }
  }
});

test("vehicle B continuity uses 25 m only for missing accuracy and still rejects discontinuities", async (t) => {
  for (const change of [
    { meters: 119, acc: undefined, allowed: true },
    { meters: 121, acc: undefined, allowed: false },
    { meters: 96, acc: 2, allowed: true },
    { meters: 98, acc: 2, allowed: false },
    { meters: 10, acc: undefined, seq: 3, allowed: false },
    { meters: 10, acc: undefined, stream: selfStream, allowed: false },
    { meters: 10, acc: undefined, gap: 10001, allowed: false },
  ]) {
    const f = serviceFixture(t);
    f.elapse(1000);
    f.publish("leader", { acc: undefined, src: "vehicle" });
    f.elapse(change.gap ?? 1000);
    f.publish("leader", { acc: change.acc, src: "vehicle", seq: change.seq ?? 2,
      stream: change.stream ?? leaderStream, lat: destination.lat + change.meters / (6371000 * Math.PI / 180) });
    f.publish("follower", { acc: undefined, src: "vehicle" });
    const input = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 1 },
      endRef: { stream: change.stream ?? leaderStream, seq: change.seq ?? 2 }, fraction: .5 } });
    if (change.allowed) assert.equal((await f.run(input)).result, "route");
    else await assert.rejects(f.run(input), error("TRACE_DISCONTINUITY"));
    assert.equal(f.calls.length, change.allowed ? 1 : 0);
  }
});

test("vehicle source cannot bypass freshness, consent, membership, device or follow authorization", async (t) => {
  for (const blocked of ["stale", "consent", "member", "device", "follow"]) {
    const f = httpFixture(t);
    f.elapse(1000);
    f.publish("leader", { acc: undefined, src: "vehicle" });
    f.publish("follower", { acc: undefined, src: "vehicle" });
    const input = f.request();
    if (blocked === "stale") f.elapse(10001);
    if (blocked === "consent") updateUserConsent(f.db, f.users[0].id, { locationVersion: "4" });
    if (blocked === "follow") f.locations.unfollow(f.room.code, "follower");
    const result = await f.post(input, blocked === "member" ? "outsider" : "follower",
      blocked === "device" ? { device: "a".repeat(32) } : {}).done;
    assert.equal(result.json().error.code, {
      stale: "LOCATION_NOT_READY", consent: "CONSENT_REQUIRED_TARGET", member: "NOT_ROOM_MEMBER",
      device: "NOT_ACTIVE_SENDER", follow: "FOLLOW_NOT_ACTIVE",
    }[blocked]);
    assert.equal(f.calls.length, 0);
  }
});

test("valid vehicle fixes cannot repair a historical unmarked or inaccurate sample", async (t) => {
  for (const bad of [{ acc: undefined }, { acc: 26, src: "vehicle" }] as const) {
    const f = serviceFixture(t);
    f.elapse(1000);
    f.publish("leader", { acc: undefined, src: "vehicle" });
    f.elapse(1000);
    f.publish("leader", { lat: destination.lat + .0001, ...bad });
    f.elapse(1000);
    f.publish("leader", { lat: destination.lat + .0002, acc: undefined, src: "vehicle" });
    f.publish("follower", { acc: undefined, src: "vehicle" });
    const request = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 1 },
      endRef: { stream: leaderStream, seq: 2 }, fraction: .5 } });
    await assert.rejects(f.run(request), error("TRACE_DISCONTINUITY"));
    assert.equal(f.calls.length, 0);
  }
});

test("S2 Naver traoptimal normalizes lng/lat and 12,345 ms without synthetic seq", () => {
  const body = naverBody();
  body.route.traoptimal[0].path.splice(1, 0, [...body.route.traoptimal[0].path[0]]);
  const result = parseNaverRoute(body, origin, destination);
  assert.deepEqual(result, { result: "route", provider: "naver", routeOption: "traoptimal",
    points: [origin, destination], meters: 112, seconds: 12.345,
    actualStart: origin, actualEnd: destination, startGapMeters: 0, endGapMeters: 0 });
});

test("S2 provider sends only coordinates, fixed option and key headers to the fixed host", async () => {
  let calls = 0;
  const provider = naverProvider(async (url, init) => {
    calls++;
    const parsed = new URL(String(url));
    assert.equal(parsed.origin + parsed.pathname, "https://maps.apigw.ntruss.com/map-direction/v1/driving");
    assert.deepEqual([...parsed.searchParams], [["start", "127,37.5"], ["goal", "127,37.501"], ["option", "traoptimal"]]);
    assert.deepEqual(init?.headers, { "x-ncp-apigw-api-key-id": naverConfig.keyId, "x-ncp-apigw-api-key": naverConfig.key });
    assert.equal(init?.redirect, "error");
    assert.equal(init?.cache, "no-store");
    assert.ok(init?.signal);
    return Response.json(naverBody());
  });
  assert.equal((await provider(origin, destination, new AbortController().signal, naverConfig)).seconds, 12.345);
  assert.equal(calls, 1);
});

test("S3 malformed shapes, units and coordinates are rejected; long road segments remain valid", () => {
  const mutations: ((body: any) => void)[] = [
    (b) => { b.route.traoptimal = []; }, (b) => { b.route.traoptimal[0].path = []; },
    (b) => { b.route.traoptimal[0].path = [[127]]; }, (b) => { b.route.traoptimal[0].path[1] = [NaN, 37]; },
    (b) => { b.route.traoptimal[0].path[1] = [181, 37]; }, (b) => { b.route.traoptimal[0].path[1] = [37, 127]; },
    (b) => { b.route.traoptimal[0].path.splice(1, 0, null); },
    (b) => { b.route.traoptimal[0].path.splice(1, 0, [[127, 37.5], [127, 37.501]]); },
    (b) => { b.route.traoptimal[0].summary.distance = -1; }, (b) => { b.route.traoptimal[0].summary.duration = -1; },
    (b) => { b.route.traoptimal[0].summary.duration = Infinity; }, (b) => { b.route.traoptimal[0].summary.distance = 1e100; },
    (b) => { b.route.traoptimal[0].summary.distance = 1; },
    (b) => { b.route.traoptimal[0].path.splice(1, 0, [130, 36]); },
    (b) => { b.route.traoptimal[0].path = [[127, 37.5], [127, 37.5]]; },
    (b) => { b.route.traoptimal[0].summary.start.location = [127, 91]; },
  ];
  for (const mutate of mutations) {
    const body = naverBody(); mutate(body);
    assert.throws(() => parseNaverRoute(body, origin, destination), error("INVALID_PROVIDER_RESPONSE"));
  }
  const distant = { lat: 38, lng: 127 };
  assert.equal(parseNaverRoute(naverBody(origin, distant), origin, distant).points.length, 2);
  const large = naverBody(); large.route.traoptimal[0].path = Array.from({ length: ROUTE_POINT_LIMIT + 1 }, () => [127, 37.5]);
  assert.throws(() => parseNaverRoute(large, origin, destination), error("ROUTE_TOO_LARGE"));
});

test("r11 A1: only D accepts 25-100 m endpoint gaps; origins and all reference routes stay at 25 m", () => {
  for (const gap of [24.9, 25.1, 99.9, 100.1]) {
    const end = { ...destination, lat: destination.lat + gap / 111195 };
    const body = naverBody(origin, end);
    if (gap < 100) {
      const result = parseNaverRoute(body, origin, destination, "destination");
      assert.deepEqual(result.points.at(-1), end);
      assert.ok(Math.abs(result.endGapMeters! - gap) < .01);
    } else assert.throws(() => parseNaverRoute(body, origin, destination, "destination"), error("ENDPOINT_MISMATCH"));
    if (gap > 25) assert.throws(() => parseNaverRoute(body, origin, destination), error("ENDPOINT_MISMATCH"));
  }
  const shiftedStart = { ...origin, lat: origin.lat - 26 / 111195 };
  assert.throws(() => parseNaverRoute(naverBody(shiftedStart, destination), origin, destination, "destination"), error("ENDPOINT_MISMATCH"));
  for (const part of ["summary", "path"]) {
    const body = naverBody();
    const end = { ...destination, lat: destination.lat + 101 / 111195 };
    if (part === "summary") body.route.traoptimal[0].summary.goal.location = [end.lng, end.lat];
    else {
      body.route.traoptimal[0].path[1] = [end.lng, end.lat];
      body.route.traoptimal[0].summary.distance += 102;
    }
    assert.throws(() => parseNaverRoute(body, origin, destination, "destination"), error("ENDPOINT_MISMATCH"));
  }
});
test("S4 no route, same point, zero distance and true path endpoint mismatch stay distinct", () => {
  for (const code of [2, 3, 4, 5]) {
    assert.throws(() => parseNaverRoute({ code }, origin, origin), error("NO_ROUTE"));
  }
  assert.throws(() => parseNaverRoute({ code: 1 }, origin, destination), error("NO_ROUTE"));
  assert.throws(() => parseNaverRoute({ code: 9 }, origin, destination), error("INVALID_PROVIDER_RESPONSE"));
  const expected = { result: "atAnchor", provider: "naver", routeOption: "traoptimal", points: [], meters: 0, seconds: 0,
    actualStart: null, actualEnd: null, startGapMeters: null, endGapMeters: null };
  assert.deepEqual(parseNaverRoute({ code: 1 }, origin, origin), expected);
  assert.deepEqual(parseNaverRoute(naverBody(origin, origin), origin, origin), expected);
  const empty = naverBody(origin, origin); empty.route.traoptimal[0].path = [];
  assert.deepEqual(parseNaverRoute(empty, origin, origin), expected);
  const shifted = naverBody(); shifted.route.traoptimal[0].path[1] = [127, 37.5005];
  assert.throws(() => parseNaverRoute(shifted, origin, destination), error("ENDPOINT_MISMATCH"));
  const zeroFar = naverBody(origin, origin); zeroFar.route.traoptimal[0].summary.goal.location = [127, 38];
  assert.throws(() => parseNaverRoute(zeroFar, origin, origin), error("ENDPOINT_MISMATCH"));
});

test("S10 provider HTTP and body errors use sanitized route codes", async () => {
  for (const [status, code] of [[401, "PROVIDER_AUTH_FAILED"], [403, "PROVIDER_AUTH_FAILED"],
    [429, "PROVIDER_RATE_LIMITED"], [500, "PROVIDER_UNAVAILABLE"], [503, "PROVIDER_UNAVAILABLE"]] as const) {
    const provider = naverProvider(async () => new Response("secret https://example.test/?lat=37.5", { status, headers: { "retry-after": "45" } }));
    await assert.rejects(provider(origin, destination, new AbortController().signal, naverConfig), (e: unknown) => {
      assert.ok(e instanceof RouteError); assert.equal(e.code, code);
      if (status === 429) assert.equal(e.retryAfterMs, 45_000);
      assert.doesNotMatch(JSON.stringify(e.body()), /secret|example|37\.5/);
      return true;
    });
  }
  for (const status of [200, 400]) {
    const failure = naverProvider(async () => Response.json({ code: 2, message: "secret" }, { status }));
    await assert.rejects(failure(origin, destination, new AbortController().signal, naverConfig), error("NO_ROUTE"));
    const same = naverProvider(async () => Response.json({ code: 1 }, { status }));
    assert.equal((await same(origin, origin, new AbortController().signal, naverConfig)).result, "atAnchor");
  }
  const unavailable = naverProvider(async () => { throw new Error("https://secret.test/?key=secret&lat=37.5"); });
  await assert.rejects(unavailable(origin, destination, new AbortController().signal, naverConfig), error("PROVIDER_UNAVAILABLE"));
});

test("S3/S10 bounded streamed bodies, bad JSON and HTTP-date retry-after", async () => {
  for (const response of [
    new Response("x", { headers: { "content-length": String(ROUTE_RESPONSE_LIMIT + 1) } }),
    new Response("x".repeat(ROUTE_RESPONSE_LIMIT + 1)),
  ]) {
    await assert.rejects(naverProvider(async () => response)(origin, destination, new AbortController().signal, naverConfig), error("ROUTE_TOO_LARGE"));
  }
  for (const data of ["{", "null", "[]", "{}", '{"code":0}']) {
    await assert.rejects(naverProvider(async () => new Response(data))(origin, destination, new AbortController().signal, naverConfig), error("INVALID_PROVIDER_RESPONSE"));
  }
  const now = 1_800_000_000_000;
  const provider = naverProvider(async () => new Response("", { status: 429, headers: { "retry-after": new Date(now + 90_000).toUTCString() } }), () => now);
  await assert.rejects(provider(origin, destination, new AbortController().signal, naverConfig), (e: unknown) => e instanceof RouteError && e.retryAfterMs === 90_000);
});

test("S11 only explicitly configured Naver with both keys can activate", () => {
  for (const env of [{}, { ROUTE_PROVIDER: "disabled" }, { ROUTE_PROVIDER: "other" },
    { ROUTE_PROVIDER: "naver" }, { ROUTE_PROVIDER: "naver", NAVER_DIRECTIONS_KEY: "key" },
    { ROUTE_PROVIDER: "naver", NAVER_DIRECTIONS_KEY_ID: "id", NAVER_DIRECTIONS_KEY: "\n" }]) {
    assert.deepEqual(routeConfig(env), { provider: "disabled" });
  }
  assert.deepEqual(routeConfig({ ROUTE_PROVIDER: "naver", NAVER_DIRECTIONS_KEY_ID: "id", NAVER_DIRECTIONS_KEY: "key" }),
    { provider: "naver", keyId: "id", key: "key" });
});

test("S5 strict schemas reject client destinations, unsafe identifiers and invalid references", (t) => {
  const f = serviceFixture(t);
  const base = f.request();
  for (const value of [null, [], {}, { ...base, url: "https://example.test" }, { ...base, target: "outsider" },
    { ...base, requestedAnchor: destination }, { ...base, schemaVersion: 2 }, { ...base, mode: "C" },
    ...[-1, 1.2, Number.MAX_SAFE_INTEGER + 1].map((guidanceGeneration) => ({ ...base, guidanceGeneration })),
    ...["", "x".repeat(129), "secret\n"].map((requestId) => ({ ...base, requestId })),
    { ...base, originRef: { stream: 1, seq: 0 } }, { ...base, originRef: { stream: selfStream, seq: -1 } },
    ...[-.1, 1.1, NaN].map((fraction) => ({ ...base, mode: "B", anchor: {
      kind: "segment", startRef: base.originRef, endRef: base.originRef, fraction,
    } })),
  ]) assert.throws(() => parseRouteRequest(value), error("INVALID_REQUEST"));
  assert.equal(f.calls.length, 0);
});

test("S5 A restores the selected recent P0, not the newest point or a different person's reference", async (t) => {
  const f = serviceFixture(t);
  const request = f.request();
  f.advance(2000);
  const result = await f.run(request);
  assert.deepEqual(result.requestedOrigin, origin);
  assert.deepEqual(result.requestedAnchor, destination);
  assert.deepEqual(result.originRef, request.originRef);
  assert.equal(result.serverNowMs, f.now());
  assert.equal(f.calls.length, 1);
  await assert.rejects(f.run(f.request({ originRef: { stream: leaderStream, seq: 2 } })), error("REFERENCE_EXPIRED"));
  await assert.rejects(f.run(f.request({ anchor: { kind: "sample", ref: { stream: selfStream, seq: 2 } } })), error("REFERENCE_EXPIRED"));
  assert.equal(f.calls.length, 1);
});

test("S5 B interpolates actual historical segments without applying current-position age to the trace", async (t) => {
  const f = serviceFixture(t);
  f.advance(30_000);
  const request = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 0 },
    endRef: { stream: leaderStream, seq: 1 }, fraction: .6 } });
  const result = await f.run(request);
  assert.ok(Math.abs(result.requestedAnchor.lat - (destination.lat + .0000006)) < 1e-10);
  assert.equal(result.mode, "B");
  assert.equal(f.calls.length, 1);
});

for (const [name, changes] of [
  ["missing seq", { seq: 2 }], ["stream change", { stream: "3333333333333333" }],
  ["time reversal", { at: 1 }], ["unknown accuracy", { acc: undefined }], ["poor accuracy", { acc: 26 }],
  ["position jump", { lat: 38 }],
] as const) test(`S5 B rejects ${name} without an external call`, async (t) => {
  const f = serviceFixture(t);
  f.elapse(1000); f.publish("leader", changes); f.publish("follower");
  const current = f.locations.position(f.room.code, "leader")!;
  const input = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 0 },
    endRef: { stream: current.stream, seq: current.seq }, fraction: .5 } });
  await assert.rejects(f.run(input), error(["time reversal", "unknown accuracy", "poor accuracy"].includes(name) ? "LOCATION_NOT_READY" : "TRACE_DISCONTINUITY"));
  assert.equal(f.calls.length, 0);
});

test("S8/S9 pins a new input before cooldown and retries with its original coordinates after the lookup expires", async (t) => {
  const f = serviceFixture(t);
  await f.run();
  f.advance(1000);
  const request = f.request();
  let expires = 0;
  await assert.rejects(f.run(request), (e: unknown) => {
    assert.ok(e instanceof RouteError); assert.equal(e.code, "RATE_LIMITED"); assert.equal(e.retryAfterMs, 29_000);
    assert.equal(e.body(request).inputAccepted, true); expires = e.inputExpiresAtMs!; return true;
  });
  assert.equal(expires, f.now() + ROUTE_INPUT_TTL_MS);
  const selectedOrigin = f.locations.position(f.room.code, "follower")!;
  const selectedAnchor = f.locations.position(f.room.code, "leader")!;
  f.advance(28_000);
  await assert.rejects(f.run({ ...request, requestId: "still-waiting" }), (e: unknown) => e instanceof RouteError && e.retryAfterMs === 1000);
  f.advance(1000);
  assert.equal(f.locations.recentSample(f.room.code, "follower", request.originRef), undefined);
  const result = await f.run({ ...request, requestId: "after-wait" });
  assert.deepEqual(result.requestedOrigin, { lat: selectedOrigin.lat, lng: selectedOrigin.lng });
  assert.deepEqual(result.requestedAnchor, { lat: selectedAnchor.lat, lng: selectedAnchor.lng });
  assert.equal(f.calls.length, 2);
});

test("S8 input identity ignores JSON key order but rejects mutated inputs and stale generations", async (t) => {
  const f = serviceFixture(t);
  f.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30_000); });
  const input = f.request();
  await assert.rejects(f.run(input), error("PROVIDER_UNAVAILABLE"));
  for (const changes of [{ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 0 }, endRef: { stream: leaderStream, seq: 1 }, fraction: 1 } },
    { originRef: { stream: selfStream, seq: 1 } }, { guidanceGeneration: 2 }]) {
    await assert.rejects(f.run({ ...input, ...changes } as FollowRouteRequest), error("CONTEXT_MISMATCH"));
  }
  await assert.rejects(f.run(f.request({ guidanceGeneration: 0 })), error("CONTEXT_MISMATCH"));
  const reordered = Object.fromEntries(Object.entries({ ...input, requestId: "reordered" }).reverse()) as unknown as FollowRouteRequest;
  await assert.rejects(f.run(reordered), error("RATE_LIMITED"));
  assert.equal(f.calls.length, 1);
});

test("S8 concurrent duplicate and replacement generations never start a second transport", async (t) => {
  const f = serviceFixture(t);
  const transport = Promise.withResolvers<ProviderRoute>();
  f.setProvider(() => transport.promise);
  const started = f.nextCall();
  const request = f.request();
  const first = f.run(request);
  const firstRejected = assert.rejects(first, error("CONTEXT_MISMATCH"));
  await started;
  await assert.rejects(f.run({ ...request, requestId: "duplicate" }), error("ROUTE_IN_PROGRESS"));
  const replacement = f.request();
  await assert.rejects(f.run(replacement), (e: unknown) => e instanceof RouteError && e.code === "ROUTE_IN_PROGRESS" && e.body(replacement).inputAccepted === true);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].signal.aborted, true);
  transport.resolve(parseNaverRoute(naverBody(), origin, destination));
  await firstRejected;
  await new Promise<void>((resolve) => setImmediate(resolve));
  await assert.rejects(f.run({ ...replacement, requestId: "replacement-wait" }), error("RATE_LIMITED"));
});

test("S8 account and shared rolling budgets persist across new calculations", async (t) => {
  const f = serviceFixture(t, { accountPerMinute: 1, accountPerHour: 2 });
  await f.run(); f.advance(30_000);
  const second = f.request();
  await assert.rejects(f.run(second), (e: unknown) => e instanceof RouteError && e.retryAfterMs === 30_000);
  f.advance(30_000); await f.run({ ...second, requestId: "second-attempt" });
  f.advance(30_000);
  await assert.rejects(f.run(f.request()), (e: unknown) => e instanceof RouteError && e.code === "RATE_LIMITED" && e.retryAfterMs === 3_510_000);
  assert.equal(f.calls.length, 2);

  const shared = serviceFixture(t, { providerPerMinute: 1 });
  await shared.run();
  shared.locations.requestFollow(shared.room.code, "third", "leader"); shared.publish("third");
  const input = { ...shared.request(), followRequestId: shared.locations.relationOf(shared.room.code, "third")!.requestId,
    originRef: { stream: selfStream, seq: 0 } };
  await assert.rejects(shared.service.calculate(shared.room.code, "third", input, () => "leader"), error("RATE_LIMITED"));
  assert.equal(shared.calls.length, 1);
});

test("S10 transient failures allow two retries, waiting attempts do not consume that budget", async (t) => {
  const f = serviceFixture(t);
  f.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30_000); });
  const input = f.request();
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) f.advance(30_000);
    await assert.rejects(f.run({ ...input, requestId: `try-${attempt}` }), (e: unknown) => {
      assert.ok(e instanceof RouteError); assert.equal(e.code, "PROVIDER_UNAVAILABLE"); assert.equal(e.retryable, attempt < 2); return true;
    });
    if (attempt < 2) await assert.rejects(f.run({ ...input, requestId: `wait-${attempt}` }), error("RATE_LIMITED"));
  }
  f.advance(30_000);
  await assert.rejects(f.run({ ...input, requestId: "try-3" }), (e: unknown) => e instanceof RouteError && !e.retryable);
  assert.equal(f.calls.length, 3);
});

test("S10 five-second timeout aborts transport and client cancellation also propagates", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = serviceFixture(t);
  f.setProvider((_start, _end, signal) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true })));
  const started = f.nextCall();
  const first = f.run(); const failed = assert.rejects(first, error("ROUTE_TIMEOUT"));
  await started;
  t.mock.timers.tick(4999); assert.equal(f.calls[0].signal.aborted, false);
  t.mock.timers.tick(1); await failed; assert.equal(f.calls[0].signal.aborted, true);
  f.advance(30_000);
  const controller = new AbortController(); const next = f.nextCall();
  const second = f.run(f.request(), controller.signal); const cancelled = assert.rejects(second, error("CONTEXT_MISMATCH"));
  await next; controller.abort(); await cancelled;
  assert.equal(f.calls[1].signal.aborted, true);
});

test("S9 inputs expire at 120 seconds and cannot reconstruct missing trace", async (t) => {
  const f = serviceFixture(t);
  f.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30_000); });
  const input = f.request(); await assert.rejects(f.run(input), error("PROVIDER_UNAVAILABLE"));
  f.advance(120_000); f.service.sweep();
  await assert.rejects(f.run({ ...input, requestId: "expired" }), error("REFERENCE_EXPIRED"));
  assert.equal(f.calls.length, 1);
  const g = serviceFixture(t);
  g.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30_000); });
  const old = g.request(); await assert.rejects(g.run(old), error("PROVIDER_UNAVAILABLE"));
  g.elapse(11_000); g.publish("leader"); g.publish("follower");
  await assert.rejects(g.run({ ...old, requestId: "broken" }), error("TRACE_DISCONTINUITY"));
  assert.equal(g.calls.length, 1);
});

test("S13 recent references resolve send races and disappear on age, stop, device reset and room clear", (t) => {
  const f = serviceFixture(t);
  const reference = f.request().originRef;
  f.advance(1000); assert.equal(f.locations.recentSample(f.room.code, "follower", reference)?.seq, 0);
  const copy = f.locations.recentSample(f.room.code, "follower", reference)!; copy.lat = 0;
  assert.equal(f.locations.recentSample(f.room.code, "follower", reference)!.lat, origin.lat);
  f.advance(9000); assert.ok(f.locations.recentSample(f.room.code, "follower", reference));
  f.elapse(1); f.locations.pruneReferences(); assert.equal(f.locations.recentSample(f.room.code, "follower", reference), undefined);
  for (const clear of [() => f.locations.remove(f.room.code, "follower"), () => f.locations.resetDevice(f.room.code, "follower"),
    () => f.locations.clear(f.room.code)]) {
    f.elapse(1000); const fix = f.publish("follower"); clear();
    assert.equal(f.locations.recentSample(f.room.code, "follower", fix), undefined);
  }
});

test("S5 HTTP checks authentication, room membership, sender and follow state before any provider call", async (t) => {
  for (const [handle, device, expected] of [["invalid", undefined, "UNAUTHENTICATED"], ["outsider", undefined, "NOT_ROOM_MEMBER"],
    ["follower", "a".repeat(32), "NOT_ACTIVE_SENDER"]] as const) {
    const f = httpFixture(t); const response = await f.post(f.request(), handle, { device }).done;
    assert.equal(response.json().error.code, expected); assert.equal(f.calls.length, 0);
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  for (const state of ["old", "pending", "rejected", "ended"]) {
    const f = httpFixture(t); const input = f.request();
    if (state === "old") input.followRequestId = "old-follow-id";
    else {
      f.locations.unfollow(f.room.code, "follower");
      if (state !== "ended") {
        f.locations.remove(f.room.code, "leader");
        const pending = f.locations.requestFollow(f.room.code, "follower", "leader");
        input.followRequestId = pending.requestId;
        if (state === "rejected") f.locations.respondFollow(f.room.code, "leader", pending.requestId, false);
      }
    }
    assert.equal((await f.post(input).done).json().error.code, "FOLLOW_NOT_ACTIVE"); assert.equal(f.calls.length, 0);
  }
});

test("S6 HTTP requires both persisted v5 records and timestamps, even for automatic follow acceptance", async (t) => {
  for (const userIndex of [0, 1]) for (const column of ["privacy_version", "location_version", "privacy_consented_at", "location_consented_at"]) {
    const f = httpFixture(t);
    f.db.prepare(`UPDATE users SET ${column} = ? WHERE id = ?`).run(column.endsWith("version") ? "4" : null, f.users[userIndex].id);
    const response = await f.post().done;
    assert.equal(response.statusCode, 403);
    assert.equal(response.json().error.code, userIndex === 0 ? "CONSENT_REQUIRED_TARGET" : "CONSENT_REQUIRED_SELF");
    assert.equal(f.calls.length, 0);
  }
  const f = httpFixture(t);
  updateUserConsent(f.db, f.users[0].id, { locationVersion: "3" });
  f.locations.unfollow(f.room.code, "follower");
  assert.equal(f.locations.requestFollow(f.room.code, "follower", "leader").accepted, true);
  assert.equal((await f.post().done).json().error.code, "CONSENT_REQUIRED_TARGET");
  assert.equal(f.calls.length, 0);
});

test("S6 failed consent storage cannot authorize routing; successful record permits it", async (t) => {
  const f = httpFixture(t);
  updateUserConsent(f.db, f.users[1].id, { locationVersion: "3" });
  f.db.exec("CREATE TRIGGER fail_consent BEFORE UPDATE OF location_version ON users BEGIN SELECT RAISE(FAIL, 'synthetic storage failure'); END");
  const failure = await f.post({ location: { version: "6" } }, "follower", { method: "PUT", path: "/v1/me/consent" }).done;
  assert.equal(failure.statusCode, 500);
  assert.equal((await f.post().done).json().error.code, "CONSENT_REQUIRED_SELF"); assert.equal(f.calls.length, 0);
  f.db.exec("DROP TRIGGER fail_consent");
  assert.equal((await f.post({ location: { version: "6" } }, "follower", { method: "PUT", path: "/v1/me/consent" }).done).statusCode, 200);
  assert.equal((await f.post().done).statusCode, 200); assert.equal(f.calls.length, 1);
});

test("S5/S13 stale measurements, repeated old at, future clocks and poor current accuracy block routing without ending follow", async (t) => {
  for (const mode of ["old-received", "old-at", "future-at", "accuracy", "unknown-accuracy"]) {
    const f = httpFixture(t);
    const input = f.request();
    f.elapse(10_001);
    if (mode !== "old-received") {
      f.publish("leader"); f.publish("follower", mode === "old-at" ? { at: f.now() - 10_001 }
        : mode === "future-at" ? { at: f.now() + 1 } : mode === "accuracy" ? { acc: 26 } : { acc: undefined });
    }
    assert.equal((await f.post(input).done).json().error.code, "LOCATION_NOT_READY");
    assert.equal(f.locations.targetOf(f.room.code, "follower"), "leader"); assert.equal(f.calls.length, 0);
  }
});

for (const scenario of ["unfollow", "leave", "device", "target-device", "consent", "target-consent", "disabled", "token", "stale"]) {
  test(`S7 late success and failure are blocked after ${scenario}`, async (t) => {
    for (const succeeds of [true, false]) {
      const f = httpFixture(t);
      const transport = Promise.withResolvers<ProviderRoute>(); f.setProvider(() => transport.promise);
      const started = f.nextCall(); const call = f.post(); await started;
      let expected: string;
      if (scenario === "unfollow") { f.locations.unfollow(f.room.code, "follower"); expected = "FOLLOW_NOT_ACTIVE"; }
      else if (scenario === "leave") { leaveRoom(f.db, f.room.id, f.users[1].id); expected = "NOT_ROOM_MEMBER"; }
      else if (scenario === "device" || scenario === "target-device") {
        const handle = scenario === "device" ? "follower" : "leader";
        f.hub.claim(f.room.code, handle, "replacement", tokenHash(f.tokens.get(handle)!));
        expected = scenario === "device" ? "NOT_ACTIVE_SENDER" : "FOLLOW_NOT_ACTIVE";
      } else if (scenario === "consent" || scenario === "target-consent") {
        const handle = scenario === "consent" ? "follower" : "leader";
        await f.post({ location: { version: "3" } }, handle, { method: "PUT", path: "/v1/me/consent" }).done;
        expected = scenario === "consent" ? "CONSENT_REQUIRED_SELF" : "CONSENT_REQUIRED_TARGET";
      } else if (scenario === "disabled") { f.setConfig({ provider: "disabled" }); expected = "ROUTING_DISABLED"; }
      else if (scenario === "token") { revokeToken(f.db, f.tokens.get("follower")!); expected = "UNAUTHENTICATED"; }
      else { f.elapse(10_001); expected = "LOCATION_NOT_READY"; }
      if (succeeds) transport.resolve(parseNaverRoute(naverBody(), origin, destination));
      else transport.reject(new Error("untrusted provider exception"));
      const response = await call.done;
      assert.equal(response.json().error.code, expected); assert.equal(response.json().points, undefined);
      assert.equal(f.calls.length, 1);
    }
  });
}

test("S11 routing disabled preserves position and call signaling APIs and supplies feature/server time", async (t) => {
  const f = httpFixture(t); f.setConfig({ provider: "disabled" });
  const route = await f.post().done; assert.equal(route.json().error.code, "ROUTING_DISABLED");
  const positions = await f.post(undefined, "follower", { method: "GET", path: "/v1/rooms/ABC234/positions" }).done;
  assert.equal(positions.statusCode, 200); assert.equal(positions.json().serverNowMs, f.now());
  assert.equal(positions.json().followRoute.enabled, false); assert.equal(positions.json().positions.length, 2);
  const signal = await f.post({ to: "leader", kind: "offer", payload: {} }, "follower", { path: "/v1/rooms/ABC234/signal" }).done;
  assert.equal(signal.statusCode, 202); assert.equal(f.calls.length, 0);
});

test("S12 route responses and application logs do not expose provider errors, request URLs, coordinates or keys", async (t) => {
  const f = httpFixture(t);
  f.setProvider(async () => { throw new Error("SECRET-NAVER https://secret.test?lat=37.5&lng=127"); });
  const logs: string[] = [];
  t.mock.method(process.stdout, "write", (value: string | Uint8Array) => { logs.push(String(value)); return true; });
  const input = f.request();
  const response = await f.post(input, "follower", { path: "/v1/rooms/ABC234/follow-route?key=SECRET-NAVER&lat=37.5" }).done;
  const serialized = JSON.stringify(response.json());
  assert.equal(response.statusCode, 502);
  assert.doesNotMatch(serialized + logs.join(""), /SECRET-NAVER|https:|37\.5|127|ABC234|follower/);
  assert.deepEqual(response.json().error, { code: "PROVIDER_UNAVAILABLE", retryable: true, retryAfterMs: 30_000 });
  assert.equal(response.json().requestId, input.requestId);
  // The checked-in reverse proxy enables no request/access log or outbound URL logging.
  const caddy = readFileSync(new URL("../../deploy/lightsail/Caddyfile", import.meta.url), "utf8");
  assert.doesNotMatch(caddy, /^\s*(log|debug)\b/m);
});

test("S5 HTTP malformed JSON, unknown fields and both declared/streamed 16 KiB limits have the contract envelope", async (t) => {
  const f = httpFixture(t);
  for (const options of [{ raw: "{" }, { raw: "[]" }, { headers: { "content-type": "text/plain" } }]) {
    const response = await f.post(f.request(), "follower", options).done;
    assert.equal(response.statusCode, 400); assert.equal(response.json().error.code, "INVALID_REQUEST");
  }
  for (const options of [{ raw: "x".repeat(16 * 1024 + 1) }, { headers: { "content-length": String(16 * 1024 + 1) } }]) {
    const response = await f.post(f.request(), "follower", options).done;
    assert.equal(response.statusCode, 413); assert.equal(response.json().error.code, "REQUEST_TOO_LARGE");
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  assert.equal(f.calls.length, 0);
});

test("S8 provider retry-after is shared and survives a new mode/calculation", async (t) => {
  const f = serviceFixture(t);
  f.setProvider(async () => { throw new RouteError("PROVIDER_RATE_LIMITED", 45_000); });
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.retryAfterMs === 45_000);
  f.advance(30_000);
  const next = f.request();
  await assert.rejects(f.run(next), (e: unknown) => e instanceof RouteError && e.code === "RATE_LIMITED" && e.retryAfterMs === 15_000);
  f.locations.requestFollow(f.room.code, "third", "leader"); f.publish("third");
  const other = { ...next, followRequestId: f.locations.relationOf(f.room.code, "third")!.requestId,
    originRef: { stream: selfStream, seq: 0 } };
  await assert.rejects(f.service.calculate(f.room.code, "third", other, () => "leader"),
    (e: unknown) => e instanceof RouteError && e.retryAfterMs === 15_000);
  assert.equal(f.calls.length, 1);
});

test("S8 completed geometry is not cached and lost replies can retry only within the fixed-input budget", async (t) => {
  const f = serviceFixture(t);
  const input = f.request();
  const first = await f.run(input);
  first.points[0].lat = 0;
  await assert.rejects(f.run(input), error("CONTEXT_MISMATCH"));
  f.advance(30_000);
  const retry = await f.run({ ...input, requestId: "lost-reply-retry" });
  assert.equal(retry.points[0].lat, origin.lat); assert.equal(f.calls.length, 2);
  assert.deepEqual(f.calls[0].origin, f.calls[1].origin);
  f.advance(30_000); await f.run({ ...input, requestId: "last-retry" });
  f.advance(30_000);
  await assert.rejects(f.run({ ...input, requestId: "over-budget" }), error("CONTEXT_MISMATCH"));
  assert.equal(f.calls.length, 3);
});

test("S10 permanent provider failures are not repeated for the same calculation", async (t) => {
  for (const code of ["NO_ROUTE", "ENDPOINT_MISMATCH", "PROVIDER_AUTH_FAILED", "INVALID_PROVIDER_RESPONSE", "ROUTE_TOO_LARGE"] as const) {
    const f = serviceFixture(t); f.setProvider(async () => { throw new RouteError(code); });
    const input = f.request(); await assert.rejects(f.run(input), error(code));
    f.advance(30_000); await assert.rejects(f.run({ ...input, requestId: "repeat" }), error(code));
    assert.equal(f.calls.length, 1);
  }
});

test("S8 default hourly budget is 60 actual calls and survives a renewed follow relation", async (t) => {
  const f = serviceFixture(t);
  for (let i = 0; i < 60; i++) {
    if (i) f.advance(30_000);
    await f.run();
  }
  f.locations.unfollow(f.room.code, "follower");
  f.locations.requestFollow(f.room.code, "follower", "leader");
  f.advance(30_000);
  await assert.rejects(f.run(), (e: unknown) => e instanceof RouteError && e.code === "RATE_LIMITED" && e.retryAfterMs === 1_800_000);
  assert.equal(f.calls.length, 60);
});

test("S7 a new accepted relation keeps its pinned input when an old transport finishes", async (t) => {
  const f = serviceFixture(t);
  const transport = Promise.withResolvers<ProviderRoute>();
  f.setProvider(() => transport.promise);
  const started = f.nextCall(); const old = f.request();
  const first = f.run(old); const rejected = assert.rejects(first, error("FOLLOW_NOT_ACTIVE"));
  await started;
  f.locations.unfollow(f.room.code, "follower");
  f.locations.requestFollow(f.room.code, "follower", "leader");
  f.advance(1000);
  const next = f.request(); assert.notEqual(old.followRequestId, next.followRequestId);
  await assert.rejects(f.run(next), error("ROUTE_IN_PROGRESS"));
  transport.reject(new Error("old provider failure")); await rejected;
  await new Promise<void>((resolve) => setImmediate(resolve));
  f.setProvider(async (start, end) => parseNaverRoute(naverBody(start, end), start, end));
  f.advance(29_000);
  const result = await f.run({ ...next, requestId: "new-relation-retry" });
  assert.equal(result.followRequestId, next.followRequestId); assert.equal(f.calls.length, 2);
});

test("S7 stop, shutdown and stream discontinuity cancel or reject an in-flight result", async (t) => {
  for (const scenario of ["stop", "shutdown", "stream"] as const) {
    const f = serviceFixture(t); const transport = Promise.withResolvers<ProviderRoute>();
    f.setProvider(() => transport.promise);
    const started = f.nextCall(); const first = f.run();
    const failure = assert.rejects(first, error(scenario === "stop" ? "LOCATION_NOT_READY" : scenario === "shutdown" ? "ROUTING_DISABLED" : "TRACE_DISCONTINUITY"));
    await started;
    if (scenario === "stop") f.locations.remove(f.room.code, "follower");
    else if (scenario === "shutdown") f.service.close();
    else { f.elapse(1000); f.publish("leader", { stream: "3333333333333333" }); f.publish("follower"); }
    if (scenario !== "stream") assert.equal(f.calls[0].signal.aborted, true);
    transport.resolve(parseNaverRoute(naverBody(), origin, destination)); await failure;
  }
});

test("S7 response write rechecks authorization after the service returns", async (t) => {
  const f = httpFixture(t);
  const original = FollowRouteService.prototype.calculate;
  t.mock.method(FollowRouteService.prototype, "calculate", async function (this: FollowRouteService, ...args: Parameters<typeof original>) {
    const result = await original.apply(this, args);
    revokeToken(f.db, f.tokens.get("follower")!);
    return result;
  });
  const response = await f.post().done;
  assert.equal(response.statusCode, 401); assert.equal(response.json().error.code, "UNAUTHENTICATED");
  assert.equal(response.json().points, undefined); assert.equal(f.calls.length, 1);
});

test("S7 response write also discards a late provider failure after authorization changes", async (t) => {
  const f = httpFixture(t);
  f.setProvider(async () => { throw new RouteError("NO_ROUTE"); });
  const original = FollowRouteService.prototype.calculate;
  t.mock.method(FollowRouteService.prototype, "calculate", async function (this: FollowRouteService, ...args: Parameters<typeof original>) {
    try { return await original.apply(this, args); }
    catch (error) {
      revokeToken(f.db, f.tokens.get("follower")!);
      throw error;
    }
  });
  const response = await f.post().done;
  assert.equal(response.statusCode, 401); assert.equal(response.json().error.code, "UNAUTHENTICATED");
  assert.equal(f.calls.length, 1);
});

test("S13 recent reference lookup is bounded even after many accepted samples", (t) => {
  const f = serviceFixture(t);
  for (let i = 0; i < 100; i++) { f.elapse(400); f.publish("follower"); }
  const retained = Array.from({ length: 101 }, (_, seq) => f.locations.recentSample(f.room.code, "follower", { stream: selfStream, seq })).filter(Boolean);
  assert.equal(retained.length, 26); assert.ok(retained.length <= 64);
  assert.equal(retained[0]!.seq, 75);
});

test("S7/S13 SSE resume preserves calculation inputs and exposes original sample age", async (t) => {
  const f = httpFixture(t);
  f.setProvider(async () => { throw new RouteError("PROVIDER_UNAVAILABLE", 30_000); });
  const input = f.request(); assert.equal((await f.post(input).done).statusCode, 502);
  const receivedAt = f.locations.position(f.room.code, "leader")!.receivedAt;
  f.elapse(2000);
  const stream = f.post(undefined, "follower", { method: "GET", path: "/v1/rooms/ABC234/events?resume=1" });
  const frame = Buffer.concat(stream.response.chunks).toString();
  const hello = JSON.parse(frame.split("\n").find((line) => line.startsWith("data: "))!.slice(6));
  assert.equal(hello.serverNowMs, f.now()); assert.equal(hello.followRequestId, input.followRequestId);
  assert.equal(hello.positions.find((fix: { handle: string }) => fix.handle === "leader").receivedAt, receivedAt);
  assert.equal(hello.followRoute.enabled, true);
  stream.response.destroy();
  // Fill the gap with real measurements; the old pinned inputs remain valid.
  f.publish("leader"); f.publish("follower"); f.advance(28_000);
  f.setProvider(async (start, end) => parseNaverRoute(naverBody(start, end), start, end));
  const response = await f.post({ ...input, requestId: "after-resume" }).done;
  assert.equal(response.statusCode, 200); assert.deepEqual(response.json().requestedOrigin, origin);
  assert.equal(f.calls.length, 2);
});

test("S5 current-location age accepts the 10-second boundary and holds beyond it", async (t) => {
  const f = serviceFixture(t); const input = f.request(); f.elapse(10_000);
  assert.equal((await f.run(input)).result, "route");
  f.elapse(1);
  await assert.rejects(f.run({ ...input, requestId: "stale" }), error("LOCATION_NOT_READY"));
  assert.equal(f.locations.targetOf(f.room.code, "follower"), "leader");
  assert.equal(f.calls.length, 1);
});
