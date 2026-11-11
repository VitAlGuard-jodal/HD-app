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
import { LOCATION_TRAIL_LIMIT, RoomLocationStore } from "../../src/locations.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { createRoom, createUser, findRoomByCode, isRoomMember, joinRoom } from "../../src/store.ts";

const sample = { handle: "alice", stream: "0123456789abcdef", lat: 37.5, lng: 127, acc: 3, speed: 2, heading: 90, at: 1000, seq: 0 };

test("위치 표본은 필수 값·유한수·범위·정수 순번을 검증한다", () => {
  const store = new RoomLocationStore();
  for (const fix of [
    null, [], {}, { ...sample, handle: 1 }, { ...sample, handle: "" },
    ...[undefined, null, 123, "", "short", "0123456789abcdeg", "0123456789abcdef0"]
      .map((stream) => ({ ...sample, stream })),
    ...["lat", "lng", "at", "seq", "acc", "speed", "heading"].flatMap((field) =>
      [NaN, Infinity, -Infinity, "1", null].map((value) => ({ ...sample, [field]: value }))),
    ...[{ lat: 90.1 }, { lat: -90.1 }, { lng: 180.1 }, { lng: -180.1 },
      { acc: -1 }, { speed: -1 }, { heading: -1 }, { heading: 360.1 }, { seq: -.1 }, { seq: .5 }]
      .map((value) => ({ ...sample, ...value })),
  ]) {
    assert.deepEqual(store.accept("ROOM", fix, 0), { ok: false, reason: "invalid" });
  }
  assert.deepEqual(store.snapshot("ROOM"), { positions: [], trails: {} });
  assert.deepEqual(store.accept("ROOM", { ...sample, lat: -90, lng: 180, heading: 360, acc: 0, speed: 0 }, 0),
    { ok: true, dropped: false });
  assert.equal(store.snapshot("ROOM").positions[0].receivedAt, 0);
  assert.deepEqual(store.accept("OTHER", { handle: "bob", stream: sample.stream, lat: 90, lng: -180, at: 0, seq: 0 }, 0),
    { ok: true, dropped: false });
});

test("새 stream의 seq 0은 이전 stream 위치를 덮고 각 순번 공간은 보존한다", () => {
  const store = new RoomLocationStore();
  store.requestFollow("ROOM", "bob", "alice");
  const restarted = { ...sample, stream: "fedcba9876543210", seq: 0, lat: 38 };
  store.accept("ROOM", { ...sample, seq: 100 }, 0);
  // stream을 바꾸어도 handle별 속도 제한은 우회하지 못한다.
  assert.deepEqual(store.accept("ROOM", restarted, 399), { ok: false, reason: "rate" });
  assert.deepEqual(store.accept("ROOM", restarted, 400), { ok: true, dropped: false });
  assert.equal(store.snapshot("ROOM").positions.length, 1);
  assert.equal(store.position("ROOM", "alice")?.stream, restarted.stream);
  assert.equal(store.position("ROOM", "alice")?.lat, 38);
  assert.deepEqual(store.snapshot("ROOM").trails.alice?.map((fix) => [fix.stream, fix.seq]),
    [[sample.stream, 100], [restarted.stream, 0]]);
  assert.deepEqual(store.accept("ROOM", restarted, 800), { ok: true, dropped: true });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 99 }, 1200), { ok: true, dropped: true });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 101 }, 1600), { ok: true, dropped: false });
  store.remove("ROOM", "alice");
  assert.deepEqual(store.accept("ROOM", { ...restarted, seq: 1 }, 2000), { ok: true, dropped: false });
});

test("400ms 미만은 제한하고 사용자·방별로 독립적으로 순번 역순을 버린다", () => {
  const store = new RoomLocationStore();
  store.requestFollow("ROOM", "bob", "alice");
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 3 }, 0), { ok: true, dropped: false });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 4 }, 399), { ok: false, reason: "rate" });
  assert.deepEqual(store.accept("ROOM", { ...sample, handle: "bob" }, 399), { ok: true, dropped: false });
  assert.deepEqual(store.accept("OTHER", sample, 399), { ok: true, dropped: false });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 3 }, 400), { ok: true, dropped: true });
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 2 }, 800), { ok: true, dropped: true });
  assert.equal(store.snapshot("ROOM").trails.alice?.length, 1);
  assert.equal(store.position("ROOM", "alice")?.seq, 3);
  assert.equal(store.position("ROOM", "alice")?.receivedAt, 0);
  assert.deepEqual(store.accept("ROOM", { ...sample, seq: 4 }, 1200), { ok: true, dropped: false });
});

test("팔로워가 있는 대상만 궤적을 쌓고 최신 7200점과 사용자별 최신 위치를 남긴다", () => {
  const store = new RoomLocationStore();
  store.requestFollow("ROOM", "bob", "alice");
  for (let seq = 0; seq < LOCATION_TRAIL_LIMIT + 5; seq++) {
    store.accept("ROOM", { ...sample, seq }, seq * 400);
    store.accept("ROOM", { ...sample, handle: "bob", seq }, seq * 400);
  }
  const snapshot = store.snapshot("ROOM");
  assert.equal(snapshot.positions.length, 2);
  assert.deepEqual(Object.keys(snapshot.trails), ["alice"]);
  assert.equal(snapshot.trails.alice?.length, 7200);
  assert.equal(snapshot.trails.alice?.[0].seq, 5);
  assert.equal(snapshot.trails.alice?.at(-1)?.seq, 7204);
  assert.ok(snapshot.trails.alice?.every((fix) => fix.handle === "alice"));
});

test("위치 제거와 follow 관계 정리는 분리되고 clear는 순번·궤적까지 지운다", () => {
  const store = new RoomLocationStore();
  store.requestFollow("ROOM", "bob", "alice");
  store.accept("ROOM", sample, 0);
  store.accept("OTHER", sample, 0);
  const snapshot = store.snapshot("ROOM");
  snapshot.positions[0].lat = 0;
  snapshot.trails.alice[0].seq = 99;
  snapshot.trails.alice.length = 0;
  assert.equal(store.position("ROOM", "alice")?.lat, sample.lat);
  assert.equal(store.remove("ROOM", "alice"), true);
  assert.equal(store.remove("ROOM", "alice"), false);
  assert.deepEqual(store.snapshot("ROOM").positions, []);
  assert.equal(store.snapshot("ROOM").trails.alice?.[0].seq, 0);
  assert.deepEqual(store.accept("ROOM", sample, 400), { ok: true, dropped: true });
  store.clear("ROOM");
  store.clear("ROOM");
  assert.deepEqual(store.snapshot("ROOM"), { positions: [], trails: {} });
  assert.equal(store.snapshot("OTHER").positions.length, 1);
  assert.deepEqual(store.accept("ROOM", sample, 400), { ok: true, dropped: false });
});

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
  if (withFollow) locations.requestFollow(room.code, "bob", "alice");
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
  return { db, hub, locations, room, users, send, api };
}

test("POST 재실행 stream은 seq 0으로 저장되고 SSE와 hello에 그대로 전달된다", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 100000 });
  const { api, send } = fixture(t);
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", { ...sample, seq: 100 });
  t.mock.timers.tick(400);
  const restarted = { ...sample, stream: "1111111111111111", seq: 0 };
  assert.deepEqual((await api("POST", "/location", "alice", restarted)).body,
    { accepted: true, dropped: false });
  assert.equal(bob.events().at(-1)?.data.stream, restarted.stream);
  const snapshot = (await api("GET", "/positions", "bob")).body;
  assert.equal(snapshot.positions.length, 1);
  assert.equal(snapshot.positions[0].stream, restarted.stream);
  assert.equal(snapshot.trails.alice.length, 2);
  const hello = send("GET", "/v1/rooms/ABC234/events", "bob").events()[0].data;
  assert.deepEqual(hello.positions, snapshot.positions);
});

test("위치 POST/GET/DELETE는 멤버만 허용하고 본문으로 송신자를 사칭할 수 없다", async (t) => {
  const { api } = fixture(t);
  for (const [method, action] of [["POST", "/location"], ["DELETE", "/location"], ["GET", "/positions"]]) {
    assert.equal((await api(method, action, "outsider", method === "POST" ? sample : undefined)).status, 403);
    assert.equal((await api(method, action, "unknown", method === "POST" ? sample : undefined)).status, 401);
  }
  assert.equal((await api("POST", "/location", "alice", { ...sample, lat: 91 })).status, 400);
  assert.deepEqual((await api("POST", "/location", "alice", { ...sample, handle: "bob", receivedAt: -1 })).body,
    { accepted: true, dropped: false });
  const snapshot = await api("GET", "/positions", "bob");
  assert.equal(snapshot.response.headers.get("cache-control"), "no-store");
  assert.equal(snapshot.body.positions[0].handle, "alice");
  assert.ok(snapshot.body.positions[0].receivedAt > 0);
  assert.deepEqual(Object.keys(snapshot.body.trails), ["alice"]);
  assert.equal((await api("POST", "/location", "alice", { ...sample, seq: 1 })).status, 429);
  assert.equal((await api("DELETE", "/location")).status, 202);
  const stopped = (await api("GET", "/positions")).body;
  assert.deepEqual(stopped.positions, []);
  assert.deepEqual(stopped.trails, {});
});

test("SSE 위치/중지는 송신자의 모든 연결을 제외하고 hello는 leader·스냅샷을 포함한다", async (t) => {
  const { api, send } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events");
  const aliceSecond = send("GET", "/v1/rooms/ABC234/events");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  assert.equal((await api("POST", "/location", "alice", sample)).status, 202);
  assert.deepEqual(alice.events().map((event) => event.name), ["hello"]);
  assert.deepEqual(aliceSecond.events().map((event) => event.name), ["hello"]);
  const received = bob.events().find((event) => event.name === "location")!.data;
  assert.deepEqual(received, { ...sample, receivedAt: received.receivedAt });
  const reconnect = send("GET", "/v1/rooms/ABC234/events", "bob");
  const hello = reconnect.events()[0].data;
  assert.equal(hello.leader, "alice");
  assert.equal(hello.self.handle, "bob");
  assert.equal(hello.members.length, 2);
  assert.deepEqual(hello.positions, [received]);
  assert.deepEqual(hello.trails, { alice: [received] });
  await api("DELETE", "/location");
  assert.ok(bob.events().some((event) => event.name === "location-stopped" && event.data.handle === "alice"));
  assert.deepEqual(alice.events().map((event) => event.name), ["hello", "follow-cancelled", "trails"]);
});

test("마지막 소켓 단절과 leave는 위치·follow·궤적을 지우고 DB 멤버십만 유지한다", async (t) => {
  const { api, send, hub, locations, db, room, users } = fixture(t);
  const alice = send("GET", "/v1/rooms/ABC234/events");
  send("GET", "/v1/rooms/ABC234/events");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  await api("POST", "/location", "alice", sample);
  alice.emit("close");
  assert.equal(locations.snapshot(room.code).positions.length, 1);
  hub.disconnectUser(room.code, "alice");
  assert.equal(locations.snapshot(room.code).positions.length, 0);
  assert.deepEqual(locations.snapshot(room.code).trails, {});
  assert.equal(isRoomMember(db, room.id, users[0].id), true);
  assert.ok(bob.events().some((event) => event.name === "location-stopped" && event.data.handle === "alice"));
  await api("POST", "/location", "bob", sample);
  await api("POST", "/leave", "bob");
  assert.deepEqual(locations.snapshot(room.code).positions, []);
  assert.deepEqual(locations.snapshot(room.code).trails, {});
  await api("POST", "/leave");
  assert.deepEqual(locations.snapshot(room.code), { positions: [], trails: {} });
  assert.equal(findRoomByCode(db, room.code), undefined);
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

test("follow는 방장과 무관하며 다중 대상·팔로워 수명과 독립된 7200점 상한을 지킨다", { timeout: 30_000 }, () => {
  const store = new RoomLocationStore();
  store.accept("ROOM", sample, 0);
  assert.deepEqual(store.snapshot("ROOM").trails, {});
  assert.equal(store.requestFollow("ROOM", "alice", "bob"), false);
  assert.equal(store.requestFollow("ROOM", "charlie", "bob"), false);
  assert.equal(store.requestFollow("ROOM", "bob", "alice"), true);
  assert.deepEqual(store.requestsFor("ROOM", "bob"), ["alice", "charlie"]);
  assert.equal(store.respondFollow("ROOM", "alice", "alice", true), null);
  assert.deepEqual(store.respondFollow("ROOM", "bob", "alice", true), ["alice", "charlie"]);
  assert.deepEqual(store.requestsFor("ROOM", "bob"), []);
  assert.equal(store.requestFollow("ROOM", "david", "bob"), true); // 첫 fix 이전에도 수락한 공유
  for (let seq = 1; seq <= 7205; seq++) {
    store.accept("ROOM", { ...sample, seq }, seq * 400);
    store.accept("ROOM", { ...sample, handle: "bob", seq }, seq * 400);
  }
  const snapshot = store.snapshot("ROOM");
  for (const handle of ["alice", "bob"]) {
    assert.equal(snapshot.trails[handle].length, 7200);
    assert.equal(snapshot.trails[handle][0].seq, 6);
  }
  store.unfollow("ROOM", "alice");
  store.unfollow("ROOM", "charlie");
  assert.equal(store.snapshot("ROOM").trails.bob.length, 7200);
  store.unfollow("ROOM", "david");
  assert.equal(store.snapshot("ROOM").trails.bob, undefined);
  assert.equal(store.snapshot("ROOM").trails.alice.length, 7200);
  assert.equal(store.position("ROOM", "bob")?.seq, 7205); // follow 중지는 공유를 끄지 않는다
});

test("follow 요청·거절·취소·이미 공유 중 수락·hello를 실제 라우터로 검증한다", { timeout: 30_000 }, async (t) => {
  const { api, send, locations } = fixture(t, false);
  const alice = send("GET", "/v1/rooms/ABC234/events", "alice");
  const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
  assert.equal((await api("POST", "/follow", "bob", { target: "alice" })).status, 202);
  assert.ok(alice.events().some((e) => e.name === "follow-request" && e.data.requester === "bob"));
  assert.equal((await api("POST", "/follow/respond", "alice", { requester: "bob", accepted: false })).status, 202);
  assert.ok(bob.events().some((e) => e.name === "follow-response" && e.data.target === "alice" && !e.data.accepted));
  assert.deepEqual(locations.snapshot("ABC234").trails, {});
  await api("POST", "/follow", "bob", { target: "alice" });
  await api("DELETE", "/follow", "bob");
  assert.equal((await api("POST", "/follow/respond", "alice", { requester: "bob", accepted: true })).status, 409);
  await api("POST", "/location", "alice", sample);
  const before = alice.events().filter((e) => e.name === "follow-request").length;
  await api("POST", "/follow", "bob", { target: "alice" });
  assert.equal(alice.events().filter((e) => e.name === "follow-request").length, before);
  assert.deepEqual(bob.events().at(-1), { name: "follow-response", data: { target: "alice", accepted: true } });
  const hello = send("GET", "/v1/rooms/ABC234/events", "bob").events()[0].data;
  assert.equal(hello.followTarget, "alice");
  assert.equal(hello.trails.alice.length, 1);
  assert.deepEqual(hello.trails, (await api("GET", "/positions", "bob")).body.trails);
  await api("DELETE", "/follow", "bob");
  assert.deepEqual(locations.snapshot("ABC234").trails, {});
  assert.equal(locations.snapshot("ABC234").positions.length, 1);
});

test("follow는 자신·외부인·잘못된 응답·퇴장한 요청자를 거른다", { timeout: 30_000 }, async (t) => {
  const { api, locations } = fixture(t, false);
  assert.equal((await api("POST", "/follow", "bob", { target: "bob" })).status, 400);
  assert.equal((await api("POST", "/follow", "bob", { target: "outsider" })).status, 403);
  for (const [method, action, body] of [
    ["POST", "/follow", { target: "alice" }], ["DELETE", "/follow", undefined],
    ["POST", "/follow/respond", { requester: "bob", accepted: true }],
  ] as const) assert.equal((await api(method, action, "outsider", body)).status, 403);
  await api("POST", "/follow", "bob", { target: "alice" });
  assert.equal((await api("POST", "/follow/respond", "alice", { requester: "bob", accepted: "true" })).status, 400);
  assert.equal((await api("POST", "/follow/respond", "bob", { requester: "alice", accepted: true })).status, 409);
  await api("POST", "/leave", "bob");
  assert.equal(locations.targetOf("ABC234", "bob"), null);
  assert.deepEqual(locations.snapshot("ABC234").trails, {});
  assert.equal((await api("POST", "/follow/respond", "alice", { requester: "bob", accepted: true })).status, 403);
});

for (const action of ["leave", "disconnect", "stop"]) {
  test(`${action}는 대상의 팔로워들에게 종료 응답을 보내고 관계·궤적을 정리한다`, { timeout: 30_000 }, async (t) => {
    const { api, send, hub, locations } = fixture(t, false);
    send("GET", "/v1/rooms/ABC234/events", "alice");
    const bob = send("GET", "/v1/rooms/ABC234/events", "bob");
    await api("POST", "/follow", "bob", { target: "alice" });
    await api("POST", "/follow/respond", "alice", { requester: "bob", accepted: true });
    if (action === "disconnect") hub.disconnectUser("ABC234", "alice");
    else await api(action === "leave" ? "POST" : "DELETE", action === "leave" ? "/leave" : "/location", "alice");
    assert.ok(bob.events().some((e) => e.name === "follow-response" &&
      e.data.accepted === false && e.data.reason === (action === "stop" ? "stopped" : "left")));
    assert.equal(locations.targetOf("ABC234", "bob"), null);
    assert.deepEqual(locations.snapshot("ABC234").trails, {});
  });
}
