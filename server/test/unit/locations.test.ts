import assert from "node:assert/strict";
import { IncomingMessage } from "node:http";
import type { ServerResponse } from "node:http";
import { Socket } from "node:net";
import { Writable } from "node:stream";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { issueToken } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { LOCATION_TRAIL_LIMIT, LOCATION_DISCONNECT_GRACE_MS, LOCATION_STALE_MS, RoomLocationStore } from "../../src/locations.ts";
import { RoomEventHub } from "../../src/rooms.ts";
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
  const app = createApp({ db, hub, locations });
  const users = ["alice", "bob", "outsider"].map((handle) =>
    createUser(db, { handle, displayName: handle, passwordHash: "unused" })!);
  const tokens = new Map(users.map((user) => [user.handle, issueToken(db, user.id)]));
  const room = createRoom(db, { code: "ABC234", name: "위치 공유", createdBy: users[0].id })!;
  joinRoom(db, room.id, users[1].id);
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
  return { db, hub, locations, room, users, send, api, app, tokens };
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

test("C4 유예 만료는 left로 정리하고 DB 멤버십은 보존한다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: 100000 });
  const { api, send, locations, db, room, users } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  alice.emit("close");
  t.mock.timers.tick(LOCATION_DISCONNECT_GRACE_MS);
  assert.deepEqual(locations.snapshot("ABC234"), { positions: [], trails: {} });
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.ok(bob.events().some((e) => e.name === "location-stopped" && e.data.reason === "left"));
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
    const { api, send, locations } = fixture(t);
    send("GET", "/v1/rooms/ABC234/events", "alice");
    const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
    await api("POST", "/location", "alice", sample);
    if (action === "logout") {
      const response = send("POST", "/v1/auth/logout", "alice");
      await new Promise<void>((resolve) => response.once("finish", resolve));
    } else await api(action === "leave" ? "POST" : "DELETE", action === "leave" ? "/leave" : "/location");
    assert.equal(locations.targetOf("ABC234", "bob"), null);
    assert.deepEqual(locations.snapshot("ABC234"), { positions: [], trails: {} });
    assert.equal(locations.disconnectedAt("ABC234", "alice"), undefined);
    if (action === "stop") {
      const count = bob.events().length;
      await api("DELETE", "/location");
      assert.equal(bob.events().length, count);
    }
  });
}

test("F4 비멤버 leave 403, 현재·전 멤버 반복 leave 204와 빈 방 삭제", async (t) => {
  const { api, db, room, users, locations } = fixture(t);
  assert.equal((await api("POST", "/leave", "outsider")).status, 403);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  assert.equal((await api("POST", "/leave", "bob")).status, 204);
  leaveRoom(db, room.id, users[0].id); // 이전 버전에서 남은 빈 방
  assert.equal((await api("POST", "/leave", "outsider")).status, 403);
  assert.ok(findRoomByCode(db, room.code));
  assert.equal((await api("POST", "/leave", "alice")).status, 204);
  assert.equal(findRoomByCode(db, room.code), undefined);
  assert.deepEqual(locations.snapshot(room.code), { positions: [], trails: {} });
});

test("생성·조회·me의 leader는 같은 handle이다", async (t) => {
  const { api, send } = fixture(t);
  assert.equal((await api("GET", "")).body.room.leader, "alice");
  for (const [method, path, body] of [["GET", "/v1/me", undefined], ["POST", "/v1/rooms", {}]] as const) {
    const response = send(method, path, "alice", body);
    await new Promise<void>((resolve) => response.once("finish", resolve));
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
  const { api, locations, db, room, users } = fixture(t, false);
  joinRoom(db, room.id, users[2].id);
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
