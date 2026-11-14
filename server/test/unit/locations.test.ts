import assert from "node:assert/strict";
import { IncomingMessage } from "node:http";
import type { ServerResponse } from "node:http";
import { Socket } from "node:net";
import { Writable } from "node:stream";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { issueToken, revokeToken, tokenHash } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { LOCATION_TRAIL_LIMIT, LOCATION_DISCONNECT_GRACE_MS, LOCATION_STALE_MS, RoomLocationStore } from "../../src/locations.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { RoomReadyStore } from "../../src/ready.ts";
import { createRoom, createUser, findRoomByCode, isRoomMember, joinRoom, leaveRoom } from "../../src/store.ts";

const sample = { handle: "alice", stream: "0123456789abcdef", lat: 37.5, lng: 127, acc: 3, speed: 2, heading: 90, at: 1000, seq: 0 };

// me.test.ts와 같이 TCP 없이 실제 라우터/인증/SSE 응답을 검증한다.
class Response extends Writable {
  statusCode = 200;
  headersSent = false;
  readonly chunks: Buffer[] = [];
  readonly headers = new Map<string, string>();
  setHeader(name: string, value: string): void { this.headers.set(name, value); }
  writeHead(status: number, headers: Record<string, string>): void {
    this.statusCode = status;
    for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
  }
  flushHeaders(): void { this.headersSent = true; }
  override _write(chunk: Buffer, _encoding: BufferEncoding, done: () => void): void {
    this.headersSent = true;
    this.chunks.push(Buffer.from(chunk));
    done();
  }
  events(): { name: string; data: any }[] {
    return Buffer.concat(this.chunks).toString().split("\n\n").filter((frame) => frame.startsWith("event:")).map((frame) => {
      const [name, data] = frame.split("\n");
      return { name: name.slice(7), data: JSON.parse(data.slice(6)) };
    });
  }
}

function fixture(t: TestContext, withFollow = true) {
  const db = openDb(":memory:");
  const hub = new RoomEventHub();
  const locations = new RoomLocationStore();
  const readiness = new RoomReadyStore();
  const app = createApp({ db, hub, locations, readiness });
  const users = ["alice", "bob", "outsider"].map((handle) =>
    createUser(db, { handle, displayName: handle, passwordHash: "unused" })!);
  const tokens = new Map(users.map((user) => [user.handle, issueToken(db, user.id)]));
  const room = createRoom(db, { code: "ABC234", name: "위치 공유", createdBy: users[0].id })!;
  joinRoom(db, room.id, users[1].id);
  // The fixture inserts membership directly; mirror explicit initial entry.
  for (const handle of ["alice", "bob"]) {
    const hash = tokenHash(tokens.get(handle)!);
    hub.claim(room.code, handle, hash, hash);
  }
  if (withFollow) {
    const request = locations.requestFollow(room.code, "bob", "alice");
    locations.respondFollow(room.code, "alice", request.requestId, true);
  }
  const responses: Response[] = [];
  t.after(() => {
    hub.close();
    for (const response of responses) response.destroy();
    db.close();
  });
  function send(method: string, path: string, handle = "alice", body?: unknown) {
    const request = new IncomingMessage(new Socket());
    request.method = method;
    request.url = path;
    request.headers = { authorization: `Bearer ${tokens.get(handle) ?? "invalid"}` };
    if (body !== undefined) request.headers["content-type"] = "application/json";
    const response = new Response();
    responses.push(response);
    app(request, response as unknown as ServerResponse);
    if (body !== undefined) request.push(JSON.stringify(body));
    request.push(null);
    return response;
  }
  async function api(method: string, action: string, handle = "alice", body?: unknown) {
    const response = send(method, `/v1/rooms/abc234${action}`, handle, body);
    await new Promise<void>((resolve, reject) => {
      response.once("finish", resolve);
      response.once("error", reject);
    });
    const raw = Buffer.concat(response.chunks).toString();
    return { status: response.statusCode, body: raw ? JSON.parse(raw) : undefined, response };
  }
  return { db, hub, locations, readiness, room, users, send, api, app, tokens };
}


function follow(store: RoomLocationStore, code = "ROOM", requester = "bob", target = "alice") {
  const result = store.requestFollow(code, requester, target);
  if (!result.accepted) store.respondFollow(code, target, result.requestId, true);
  return result;
}

test("C1 유한수·범위와 안전 정수 seq를 검증한다", () => {
  const store = new RoomLocationStore(() => 0);
  for (const fix of [null, [], {}, ...[1e100, 2 ** 53, -1, NaN, Infinity, .5].map((seq) => ({ ...sample, seq })),
    ...["lat", "lng", "acc", "speed", "heading", "at"].flatMap((key) =>
      [NaN, Infinity, -Infinity, "1", null].map((value) => ({ ...sample, [key]: value }))),
    ...[{ lat: 91 }, { lng: -181 }, { acc: -1 }, { speed: -1 }, { heading: 361 }, { at: -1 }, { stream: "bad" }]
      .map((value) => ({ ...sample, ...value })),
  ]) assert.deepEqual(store.accept("ROOM", fix), { ok: false, reason: "invalid" });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: Number.MAX_SAFE_INTEGER, lat: -90, lng: 180, heading: 360 }),
    { ok: true, dropped: false });
});

test("source accepts only omitted or vehicle; bad accuracy cannot hide behind the source", () => {
  const store = new RoomLocationStore(() => 1000);
  for (const src of [null, "phone", "Vehicle", "unknown", 1, true, {}]) {
    assert.deepEqual(store.accept("ROOM", { ...sample, src }), { ok: false, reason: "invalid" });
  }
  for (const acc of [null, -1, NaN, Infinity, "25"]) {
    assert.deepEqual(store.accept("ROOM", { ...sample, src: "vehicle", acc }), { ok: false, reason: "invalid" });
  }
  follow(store);
  const vehicle = { ...sample, acc: undefined, src: "vehicle" };
  assert.deepEqual(store.accept("ROOM", vehicle), { ok: true, dropped: false });
  const ref = { stream: sample.stream, seq: sample.seq };
  for (const fix of [store.position("ROOM", "alice"), store.recentSample("ROOM", "alice", ref),
    store.trail("ROOM", "alice")[0], store.snapshot("ROOM", "bob").trails.alice[0]]) {
    assert.equal(fix?.src, "vehicle");
    assert.equal(Object.hasOwn(fix!, "acc"), false);
  }
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 1 }, 2000), { ok: true, dropped: false });
  assert.equal(Object.hasOwn(store.position("ROOM", "alice")!, "src"), false);
});

test("vehicle source and absent accuracy survive location SSE and reconnect hello", async (t) => {
  const { api, send } = fixture(t);
  const events = send("GET", "/v1/rooms/ABC234/events", "bob");
  assert.equal((await api("POST", "/location", "alice", { ...sample, src: "vehicle", acc: undefined })).status, 202);
  const update = events.events().find((event) => event.name === "location")!.data;
  assert.equal(update.src, "vehicle");
  assert.equal(Object.hasOwn(update, "acc"), false);
  events.emit("close");
  const reconnect = send("GET", "/v1/rooms/ABC234/events", "bob");
  const hello = reconnect.events().find((event) => event.name === "hello")!.data;
  assert.equal(hello.positions[0].src, "vehicle");
  assert.equal(hello.trails.alice[0].src, "vehicle");
  assert.equal(Object.hasOwn(hello.trails.alice[0], "acc"), false);
});

test("위치 stream별 중복·역순과 handle별 400ms 제한은 독립적으로 유지한다", () => {
  const store = new RoomLocationStore(() => 0);
  follow(store);
  store.accept("ROOM", { ...sample, seq: 100 }, 0);
  assert.deepEqual(store.accept("ROOM", { ...sample, stream: "1111111111111111" }, 399), { ok: false, reason: "rate" });
  assert.deepEqual(store.accept("ROOM", { ...sample, stream: "1111111111111111" }, 400), { ok: true, dropped: false });
  const revision = store.revision("ROOM");
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 99 }, 800), { ok: true, dropped: true });
  assert.equal(store.revision("ROOM"), revision);
  assert.deepEqual(store.snapshot("ROOM").trails.alice.map((fix) => fix.seq), [100, 0]);
  store.clear("ROOM");
  assert.deepEqual(store.accept("ROOM", sample, 1200), { ok: true, dropped: false });
});

test("C5 pending에는 follower·trail이 없고 수락 시 ID를 보존한다", () => {
  const store = new RoomLocationStore(() => 0);
  const pending = store.requestFollow("ROOM", "bob", "alice", "보비");
  assert.equal(pending.accepted, false);
  assert.equal(store.targetOf("ROOM", "bob"), null);
  assert.equal(store.pendingOf("ROOM", "bob"), "alice");
  assert.deepEqual(store.snapshot("ROOM").trails, {});
  assert.equal(store.requestsFor("ROOM", "alice")[0].displayName, "보비");
  assert.equal(store.respondFollow("ROOM", "alice", "wrong", true), null);
  store.respondFollow("ROOM", "alice", pending.requestId, true);
  assert.equal(store.pendingOf("ROOM", "bob"), null);
  assert.equal(store.targetOf("ROOM", "bob"), "alice");
  assert.equal(store.relationOf("ROOM", "bob")?.requestId, pending.requestId);
  assert.equal(store.requestFollow("ROOM", "charlie", "alice").accepted, true);
  assert.ok(store.revision("ROOM") > pending.revision);
});

test("C7 7200점 상한·마지막 팔로워 정리·수신자별 trail·사본 격리를 지킨다", () => {
  const store = new RoomLocationStore(() => 0);
  follow(store);
  follow(store, "ROOM", "charlie", "alice");
  follow(store, "ROOM", "alice", "bob");
  for (let seq = 0; seq < LOCATION_TRAIL_LIMIT + 5; seq++) {
    store.accept("ROOM", { ...sample, seq }, seq * 400);
    store.accept("ROOM", { ...sample, handle: "bob", seq }, seq * 400);
  }
  const snapshot = store.snapshot("ROOM", "bob");
  assert.deepEqual(Object.keys(snapshot.trails), ["alice"]);
  assert.equal(snapshot.trails.alice.length, 7200);
  assert.equal(snapshot.trails.alice[0].seq, 5);
  snapshot.positions[0].lat = 0;
  snapshot.trails.alice[0].seq = -1;
  assert.equal(store.position("ROOM", "alice")?.lat, sample.lat);
  assert.equal(store.snapshot("ROOM").trails.alice[0].seq, 5);
  store.unfollow("ROOM", "bob");
  assert.equal(store.snapshot("ROOM").trails.alice.length, 7200);
  store.unfollow("ROOM", "charlie");
  assert.equal(store.snapshot("ROOM").trails.alice, undefined);
  assert.equal(store.snapshot("ROOM").trails.bob.length, 7200);
});

test("C3 stale 표본은 sweep 전에도 snapshot·position에 노출하지 않는다", () => {
  let now = 0;
  const store = new RoomLocationStore(() => now);
  follow(store);
  store.accept("ROOM", sample);
  now = LOCATION_STALE_MS - 1;
  assert.equal(store.snapshot("ROOM").positions.length, 1);
  now++;
  assert.deepEqual(store.snapshot("ROOM"), { positions: [], trails: {} });
  assert.equal(store.position("ROOM", "alice"), undefined);
  assert.deepEqual(store.stale(), [{ code: "ROOM", handle: "alice" }]);
});

test("C1 라우터가 위험한 seq와 NaN JSON 값을 400으로 거른다", async (t) => {
  const { api } = fixture(t, false);
  for (const seq of [1e100, 2 ** 53, -1, NaN]) {
    assert.equal((await api("POST", "/location", "alice", { ...sample, seq })).status, 400);
  }
  assert.equal((await api("POST", "/location", "alice", sample)).status, 202);
});

test("위치 API 인증·멤버·사칭 방어와 no-store를 유지한다", async (t) => {
  const { api } = fixture(t);
  for (const [method, action] of [["POST", "/location"], ["GET", "/positions"], ["DELETE", "/location"]]) {
    assert.equal((await api(method, action, "outsider", method === "POST" ? sample : undefined)).status, 403);
    assert.equal((await api(method, action, "unknown", method === "POST" ? sample : undefined)).status, 401);
  }
  await api("POST", "/location", "alice", { ...sample, handle: "bob", receivedAt: -1 });
  const snapshot = await api("GET", "/positions", "bob");
  assert.equal(snapshot.body.positions[0].handle, "alice");
  assert.equal(snapshot.response.headers.get("cache-control"), "no-store");
  assert.equal((await api("POST", "/location", "alice", { ...sample, seq: 1 })).status, 429);
});

for (const disconnected of ["alice", "bob"]) {
  test(`C4 ${disconnected} 마지막 소켓 유예 내 재구독은 위치·관계·7200점 궤적을 보존한다`, async (t) => {
    t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
    const { send, hub, locations } = fixture(t);
    for (let seq = 0; seq < 7200; seq++) locations.accept("ABC234", { ...sample, seq }, Date.now() + seq * 400);
    const original = send("GET", "/v1/rooms/ABC234/events", disconnected);
    const second = send("GET", "/v1/rooms/ABC234/events", disconnected);
    original.emit("close");
    assert.equal(locations.disconnectedAt("ABC234", disconnected), undefined);
    second.emit("close");
    assert.equal(hub.subscriberCount("ABC234", disconnected), 0);
    assert.equal(locations.disconnectedAt("ABC234", disconnected), Date.now());
    t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS - 1);
    const hello = send("GET", "/v1/rooms/ABC234/events", disconnected).events()[0].data;
    assert.equal(hello.positions.length, 1);
    assert.equal(locations.disconnectedAt("ABC234", disconnected), undefined);
    if (disconnected === "bob") {
      assert.equal(hello.followTarget, "alice");
      assert.equal(hello.trails.alice.length, 7200);
    }
    t.mock.timers.tick(2);
    assert.equal(locations.targetOf("ABC234", "bob"), "alice");
    assert.equal(locations.snapshot("ABC234").trails.alice.length, 7200);
  });
}

test("M7 SSE가 끊겨도 위치 수신이 계속되면 반복 유예 뒤 공유·관계·궤적을 보존한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, hub, locations } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  alice.emit("close");
  const disconnectedAt = locations.disconnectedAt("ABC234", "alice");
  for (let seq = 1; seq <= 4; seq++) {
    t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS - 1000);
    assert.equal((await api("POST", "/location", "alice", { ...sample, seq })).status, 202);
    t.mock.timers.tick(1000);
    assert.equal(hub.subscriberCount("ABC234", "alice"), 0);
    assert.equal(locations.targetOf("ABC234", "bob"), "alice");
    assert.equal(locations.position("ABC234", "alice")?.seq, seq);
    assert.equal(locations.snapshot("ABC234").trails.alice.length, seq + 1);
    assert.equal(locations.disconnectedAt("ABC234", "alice"), disconnectedAt);
  }
  assert.equal(bob.events().some((e) => e.name === "location-stopped"), false);
});

test("다른 토큰 SSE가 남은 로그아웃은 공유·팔로워 관계·궤적을 변경하지 않는다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, hub, locations, db, users, tokens } = fixture(t);
  const original = send("GET", "/v1/rooms/ABC234/events", "alice");
  const originalToken = tokens.get("alice")!;
  const otherToken = issueToken(db, users[0].id);
  tokens.set("alice", otherToken);
  const survivor = send("GET", "/v1/rooms/ABC234/events", "alice");
  // Device replacement clears the old consent relationship. Recreate the
  // survivor's relationship explicitly before testing the old token's logout.
  const renewed = locations.requestFollow("ABC234", "bob", "alice");
  locations.respondFollow("ABC234", "alice", renewed.requestId, true);
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  const before = locations.snapshot("ABC234");
  const revision = locations.revision("ABC234");
  tokens.set("alice", originalToken);
  const response = send("POST", "/v1/auth/logout", "alice");
  await new Promise<void>((resolve) => response.once("finish", resolve));
  assert.equal(response.statusCode, 204);
  assert.equal(original.writableEnded, true);
  assert.equal(survivor.writableEnded, false);
  assert.equal(hub.subscriberCount("ABC234", "alice"), 1);
  assert.equal(locations.disconnectedAt("ABC234", "alice"), undefined);
  assert.equal(locations.targetOf("ABC234", "bob"), "alice");
  assert.deepEqual(locations.snapshot("ABC234"), before);
  assert.equal(locations.revision("ABC234"), revision);
  tokens.set("alice", otherToken);
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS);
  assert.equal((await api("POST", "/location", "alice", { ...sample, seq: 1 })).status, 202);
  assert.equal(locations.snapshot("ABC234").trails.alice.length, 2);
  assert.equal(bob.events().some((event) => event.name === "follow-response" || event.name === "location-stopped"), false);
});

for (const hadSse of [false, true]) {
  test(`송신 기기 로그아웃은 ${hadSse ? "SSE를 닫고" : "SSE 없이도"} 즉시 정리하며 다른 토큰은 빈 자리 resume으로 복구한다`, async (t) => {
    t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
    const { api, send, hub, locations, db, room, users, tokens } = fixture(t);
    const otherToken = issueToken(db, users[0].id);
    const original = hadSse ? send("GET", "/v1/rooms/ABC234/events", "alice") : undefined;
    const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
    const requestId = locations.relationOf(room.code, "bob")!.requestId;
    await api("POST", "/location", "alice", sample);
    const response = send("POST", "/v1/auth/logout", "alice");
    await new Promise<void>((resolve) => response.once("finish", resolve));
    assert.equal(response.statusCode, 204);
    if (original) assert.equal(original.writableEnded, true);
    assert.equal(hub.subscriberCount(room.code, "alice"), 0);
    assert.equal(locations.targetOf(room.code, "bob"), null);
    assert.deepEqual(locations.snapshot(room.code), { positions: [], trails: {} });
    assert.equal(locations.disconnectedAt(room.code, "alice"), undefined);
    assert.equal(isRoomMember(db, room.id, users[0].id), true);
    assert.deepEqual(bob.events().filter((event) => event.name === "follow-response").map((event) => event.data), [{
      requestId, requester: "bob", target: "alice", accepted: false, revision: locations.revision(room.code), reason: "stopped",
    }]);
    tokens.set("alice", otherToken);
    const pending = await api("POST", "/location", "alice", sample);
    assert.equal(pending.status, 503);
    assert.equal(pending.body.error.code, "SENDER_UNAVAILABLE");
    assert.equal(hub.hasSender(room.code, "alice"), false);
    const resumed = send("GET", "/v1/rooms/ABC234/events?resume=1", "alice");
    assert.equal(resumed.statusCode, 200);
    assert.equal(resumed.events()[0].name, "hello");
    assert.equal(hub.isSender(room.code, "alice", tokenHash(otherToken)), true);
    assert.equal((await api("POST", "/location", "alice", sample)).status, 202);
    assert.equal(locations.targetOf(room.code, "bob"), null); // no implicit consent restoration
    t.mock.timers.tick(LOCATION_STALE_MS);
    assert.equal(locations.position(room.code, "alice"), undefined);
    assert.deepEqual(bob.events().filter((event) => event.name === "location-stopped").map((event) => event.data.reason), ["stopped", "stale"]);
  });
}

test("다른 유효 토큰이 있어도 송신 기기 로그아웃은 표본 없는 관계도 즉시 정리한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { send, locations, db, room, users } = fixture(t);
  issueToken(db, users[0].id);
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  const response = send("POST", "/v1/auth/logout", "alice");
  await new Promise<void>((resolve) => response.once("finish", resolve));
  assert.equal(response.statusCode, 204);
  assert.equal(locations.targetOf(room.code, "bob"), null);
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS);
  assert.deepEqual(bob.events().filter((event) => event.name === "follow-response").map((event) => event.data.reason), ["stopped"]);
});

test("M7 SSE와 위치가 모두 끊기면 유예가 아닌 기존 sweep이 stale로 정리한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations, db, room, users } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  // sweep과 유예 만료를 어긋나게 해 stale 직후에도 left가 먼저 나가지 않는지 본다.
  t.mock.timers.tick(5000);
  await api("POST", "/location", "alice", sample);
  alice.emit("close");
  for (let elapsed = 0; elapsed < LOCATION_STALE_MS; elapsed += LOCATION_DISCONNECT_GRACE_MS) {
    t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS - 5000);
    t.mock.timers.tick(5000);
    assert.equal(locations.targetOf("ABC234", "bob"), "alice");
    assert.equal(bob.events().some((e) => e.name === "location-stopped"), false);
  }
  t.mock.timers.tick(25000);
  assert.deepEqual(locations.snapshot("ABC234"), { positions: [], trails: {} });
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.equal(locations.disconnectedAt("ABC234", "alice"), undefined);
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.deepEqual(bob.events().filter((e) => e.name === "location-stopped").map((e) => e.data.reason), ["stale"]);
  t.mock.timers.tick(LOCATION_STALE_MS);
  assert.equal(bob.events().filter((e) => e.name === "location-stopped").length, 1);
});

test("M7 공유하지 않는 멤버는 30초 유예 만료에 left로 정리하고 DB 멤버십은 보존한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations, db, room, users } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  bob.emit("close");
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS - 1);
  assert.equal(locations.targetOf("ABC234", "bob"), "alice");
  t.mock.timers.tick(1);
  assert.equal(locations.position("ABC234", "alice")?.seq, 0);
  assert.deepEqual(locations.snapshot("ABC234").trails, {});
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.equal(locations.disconnectedAt("ABC234", "bob"), undefined);
  assert.equal(isRoomMember(db, room.id, users[1].id), true);
  assert.ok(alice.events().some((e) => e.name === "location-stopped" && e.data.handle === "bob" && e.data.reason === "left"));
});

test("M7 중지 전 수신 시각은 표본 없는 새 공유의 유예를 연장하지 않는다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  await api("DELETE", "/location", "alice");
  const pending = await api("POST", "/follow", "bob", { target: "alice" });
  await api("POST", "/follow/respond", "alice", { requestId: pending.body.requestId, accepted: true });
  alice.emit("close");
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS);
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.equal(locations.disconnectedAt("ABC234", "alice"), undefined);
  assert.equal(bob.events().filter((e) => e.name === "location-stopped").at(-1)?.data.reason, "left");
});

test("C3 주기 sweep은 90초 위치와 관계를 stale로 삭제한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations } = fixture(t);
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  t.mock.timers.tick(89999);
  assert.equal(locations.targetOf("ABC234", "bob"), "alice");
  t.mock.timers.tick(1);
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.ok(bob.events().some((e) => e.name === "location-stopped" && e.data.reason === "stale"));
  assert.deepEqual(locations.stale(), []);
});

test("요청자 위치만 stale이면 살아 있는 SSE에 requester-stale을 한 번 보내고 관계·궤적을 삭제한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, hub, locations, room } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  const requestId = locations.relationOf(room.code, "bob")!.requestId;
  await api("POST", "/location", "alice", sample);
  await api("POST", "/location", "bob", sample);
  t.mock.timers.tick(LOCATION_STALE_MS - 1);
  await api("POST", "/location", "alice", { ...sample, seq: 1 });
  assert.equal(locations.targetOf(room.code, "bob"), "alice");
  t.mock.timers.tick(1);
  const revision = locations.revision(room.code);
  assert.equal(hub.subscriberCount(room.code, "bob"), 1);
  assert.equal(locations.relationOf(room.code, "bob"), undefined);
  assert.equal(locations.isSharing(room.code, "bob"), false);
  assert.equal(locations.position(room.code, "alice")?.seq, 1);
  assert.deepEqual(locations.snapshot(room.code).trails, {});
  assert.deepEqual(bob.events().filter((event) => event.name === "follow-response").map((event) => event.data), [{
    requestId, requester: "bob", target: "alice", accepted: false, revision, reason: "requester-stale",
  }]);
  assert.deepEqual(alice.events().filter((event) => event.name === "follow-cancelled").map((event) => event.data), [{
    requestId, requester: "bob", reason: "cancelled", revision,
  }]);
  assert.equal(bob.events().some((event) => event.name === "location-stopped"), false);
  await api("GET", "/positions", "bob");
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS);
  assert.equal(bob.events().filter((event) => event.name === "follow-response").length, 1);
  assert.equal(alice.events().filter((event) => event.name === "follow-cancelled").length, 1);
});

test("요청자 명시적 중지는 outgoing 종료 응답의 stopped 사유를 보존한다", async (t) => {
  const { api, send, locations, room } = fixture(t);
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  const requestId = locations.relationOf(room.code, "bob")!.requestId;
  assert.equal((await api("DELETE", "/location", "bob")).status, 202);
  assert.deepEqual(bob.events().filter((event) => event.name === "follow-response").map((event) => event.data), [{
    requestId, requester: "bob", target: "alice", accepted: false, revision: locations.revision(room.code), reason: "stopped",
  }]);
  await api("DELETE", "/location", "bob");
  assert.equal(bob.events().filter((event) => event.name === "follow-response").length, 1);
});

test("C5/C6 pending hello·displayName·ID 일치·수락 전환을 검증한다", async (t) => {
  const { api, send, locations } = fixture(t, false);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  const result = await api("POST", "/follow", "bob", { target: "alice" });
  const id = result.body.requestId;
  assert.equal(result.body.accepted, false);
  assert.equal(typeof result.body.revision, "number");
  assert.ok(alice.events().some((e) => e.name === "follow-request" && e.data.requestId === id && e.data.displayName === "bob"));
  const hello = send("GET", "/v1/rooms/ABC234/events", "bob").events()[0].data;
  assert.equal(hello.followTarget, null);
  assert.equal(hello.pendingFollow, "alice");
  assert.equal(hello.followRequestId, id);
  assert.deepEqual(hello.trails, {});
  const targetHello = send("GET", "/v1/rooms/ABC234/events", "alice").events()[0].data;
  assert.equal(targetHello.followRequests[0].requestId, id);
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: "unknown", accepted: true })).status, 404);
  assert.equal((await api("POST", "/follow/respond", "bob", { requestId: id, accepted: true })).status, 404);
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: id, accepted: true })).status, 202);
  assert.equal(locations.targetOf("ABC234", "bob"), "alice");
  assert.ok(bob.events().some((e) => e.name === "follow-response" && e.data.requestId === id && e.data.requester === "bob" && e.data.accepted));
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: id, accepted: true })).status, 404);
});

test("C6 대상 유예 중 pending을 유지하고 hello로 재전달한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send } = fixture(t, false);
  send("GET", "/v1/rooms/ABC234/events", "alice").emit("close");
  const result = await api("POST", "/follow", "bob", { target: "alice" });
  t.mock.timers.tick(29000);
  const hello = send("GET", "/v1/rooms/ABC234/events", "alice").events()[0].data;
  assert.equal(hello.followRequests[0].requestId, result.body.requestId);
});

test("C7 변경 없는 재요청은 revision·SSE·바이트 수를 늘리지 않는다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations } = fixture(t, false);
  const a = send("GET", "/v1/rooms/ABC234/events", "alice");
  const b = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  const first = await api("POST", "/follow", "bob", { target: "alice" });
  assert.equal(first.body.accepted, true);
  assert.equal(a.events().filter((e) => e.name === "trail" || e.name === "trails").length, 0);
  assert.equal(b.events().filter((e) => e.name === "trail").length, 1);
  const before = a.chunks.length + b.chunks.length;
  const revision = locations.revision("ABC234");
  for (let index = 0; index < 3; index++) {
    t.mock.timers.tick(1000);
    assert.deepEqual((await api("POST", "/follow", "bob", { target: "alice" })).body, first.body);
  }
  assert.equal(a.chunks.length + b.chunks.length, before);
  assert.equal(locations.revision("ABC234"), revision);
});

test("C7 follow/respond/unfollow는 handle당 합산 1초 제한이다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api } = fixture(t, false);
  const pending = await api("POST", "/follow", "bob", { target: "alice" });
  assert.equal((await api("POST", "/follow", "bob", { target: "alice" })).status, 429);
  assert.equal((await api("DELETE", "/follow", "bob")).status, 429);
  await api("POST", "/follow", "alice", { target: "bob" });
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: pending.body.requestId, accepted: false })).status, 429);
  t.mock.timers.tick(1000);
  assert.equal((await api("DELETE", "/follow", "bob")).status, 202);
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: pending.body.requestId, accepted: true })).status, 404);
});

for (const action of ["leave", "stop", "logout"]) {
  test(`명시적 ${action}는 유예 없이 정리하고 반복 중지는 방송하지 않는다`, async (t) => {
    const { api, send, locations, db, users } = fixture(t);
    const requestId = locations.relationOf("ABC234", "bob")!.requestId;
    send("GET", "/v1/rooms/ABC234/events", "alice");
    const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
    await api("POST", "/location", "alice", sample);
    if (action === "logout") {
      issueToken(db, users[0].id, new Date("2000-01-01T00:00:00.000Z"));
      revokeToken(db, issueToken(db, users[0].id));
      const response = send("POST", "/v1/auth/logout", "alice");
      await new Promise<void>((resolve) => response.once("finish", resolve));
      assert.equal(response.statusCode, 204);
    } else await api(action === "leave" ? "POST" : "DELETE", action === "leave" ? "/leave" : "/location");
    assert.equal(locations.targetOf("ABC234", "bob"), null);
    assert.deepEqual(locations.snapshot("ABC234"), { positions: [], trails: {} });
    assert.equal(locations.disconnectedAt("ABC234", "alice"), undefined);
    assert.deepEqual(bob.events().filter((event) => event.name === "follow-response").map((event) => event.data), [{
      requestId, requester: "bob", target: "alice", accepted: false,
      revision: locations.revision("ABC234"), reason: action === "leave" ? "left" : "stopped",
    }]);
    if (action === "stop") {
      const count = bob.events().length;
      await api("DELETE", "/location");
      assert.equal(bob.events().length, count);
    }
  });
}

test("F4 비멤버 leave 403, 현재·전 멤버 반복 leave 204와 빈 방 삭제", async (t) => {
  const { api, db, room, users, locations, hub, send } = fixture(t);
  send("GET", "/v1/rooms/ABC234/events", "alice");
  await api("POST", "/location", "alice", sample);
  await api("PUT", "/ready", "alice", { ready: true });
  assert.equal((await api("POST", "/leave", "outsider")).status, 403);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  leaveRoom(db, room.id, users[0].id); // 이전 버전에서 남은 빈 방
  assert.equal((await api("POST", "/leave", "outsider")).status, 403);
  assert.ok(findRoomByCode(db, room.code));
  assert.equal((await api("POST", "/leave", "alice")).status, 204);
  assert.equal(findRoomByCode(db, room.code), undefined);
  assert.deepEqual(locations.snapshot(room.code), { positions: [], trails: {} });
  assert.equal(hub.subscriberCount(room.code), 0);
  assert.equal(hub.hasSender(room.code, "alice"), false);
  assert.equal(hub.hasSender(room.code, "bob"), false);
});

test("D5 연결·송신 기기가 전혀 없는 계정도 join 없이 leave할 수 있다", async (t) => {
  const { api, db, room, users, hub } = fixture(t, false);
  hub.forgetSender(room.code, "alice");
  hub.forgetSender(room.code, "bob");
  assert.equal(hub.subscriberCount(room.code), 0);
  assert.equal((await api("POST", "/leave", "outsider")).status, 403);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  assert.equal(isRoomMember(db, room.id, users[1].id), false);
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  assert.equal((await api("POST", "/leave", "alice")).status, 204);
  assert.equal(findRoomByCode(db, room.code), undefined);
});

test("D5 송신 기기가 없는 현재 멤버의 leave는 204와 모든 잔여 상태 정리를 수행한다", async (t) => {
  const { api, db, room, users, locations, readiness, hub, send } = fixture(t);
  send("GET", `/v1/rooms/${room.code}/events`, "alice");
  const bob = send("GET", `/v1/rooms/${room.code}/events`, "bob");
  await api("POST", "/location", "alice", sample);
  await api("PUT", "/ready", "alice", { ready: true });
  hub.forgetSender(room.code, "alice");
  hub.queueSignal(room.code, "alice", "signal", { from: "bob", payload: "to-left" });
  hub.queueSignal(room.code, "bob", "signal", { from: "alice", payload: "from-left" });
  assert.equal(hub.hasSender(room.code, "alice"), false);
  assert.equal((await api("POST", "/leave", "alice")).status, 204);
  assert.equal(isRoomMember(db, room.id, users[0].id), false);
  assert.equal(readiness.isReady(room.code, "alice"), false);
  assert.deepEqual(locations.snapshot(room.code), { positions: [], trails: {} });
  assert.equal(locations.targetOf(room.code, "bob"), null);
  assert.equal(locations.disconnectedAt(room.code, "alice"), undefined);
  assert.equal(hub.subscriberCount(room.code, "alice"), 0);
  assert.equal(hub.hasSender(room.code, "alice"), false);
  assert.equal(hub.replaySignals(room.code, "alice", () => assert.fail("recipient backlog survived")), 0);
  assert.equal(hub.replaySignals(room.code, "bob", () => assert.fail("sender backlog survived")), 0);
  assert.ok(bob.events().some((event) => event.name === "member-left" && event.data.handle === "alice"));
  assert.equal((await api("POST", "/leave", "alice")).status, 204);
  // A last member without an owner also removes the room itself.
  hub.forgetSender(room.code, "bob");
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  assert.equal(findRoomByCode(db, room.code), undefined);
  assert.equal(hub.subscriberCount(room.code), 0);
  assert.equal(readiness.revision(room.code), 0);
});

test("D5 다른 기기가 송신자이면 leave는 409이며 현재 상태를 보존한다", async (t) => {
  const { api, db, room, users, locations, readiness, hub, tokens } = fixture(t);
  hub.claim(room.code, "alice", "other-device", tokenHash(tokens.get("alice")!));
  readiness.set(room.code, "alice", true);
  locations.accept(room.code, sample);
  const result = await api("POST", "/leave", "alice");
  assert.equal(result.status, 409);
  assert.equal(result.body.error.code, "DEVICE_REPLACED");
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.equal(readiness.isReady(room.code, "alice"), true);
  assert.equal(locations.position(room.code, "alice")?.seq, sample.seq);
  assert.equal(hub.isSender(room.code, "alice", "other-device"), true);
});

test("D5 leave 본문을 기다리는 동안 빈 자리를 다른 기기가 얻으면 409다", async (t) => {
  const { app, db, room, users, hub, tokens } = fixture(t, false);
  hub.forgetSender(room.code, "alice");
  const request = new IncomingMessage(new Socket());
  request.method = "POST";
  request.url = `/v1/rooms/${room.code}/leave`;
  request.headers = { authorization: `Bearer ${tokens.get("alice")}`, "content-type": "application/json" };
  const response = new Response();
  t.after(() => response.destroy());
  app(request, response as unknown as ServerResponse);
  hub.claim(room.code, "alice", "new-device", tokenHash(tokens.get("alice")!));
  request.push("{}");
  request.push(null);
  await new Promise<void>((resolve) => response.once("finish", resolve));
  assert.equal(response.statusCode, 409);
  assert.equal(JSON.parse(Buffer.concat(response.chunks).toString()).error.code, "DEVICE_REPLACED");
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.equal(hub.isSender(room.code, "alice", "new-device"), true);
});

test("생성·조회·me의 leader는 같은 handle이다", async (t) => {
  const { api, send } = fixture(t);
  assert.equal((await api("GET", "")).body.room.leader, "alice");
  for (const [method, path, body] of [["GET", "/v1/me", undefined], ["POST", "/v1/rooms", {}]] as const) {
    if (method === "POST") assert.equal((await api("POST", "/leave", "alice")).status, 204);
    const response = send(method, path, "alice", body);
    await new Promise<void>((resolve) => response.once("finish", resolve));
    assert.equal(response.statusCode, method === "POST" ? 201 : 200);
    assert.equal(JSON.parse(Buffer.concat(response.chunks).toString()).room.leader, "alice");
  }
});

test("위치 POST 액세스 로그 대신 분당 집계하며 드롭은 SSE로 반사하지 않는다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 100000 });
  const { api, send } = fixture(t);
  const writes: string[] = [];
  const originalWrite = process.stdout.write.bind(process.stdout);
  t.mock.method(process.stdout, "write", (chunk: string | Uint8Array, ...args: unknown[]) => {
    // node:test의 바이너리 리포터 프레임은 그대로 전달한다.
    if (typeof chunk !== "string") return Reflect.apply(originalWrite, process.stdout, [chunk, ...args]);
    writes.push(chunk);
    return true;
  });
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  await api("POST", "/location", "alice", { ...sample, seq: 1 });
  t.mock.timers.tick(400);
  const dropped = await api("POST", "/location", "alice", sample);
  assert.deepEqual(dropped.body, { accepted: true, dropped: true });
  assert.equal(bob.events().filter((event) => event.name === "location").length, 1);
  assert.deepEqual(writes, []);
  t.mock.timers.tick(59600);
  assert.deepEqual(writes, ["location: code=ABC234 accepted=1 dropped=1 rate=1\n"]);
  t.mock.timers.tick(60000);
  assert.equal(writes.length, 1);
});


for (const action of ["location", "follow", "follow/respond"]) {
  test(`${action}는 본문 대기 중 퇴장한 사용자를 다시 검사한다`, async (t) => {
    const { db, room, users, app, tokens } = fixture(t, false);
    const request = new IncomingMessage(new Socket());
    request.method = "POST";
    request.url = `/v1/rooms/ABC234/${action}`;
    request.headers = { authorization: `Bearer ${tokens.get("alice")}`, "content-type": "application/json" };
    const response = new Response();
    app(request, response as unknown as ServerResponse);
    leaveRoom(db, room.id, users[0].id);
    request.push(JSON.stringify(action === "location" ? sample : action === "follow" ? { target: "bob" } : { requestId: "r", accepted: true }));
    request.push(null);
    await new Promise<void>((resolve) => response.once("finish", resolve));
    assert.equal(response.statusCode, 403);
  });
}

test("pending 재요청은 방송 0, 공유 시작 뒤 같은 ID의 수락 전환만 알린다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send } = fixture(t, false);
  const a = send("GET", "/v1/rooms/ABC234/events", "alice");
  const b = send("GET", "/v1/rooms/ABC234/events", "bob");
  const first = await api("POST", "/follow", "bob", { target: "alice" });
  const count = a.events().length + b.events().length;
  t.mock.timers.tick(1000);
  assert.deepEqual((await api("POST", "/follow", "bob", { target: "alice" })).body, first.body);
  assert.equal(a.events().length + b.events().length, count);
  await api("POST", "/location", "alice", sample);
  t.mock.timers.tick(1000);
  const promoted = await api("POST", "/follow", "bob", { target: "alice" });
  assert.equal(promoted.body.requestId, first.body.requestId);
  assert.equal(promoted.body.accepted, true);
  assert.equal(a.events().at(-1)?.data.reason, "accepted");
  assert.equal(b.events().filter((event) => event.name === "trail").length, 1);
});

test("대상 전환·취소 후 재요청은 새 ID이며 이전 응답은 404다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, locations, room } = fixture(t, false);
  // Use the actual entry path: a DB-only insert omits the sender registration.
  assert.equal((await api("POST", "/join", "outsider")).status, 200);
  const first = await api("POST", "/follow", "bob", { target: "alice" });
  t.mock.timers.tick(1000);
  const switched = await api("POST", "/follow", "bob", { target: "outsider" });
  assert.notEqual(switched.body.requestId, first.body.requestId);
  assert.equal(locations.requestsFor(room.code, "alice").length, 0);
  assert.equal((await api("POST", "/follow/respond", "alice", { requestId: first.body.requestId, accepted: true })).status, 404);
  t.mock.timers.tick(1000);
  await api("DELETE", "/follow", "bob");
  t.mock.timers.tick(1000);
  const again = await api("POST", "/follow", "bob", { target: "outsider" });
  assert.notEqual(again.body.requestId, switched.body.requestId);
  assert.equal((await api("POST", "/follow/respond", "outsider", { requestId: switched.body.requestId, accepted: true })).status, 404);
});
