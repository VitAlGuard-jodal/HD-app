import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { naverProvider } from "../../src/route_providers/naver.ts";
import { leaderStream, naverBody, routeFixture } from "../helpers/route_fixture.ts";

// Real loopback HTTP. Run with the existing HTTP suite outside a sandbox that
// prohibits listen(); all provider traffic still uses invented responses.
async function fixture(t: TestContext) {
  const f = routeFixture(t);
  const server = createServer(createApp({ ...f, routeOptions: f.routeOptions }));
  const controllers = new Set<AbortController>();
  t.after(async () => {
    for (const controller of controllers) controller.abort();
    await new Promise<void>((resolve) => { server.close(() => resolve()); server.closeAllConnections(); });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve(); });
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const base = `http://127.0.0.1:${address.port}`;
  const path = `/v1/rooms/${f.room.code}/follow-route`;
  async function api(body: unknown, options: { token?: string; path?: string; method?: string; device?: string; raw?: string } = {}) {
    const response = await fetch(base + (options.path ?? path), {
      method: options.method ?? "POST", signal: AbortSignal.timeout(5000),
      headers: { authorization: `Bearer ${options.token ?? f.tokens.get("follower")}`, "content-type": "application/json",
        ...(options.device ? { "x-unavo-device": options.device } : {}) },
      body: options.method === "GET" ? undefined : options.raw ?? JSON.stringify(body),
    });
    return { status: response.status, headers: response.headers, body: await response.json() as any };
  }
  return { ...f, base, path, api, controllers };
}

test("follow-route HTTP A contract uses Naver units, exact references and no-store", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  f.setProvider(naverProvider(async (url) => {
    const query = new URL(String(url)).searchParams;
    const [lng, lat] = query.get("start")!.split(",").map(Number);
    const [endLng, endLat] = query.get("goal")!.split(",").map(Number);
    return Response.json(naverBody({ lat, lng }, { lat: endLat, lng: endLng }));
  }));
  const request = f.request(); f.advance(1000);
  const response = await f.api(request);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  for (const key of ["schemaVersion", "followRequestId", "guidanceGeneration", "calculationId", "requestId", "mode", "originRef", "anchor"] as const) {
    assert.deepEqual(response.body[key], request[key]);
  }
  assert.equal(response.body.provider, "naver"); assert.equal(response.body.routeOption, "traoptimal");
  assert.equal(response.body.seconds, 12.345); assert.equal(response.body.serverNowMs, f.now());
  assert.equal(response.body.points.length, 2); assert.equal(response.body.points[0].seq, undefined);
  assert.equal(f.calls.length, 1);
});

test("follow-route HTTP validates tokens, ownership, schema and 16 KiB body before routing", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  for (const [options, status, code] of [
    [{ token: "invalid" }, 401, "UNAUTHENTICATED"],
    [{ token: f.tokens.get("outsider") }, 403, "NOT_ROOM_MEMBER"],
    [{ device: "a".repeat(32) }, 403, "NOT_ACTIVE_SENDER"],
    [{ raw: "{" }, 400, "INVALID_REQUEST"],
    [{ raw: "x".repeat(16 * 1024 + 1) }, 413, "REQUEST_TOO_LARGE"],
  ] as const) {
    const request = f.request(); const response = await f.api(request, options);
    assert.equal(response.status, status); assert.equal(response.body.error.code, code);
    assert.equal(response.body.error.retryable, false); assert.equal(response.body.error.retryAfterMs, null);
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
  assert.equal(f.calls.length, 0);
});

test("follow-route HTTP pins B inputs during A/B cooldown and restores historical J", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  assert.equal((await f.api(f.request())).status, 200);
  f.advance(1000);
  const input = f.request({ mode: "B", anchor: { kind: "segment", startRef: { stream: leaderStream, seq: 0 },
    endRef: { stream: leaderStream, seq: 1 }, fraction: 1 } });
  const blocked = await f.api(input);
  assert.equal(blocked.status, 429); assert.equal(blocked.body.inputAccepted, true);
  assert.equal(blocked.body.error.retryAfterMs, 29_000); assert.equal(blocked.body.inputExpiresAtMs, f.now() + 120_000);
  f.advance(29_000);
  const response = await f.api({ ...input, requestId: "retry-after-cooldown" });
  assert.equal(response.status, 200); assert.equal(response.body.mode, "B");
  assert.deepEqual(response.body.anchor, input.anchor);
  assert.ok(Math.abs(response.body.requestedAnchor.lat - 37.501001) < 1e-10);
  assert.equal(f.calls.length, 2);
});

test("follow-route HTTP uses persisted consent and disabled routing leaves position/signaling APIs available", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  const consentPath = "/v1/me/consent";
  await f.api({ location: { version: "3" } }, { path: consentPath, method: "PUT", token: f.tokens.get("leader") });
  assert.equal((await f.api(f.request())).body.error.code, "CONSENT_REQUIRED_TARGET"); assert.equal(f.calls.length, 0);
  await f.api({ location: { version: "6" } }, { path: consentPath, method: "PUT", token: f.tokens.get("leader") });
  assert.equal((await f.api(f.request())).status, 200);
  f.setConfig({ provider: "disabled" });
  assert.equal((await f.api(f.request())).body.error.code, "ROUTING_DISABLED");
  const positions = await f.api(undefined, { method: "GET", path: "/v1/rooms/ABC234/positions" });
  assert.equal(positions.status, 200); assert.equal(positions.body.followRoute.enabled, false);
  assert.equal(positions.body.serverNowMs, f.now());
  assert.equal((await f.api({ to: "leader", kind: "offer", payload: {} }, { path: "/v1/rooms/ABC234/signal" })).status, 202);
  assert.equal(f.calls.length, 1);
});

test("follow-route HTTP disconnect aborts the outstanding provider transport", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  const aborted = Promise.withResolvers<void>();
  f.setProvider((_start, _end, signal) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => { aborted.resolve(); reject(signal.reason); }, { once: true });
  }));
  const controller = new AbortController(); f.controllers.add(controller);
  const started = f.nextCall();
  const pending = fetch(f.base + f.path, { method: "POST", signal: controller.signal,
    headers: { authorization: `Bearer ${f.tokens.get("follower")}`, "content-type": "application/json" }, body: JSON.stringify(f.request()) });
  const rejected = assert.rejects(pending, (e: unknown) => e instanceof Error && e.name === "AbortError");
  await started; controller.abort(); await rejected; await aborted.promise;
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].signal.aborted, true);
});

test("follow-route HTTP provider auth is distinct from app auth and errors never expose upstream details", { timeout: 10_000 }, async (t) => {
  const f = await fixture(t);
  f.setProvider(naverProvider(async () => new Response("synthetic-secret https://provider.invalid?lat=37.5", { status: 403 })));
  const response = await f.api(f.request());
  assert.equal(response.status, 502);
  assert.deepEqual(response.body.error, { code: "PROVIDER_AUTH_FAILED", retryable: false, retryAfterMs: null });
  assert.doesNotMatch(JSON.stringify(response.body), /synthetic-secret|https:|37\.5/);
  assert.equal(response.headers.get("cache-control"), "no-store");
});
