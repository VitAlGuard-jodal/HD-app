import assert from "node:assert/strict";
import { test } from "node:test";
import { createApp } from "../../src/app.ts";
import { GeocodingService, geocodingConfig, naverGeocoding, parseAddresses, parseSearch } from "../../src/geocoding.ts";
import type { AddressResult, GeocodingProvider } from "../../src/geocoding.ts";
import { RouteError } from "../../src/route_contract.ts";
import { MeetingRecommendationService } from "../../src/meeting_recommendation.ts";
import { revokeToken } from "../../src/auth.ts";
import { updateUserConsent } from "../../src/store.ts";
import { dispatch, naverConfig } from "../helpers/route_fixture.ts";
import { pin, planFixture } from "../helpers/plan_fixture.ts";

const body = () => ({ status: "OK", addresses: [{ x: "127.123", y: "37.456", roadAddress: "서울시 시험로 123", jibunAddress: "서울시 시험동 1" }] });
const input = { requestId: "address-search", query: "  서울시   시험로 123  " };
const error = (code: string) => (e: unknown) => e instanceof RouteError && e.code === code;
test("geocoding: explicit activation, Unicode input, fixed endpoint, encoded query and no coordinate parameter", async () => {
  assert.deepEqual(geocodingConfig({ ROUTE_PROVIDER: "naver", NAVER_DIRECTIONS_KEY: "key", NAVER_DIRECTIONS_KEY_ID: "id" }), { provider: "disabled" });
  assert.equal(geocodingConfig({ GEOCODING_ENABLED: "true", NAVER_DIRECTIONS_KEY: "key", NAVER_DIRECTIONS_KEY_ID: "id" }).provider, "naver");
  const parsed = parseSearch(input); assert.equal(parsed.query, "서울시 시험로 123");
  for (const query of ["a", " ", "a\nb", "a\u0000b", "가".repeat(201)]) assert.throws(() => parseSearch({ ...input, query }), error("INVALID_REQUEST"));
  assert.throws(() => parseSearch({ ...input, coordinate: "127,37" }), error("INVALID_REQUEST"));
  const provider = naverGeocoding(async (url, init) => {
    const u = new URL(String(url)); assert.equal(u.origin, "https://maps.apigw.ntruss.com");
    assert.equal(u.pathname, "/map-geocode/v2/geocode");
    assert.deepEqual([...u.searchParams], [["query", parsed.query], ["page", "1"], ["count", "5"]]);
    assert.equal(init?.redirect, "error"); assert.equal(init?.cache, "no-store");
    return Response.json(body());
  });
  const result = await provider(parsed.query, new AbortController().signal, naverConfig);
  assert.deepEqual(result, [{ lat: 37.456, lng: 127.123, label: "서울시 시험로 123", roadAddress: "서울시 시험로 123", jibunAddress: "서울시 시험동 1" }]);
  assert.deepEqual(parseAddresses({ status: "OK", addresses: [] }), []);
  for (const response of [{ status: "SYSTEM_ERROR", addresses: [] }, { status: "OK", addresses: [{ ...body().addresses[0], x: "" }] },
    { status: "OK", addresses: [{ ...body().addresses[0], y: "127" }] }, { status: "OK", addresses: new Array(6).fill(body().addresses[0]) }]) {
    assert.throws(() => parseAddresses(response), error("SEARCH_UNAVAILABLE"));
  }
});
test("geocoding: upstream auth, throttle and transport errors are sanitized and separate from user auth", async () => {
  for (const status of [401, 403, 429, 500]) {
    const provider = naverGeocoding(async () => new Response("secret upstream query=private-address", { status }));
    await assert.rejects(provider("주소", new AbortController().signal, naverConfig), error(status === 429 ? "RATE_LIMITED" : "SEARCH_UNAVAILABLE"));
  }
  const provider = naverGeocoding(async () => { throw new Error("https://secret.invalid?query=private-address"); });
  await assert.rejects(provider("주소", new AbortController().signal, naverConfig), (e: unknown) => e instanceof RouteError && !/secret|private-address/.test(e.message));
});
test("geocoding: separate one-second/account budget, concurrent slot, timeout and retry do not cache results", async (t) => {
  const f = planFixture(t); let calls = 0; let provider: GeocodingProvider = async () => { calls++; return []; };
  const service = new GeocodingService(f.locations, f.plans, { now: f.now, monotonicNow: f.now, config: () => naverConfig,
    provider: (...args) => provider(...args) }); t.after(() => service.close());
  const search = () => service.search(f.room.code, "leader", input, () => {});
  await search(); await assert.rejects(search(), error("RATE_LIMITED"));
  f.step(); await search(); assert.equal(calls, 2);
  f.step(); const pending = Promise.withResolvers<AddressResult[]>();
  let signal: AbortSignal | undefined; provider = async (_query, s) => { signal = s; return pending.promise; };
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const run = search(); const failed = assert.rejects(run, error("SEARCH_TIMEOUT"));
  await assert.rejects(search(), error("ROUTE_IN_PROGRESS"));
  t.mock.timers.tick(4999); assert.equal(signal!.aborted, false);
  t.mock.timers.tick(1); await failed; assert.equal(signal!.aborted, true);
  // A misbehaving transport keeps the physical slot even after caller timeout.
  await assert.rejects(search(), error("ROUTE_IN_PROGRESS")); pending.resolve([]); await Promise.resolve();
});
test("geocoding: late result is blocked by movement, plan creation, account change and consent loss", async (t) => {
  for (const change of ["movement", "plan", "account", "consent"]) {
    const f = planFixture(t); const pending = Promise.withResolvers<AddressResult[]>(); let authorized = true;
    const service = new GeocodingService(f.locations, f.plans, { now: f.now, config: () => naverConfig, provider: () => pending.promise });
    t.after(() => service.close());
    const run = service.search(f.room.code, "leader", input, () => { if (!authorized) throw new RouteError("UNAUTHENTICATED"); });
    if (change === "movement") f.step({}, 5);
    if (change === "plan") f.save();
    if (change === "account") authorized = false;
    if (change === "consent") service.invalidateConsent("leader");
    pending.resolve(parseAddresses(body()));
    await assert.rejects(run, error(({ movement: "STOP_REQUIRED", plan: "PLAN_CHANGED", account: "UNAUTHENTICATED", consent: "CONSENT_REQUIRED_SELF" })[change]!));
  }
});
test("HTTP search and recommendation: v6 consent, active device, no-store and private logging", async (t) => {
  const f = planFixture(t); f.plans.close(); let searches = 0;
  const app = createApp({ ...f, routeOptions: f.routeOptions, geocodingOptions: { config: () => naverConfig,
    provider: async () => { searches++; return parseAddresses(body()); } } });
  const logs: string[] = []; const write = process.stdout.write.bind(process.stdout);
  t.mock.method(process.stdout, "write", (chunk: any, ...args: any[]) => { logs.push(String(chunk)); return write(chunk, ...args); });
  const call = (who = "leader", data: unknown = input, options: Record<string, any> = {}) => dispatch(app, f.tokens.get(who)!, data,
    { path: "/v1/rooms/ABC234/geocoding?query=private-address", ...options }).done;
  updateUserConsent(f.db, f.users[0].id, { locationVersion: "5" });
  assert.equal((await call()).json().error.code, "CONSENT_REQUIRED_SELF"); assert.equal(searches, 0);
  updateUserConsent(f.db, f.users[0].id, { locationVersion: "6" });
  assert.equal((await call("leader", input, { device: "a".repeat(32) })).json().error.code, "NOT_ACTIVE_SENDER");
  const reply = await call(); assert.equal(reply.statusCode, 200); assert.equal(reply.headers.get("cache-control"), "no-store");
  assert.equal(reply.json().requestId, input.requestId); assert.equal(searches, 1);
  assert.doesNotMatch(logs.join(""), /private-address|서울|ABC234|leader|127\.123|secret/);
  const invalid = await call("leader", undefined, { raw: "x".repeat(16 * 1024 + 1) });
  assert.equal(invalid.statusCode, 413);
  assert.equal((await call("leader", undefined, { raw: "{" })).json().error.code, "INVALID_REQUEST");
});

test("new APIs recheck authorization immediately before writing successes AND failures", async (t) => {
  for (const kind of ["search", "recommend"] as const) for (const failure of [false, true]) {
    const f = planFixture(t); f.plans.close();
    if (failure) f.setProvider(async () => { throw new RouteError("NO_ROUTE"); });
    const app = createApp({ ...f, routeOptions: f.routeOptions, geocodingOptions: { config: () => naverConfig, provider: async () => {
      if (failure) throw new RouteError("SEARCH_UNAVAILABLE"); return [];
    } } });
    const originalSearch = GeocodingService.prototype.search;
    const originalRecommend = MeetingRecommendationService.prototype.recommend;
    const wrap = async (work: () => Promise<unknown>) => {
      try { return await work(); } finally { revokeToken(f.db, f.tokens.get("leader")!); }
    };
    if (kind === "search") t.mock.method(GeocodingService.prototype, "search", function (this: GeocodingService, ...args: Parameters<typeof originalSearch>) {
      return wrap(() => originalSearch.apply(this, args));
    });
    else t.mock.method(MeetingRecommendationService.prototype, "recommend", function (this: MeetingRecommendationService, ...args: Parameters<typeof originalRecommend>) {
      return wrap(() => originalRecommend.apply(this, args));
    });
    const path = kind === "search" ? "geocoding" : "follow-plans/self/recommend";
    const payload = kind === "search" ? input : { requestId: "recommend", draftGeneration: 1, planId: null,
      expectedRevision: 0, destination: pin(1000), participantFollowRequestIds: [f.relation.requestId] };
    const reply = await dispatch(app, f.tokens.get("leader")!, payload, { path: `/v1/rooms/ABC234/${path}` }).done;
    assert.equal(reply.statusCode, 401); assert.equal(reply.json().error.code, "UNAUTHENTICATED");
    assert.equal(reply.json().results, undefined); assert.equal(reply.json().joinPoint, undefined);
    t.mock.restoreAll();
  }
});
test("recommendation response cannot survive a last-moment participant consent withdrawal", async (t) => {
  const f = planFixture(t); f.plans.close(); const app = createApp({ ...f, routeOptions: f.routeOptions });
  const original = MeetingRecommendationService.prototype.recommend;
  t.mock.method(MeetingRecommendationService.prototype, "recommend", async function (this: MeetingRecommendationService, ...args: Parameters<typeof original>) {
    const result = await original.apply(this, args); updateUserConsent(f.db, f.users[1].id, { locationVersion: "5" }); return result;
  });
  const reply = await dispatch(app, f.tokens.get("leader")!, { requestId: "recommend", draftGeneration: 1, planId: null,
    expectedRevision: 0, destination: pin(1000), participantFollowRequestIds: [f.relation.requestId] }, { path: "/v1/rooms/ABC234/follow-plans/self/recommend" }).done;
  assert.equal(reply.statusCode, 403); assert.equal(reply.json().error.code, "CONSENT_REQUIRED_PARTICIPANT");
  assert.deepEqual(reply.json().participantFollowRequestIds, [f.relation.requestId]);
});
