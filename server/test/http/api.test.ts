import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer, request as httpRequest } from "node:http";
import type { IncomingMessage } from "node:http";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { issueToken } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { RoomLocationStore, LOCATION_DISCONNECT_GRACE_MS, LOCATION_STALE_MS } from "../../src/locations.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { createRoom, findUserByHandle, joinRoom, leaveRoom } from "../../src/store.ts";

// 이 파일은 루프백 소켓을 열 수 있는 환경에서만 실행한다.
async function fixture(t: TestContext) {
  const db = openDb(":memory:");
  const hub = new RoomEventHub();
  const locations = new RoomLocationStore();
  const server = createServer(createApp({ db, hub, locations }));
  const controllers = new Set<AbortController>();
  t.after(async () => {
    for (const controller of controllers) controller.abort();
    hub.close();
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
      server.closeAllConnections();
    });
    db.close();
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const base = `http://127.0.0.1:${address.port}`;

  async function api(method: string, path: string, token?: string, body?: unknown) {
    const headers: Record<string, string> = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const response = await fetch(`${base}${path}`, {
      method, headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(5000),
    });
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(response.headers.has("access-control-allow-origin"), false);
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : undefined };
  }

  async function signup(handle: string, displayName: string) {
    const result = await api("POST", "/v1/auth/signup", undefined, {
      handle, displayName, password: "password123!",
    });
    assert.equal(result.status, 201);
    assert.deepEqual(result.body.user, { handle, displayName: displayName.trim() });
    assert.match(result.body.token, /^[A-Za-z0-9_-]{43}$/);
    return result.body.token as string;
  }

  async function events(code: string, token: string) {
    const controller = new AbortController();
    controllers.add(controller);
    const connecting = setTimeout(() => controller.abort(), 5000);
    let response: Response;
    try {
      response = await fetch(`${base}/v1/rooms/${code}/events`, {
        headers: { authorization: `Bearer ${token}` }, signal: controller.signal,
      });
    } finally {
      clearTimeout(connecting);
    }
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") ?? "", /^text\/event-stream/);
    assert.ok(response.body);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    async function next(expected: string) {
      const timeout = setTimeout(() => controller.abort(), 5000);
      try {
        while (true) {
          const separator = buffer.indexOf("\n\n");
          if (separator >= 0) {
            const frame = buffer.slice(0, separator);
            buffer = buffer.slice(separator + 2);
            if (frame.startsWith(":")) continue;
            const lines = frame.split("\n");
            const name = lines.find((line) => line.startsWith("event: "))?.slice(7);
            const data = lines.filter((line) => line.startsWith("data: ")).map((line) => line.slice(6)).join("\n");
            assert.equal(name, expected);
            return JSON.parse(data);
          }
          const chunk = await reader.read();
          assert.equal(chunk.done, false, `${expected} 이벤트 전에 SSE가 종료되었습니다.`);
          buffer += decoder.decode(chunk.value, { stream: true });
        }
      } finally {
        clearTimeout(timeout);
      }
    }

    async function close() {
      controller.abort();
      await reader.cancel().catch(() => {});
      controllers.delete(controller);
    }

    return { next, close };
  }

  return { db, hub, locations, base, api, signup, events };
}

function assertError(result: { status: number; body: unknown }, status: number): void {
  assert.equal(result.status, status);
  const body = result.body as { error: { code: string; message: string } };
  assert.equal(typeof body.error.code, "string");
  assert.ok(body.error.code.length > 0);
  assert.equal(typeof body.error.message, "string");
  assert.ok(body.error.message.length > 0);
}

test("TURN 자격 발급은 로그인 필수이고 응답을 캐시하지 않는다", async (t) => {
  const { api, signup, base } = await fixture(t);
  assertError(await api("GET", "/v1/turn"), 401);
  const token = await signup("turn_user", "통화 사용자");
  const response = await fetch(`${base}/v1/turn`, {
    headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000),
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json() as { iceServers: unknown[]; ttlSeconds: number };
  assert.ok(Array.isArray(body.iceServers));
  assert.ok(Number.isSafeInteger(body.ttlSeconds) && body.ttlSeconds > 0);
  await api("POST", "/v1/auth/logout", token);
  assertError(await api("GET", "/v1/turn", token), 401);
});

test("GET /v1/me는 참여 전 null, 참여 중 방 요약, 나간 뒤 null을 반환한다", async (t) => {
  const { api, signup } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  const bob = await signup("bob", "보비");
  assert.deepEqual((await api("GET", "/v1/me", bob)).body, {
    user: { handle: "bob", displayName: "보비" }, room: null,
  });

  const created = await api("POST", "/v1/rooms", alice, { name: "자동 복귀" });
  const code = created.body.room.code as string;
  const creatorDetails = (await api("GET", `/v1/rooms/${code}`, alice)).body;
  assert.deepEqual((await api("GET", "/v1/me", alice)).body.room, {
    ...creatorDetails.room, members: creatorDetails.members,
  });
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  const details = (await api("GET", `/v1/rooms/${code}`, bob)).body;
  const restored = await api("GET", "/v1/me", bob);
  assert.equal(restored.status, 200);
  assert.deepEqual(restored.body, {
    user: { handle: "bob", displayName: "보비" },
    room: { ...details.room, members: details.members },
  });
  // 재참여로 joinedAt을 바꾸거나 다른 사람의 방을 복구하지 않는다.
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  assert.deepEqual((await api("GET", "/v1/me", bob)).body, restored.body);
  assert.equal((await api("POST", `/v1/rooms/${code}/leave`, bob)).status, 204);
  assert.equal((await api("GET", "/v1/me", bob)).body.room, null);
  assert.equal((await api("GET", "/v1/me", alice)).body.room.members.length, 1);
});

test("GET /v1/me는 복수 참여 데이터에서 가장 최근 joined_at의 활성 방 하나를 고른다", async (t) => {
  const { api, signup, db } = await fixture(t);
  await signup("alice", "앨리스");
  const bob = await signup("bob", "보비");
  const aliceId = findUserByHandle(db, "alice")!.id;
  const bobId = findUserByHandle(db, "bob")!.id;
  const first = createRoom(db, { code: "ABC234", name: "먼저 만든 방", createdBy: aliceId }, "2026-01-01T00:00:00.000Z")!;
  const second = createRoom(db, { code: "DEF567", name: "나중에 만든 방", createdBy: aliceId }, "2026-01-02T00:00:00.000Z")!;
  joinRoom(db, second.id, bobId, "2026-01-03T00:00:00.000Z");
  joinRoom(db, first.id, bobId, "2026-01-04T00:00:00.000Z");
  assert.equal((await api("GET", "/v1/me", bob)).body.room.code, first.code);
  leaveRoom(db, first.id, bobId);
  assert.equal((await api("GET", "/v1/me", bob)).body.room.code, second.code);
  leaveRoom(db, second.id, bobId);
  assert.equal((await api("GET", "/v1/me", bob)).body.room, null);
});

test("회원가입부터 친구·방·다중 SSE·시그널·재연결·나가기·로그아웃까지", { timeout: 30_000 }, async (t) => {
  const { api, signup, events, hub } = await fixture(t);
  const signupToken = await signup("alice", "  앨리스  ");
  const bob = await signup("bob", "보비");
  const charlie = await signup("charlie", "찰리");
  const login = await api("POST", "/v1/auth/login", undefined, { handle: "alice", password: "password123!" });
  assert.equal(login.status, 200);
  const alice = login.body.token as string;
  assert.notEqual(alice, signupToken);
  assert.deepEqual((await api("GET", "/v1/me", alice)).body, { user: { handle: "alice", displayName: "앨리스" }, room: null });
  assert.deepEqual((await api("GET", "/v1/users/bob", alice)).body, { user: { handle: "bob", displayName: "보비" } });

  const added = await api("POST", "/v1/contacts", alice, { handle: "bob" });
  assert.equal(added.status, 201);
  assert.deepEqual(added.body, { contact: { handle: "bob", displayName: "보비" } });
  assert.deepEqual((await api("GET", "/v1/contacts", alice)).body.contacts, [added.body.contact]);
  assert.deepEqual((await api("GET", "/v1/contacts", bob)).body.contacts, []);

  const created = await api("POST", "/v1/rooms", alice, { name: "함께 출발", invitees: ["bob"] });
  assert.equal(created.status, 201);
  const code = created.body.room.code as string;
  assert.match(code, /^[A-HJ-NP-Z2-9]{6}$/);
  assert.equal(created.body.room.createdBy, "alice");
  assert.equal(created.body.room.name, "함께 출발");
  assert.deepEqual((await api("GET", `/v1/rooms/${code}`, alice)).body.members.map((member: { handle: string }) => member.handle), ["alice"]);
  assertError(await api("GET", `/v1/rooms/${code}/events`, bob), 403);
  assertError(await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", kind: "offer", payload: null }), 403);
  assertError(await api("POST", `/v1/rooms/${code}/signal`, charlie, { to: "alice", kind: "offer", payload: null }), 403);

  const aliceEvents = await events(code, alice);
  const helloAlice = await aliceEvents.next("hello");
  assert.deepEqual(helloAlice.self, { handle: "alice", displayName: "앨리스" });
  assert.equal(helloAlice.members.length, 1);
  assert.equal(typeof helloAlice.members[0].joinedAt, "string");
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  assert.equal((await aliceEvents.next("member-joined")).handle, "bob");
  // 반복 참여는 중복 이벤트를 만들지 않는다. 다음 수신 이벤트의 종류로도 검증한다.
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  const bobFirst = await events(code, bob);
  const bobSecond = await events(code, bob);
  for (const stream of [bobFirst, bobSecond]) {
    const hello = await stream.next("hello");
    assert.deepEqual(hello.self, { handle: "bob", displayName: "보비" });
    assert.deepEqual(hello.members.map((member: { handle: string }) => member.handle).sort(), ["alice", "bob"]);
  }

  const signals = [
    { kind: "offer", payload: { sdp: "offer-sdp" } },
    { kind: "answer", payload: "answer-sdp" },
    { kind: "ice", payload: { candidate: "candidate" } },
    { kind: "custom", payload: null },
    { kind: "custom", payload: [1, "한글", false] },
    { kind: "custom", payload: 0 },
    { kind: "custom", payload: true },
  ];
  for (const signal of signals) {
    const sent = await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", ...signal });
    assert.equal(sent.status, 202);
    assert.deepEqual(sent.body, { delivered: true });
    assert.deepEqual(await bobFirst.next("signal"), { from: "alice", ...signal });
    assert.deepEqual(await bobSecond.next("signal"), { from: "alice", ...signal });
  }

  for (const stream of [bobFirst, bobSecond]) {
    const unsubscribed = once(hub, "unsubscribed");
    await stream.close();
    await unsubscribed;
  }
  assert.equal(hub.subscriberCount(code), 1);
  assert.equal((await api("GET", `/v1/rooms/${code}`, alice)).body.members.length, 2);
  const offline = await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", kind: "custom", payload: null });
  assert.equal(offline.status, 202);
  assert.deepEqual(offline.body, { delivered: false });

  const reconnected = await events(code, bob);
  assert.equal((await reconnected.next("hello")).members.length, 2);
  for (const signal of signals) {
    assert.deepEqual(await reconnected.next("signal"), { from: "alice", ...signal });
  }
  assert.deepEqual(await reconnected.next("signal"), { from: "alice", kind: "custom", payload: null });
  const left = await api("POST", `/v1/rooms/${code}/leave`, bob);
  assert.equal(left.status, 204);
  assert.equal(left.body, undefined);
  assert.equal((await aliceEvents.next("member-left")).handle, "bob");
  assert.equal((await reconnected.next("member-left")).handle, "bob");
  await reconnected.close();
  assert.equal(hub.subscriberCount(code), 1);
  assert.deepEqual((await api("GET", `/v1/rooms/${code}`, alice)).body.members.map((member: { handle: string }) => member.handle), ["alice"]);
  assertError(await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", kind: "custom", payload: null }), 403);
  assertError(await api("GET", `/v1/rooms/${code}/events`, bob), 403);
  assert.equal((await api("POST", `/v1/rooms/${code}/leave`, bob)).status, 204);
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  assert.equal((await aliceEvents.next("member-joined")).handle, "bob");
  assert.equal((await api("GET", `/v1/rooms/${code}`, alice)).body.members.length, 2);
  const rejoined = await events(code, bob);
  assert.equal((await rejoined.next("hello")).members.length, 2);
  const afterLeave = { to: "bob", kind: "offer", payload: { sdp: "새 참여의 offer" } };
  const sentAfterLeave = await api("POST", `/v1/rooms/${code}/signal`, alice, afterLeave);
  assert.equal(sentAfterLeave.status, 202);
  assert.deepEqual(sentAfterLeave.body, { delivered: true });
  assert.deepEqual(await rejoined.next("signal"), { from: "alice", kind: afterLeave.kind, payload: afterLeave.payload });

  assert.equal((await api("DELETE", "/v1/contacts/bob", alice)).status, 204);
  assert.deepEqual((await api("GET", "/v1/contacts", alice)).body.contacts, []);
  assert.equal((await api("POST", "/v1/auth/logout", alice)).status, 204);
  assertError(await api("GET", "/v1/me", alice), 401);
  assert.equal((await api("GET", "/v1/me", signupToken)).status, 200);
});

test("SSE가 없는 수신자의 시그널을 보관하고 연결 시 hello 다음에 재전송한다", { timeout: 15_000 }, async (t) => {
  const { api, signup, events, hub } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  const bob = await signup("bob", "보비");
  const created = await api("POST", "/v1/rooms", alice, {});
  assert.equal(created.status, 201);
  const code = created.body.room.code as string;
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  assert.equal(hub.subscriberCount(code), 0);
  const signal = { kind: "offer", payload: { negotiationId: "offline-offer", sdp: "offer-sdp" } };
  const sent = await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", ...signal });
  assert.equal(sent.status, 202);
  assert.deepEqual(sent.body, { delivered: false });

  const stream = await events(code, bob);
  assert.deepEqual((await stream.next("hello")).self, { handle: "bob", displayName: "보비" });
  assert.deepEqual(await stream.next("signal"), { from: "alice", ...signal });
});

test("로그아웃은 해당 토큰의 기존 SSE를 end로 끝내고 다른 기기와 방 참여는 유지한다", { timeout: 15_000 }, async (t) => {
  const { base, api, signup, events, hub } = await fixture(t);
  const token = await signup("alice", "앨리스");
  const login = await api("POST", "/v1/auth/login", undefined, { handle: "alice", password: "password123!" });
  assert.equal(login.status, 200);
  const otherToken = login.body.token as string;
  assert.notEqual(token, otherToken);
  const firstRoom = await api("POST", "/v1/rooms", token, {});
  const secondRoom = await api("POST", "/v1/rooms", token, {});
  assert.equal(firstRoom.status, 201);
  assert.equal(secondRoom.status, 201);
  const code = firstRoom.body.room.code as string;
  const otherCode = secondRoom.body.room.code as string;
  const survivor = await events(code, otherToken);
  assert.equal((await survivor.next("hello")).self.handle, "alice");

  const responses: IncomingMessage[] = [];
  for (const roomCode of [code, code, otherCode]) {
    const response = await new Promise<IncomingMessage>((resolve, reject) => {
      const request = httpRequest(`${base}/v1/rooms/${roomCode}/events`, {
        headers: { authorization: `Bearer ${token}` },
      }, resolve);
      request.once("error", reject);
      request.setTimeout(5000, () => request.destroy(new Error("SSE 종료 대기 시간 초과")));
      t.after(() => request.destroy());
      request.end();
    });
    assert.equal(response.statusCode, 200);
    assert.match(response.headers["content-type"] ?? "", /^text\/event-stream/);
    assert.equal(response.readableEnded, false);
    responses.push(response);
  }
  assert.equal(hub.subscriberCount(code), 3);
  assert.equal(hub.subscriberCount(otherCode), 1);
  // 클라이언트에서 중단하지 않고 서버가 응답 스트림을 끝내는지 확인한다.
  const ended = responses.map((response) => {
    const result = once(response, "end", { signal: AbortSignal.timeout(5000) });
    response.resume();
    return result;
  });
  const [logout] = await Promise.all([
    api("POST", "/v1/auth/logout", token),
    Promise.all(ended),
  ]);
  assert.equal(logout.status, 204);
  for (const response of responses) assert.equal(response.readableEnded, true);
  assert.equal(hub.subscriberCount(code), 1);
  assert.equal(hub.subscriberCount(otherCode), 0);
  assertError(await api("GET", "/v1/me", token), 401);
  assert.equal((await api("GET", "/v1/me", otherToken)).status, 200);
  for (const roomCode of [code, otherCode]) {
    const details = await api("GET", `/v1/rooms/${roomCode}`, otherToken);
    assert.deepEqual(details.body.members.map((member: { handle: string }) => member.handle), ["alice"]);
  }
  const signal = { to: "alice", kind: "custom", payload: "다른 기기 연결 유지" };
  const sent = await api("POST", `/v1/rooms/${code}/signal`, otherToken, signal);
  assert.equal(sent.status, 202);
  assert.deepEqual(sent.body, { delivered: true });
  assert.deepEqual(await survivor.next("signal"), { from: "alice", kind: signal.kind, payload: signal.payload });
});

test("비ASCII 방 코드는 대문자로 변환하면 기존 방과 같아도 404를 반환한다", { timeout: 15_000 }, async (t) => {
  const { db, api, signup } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  createRoom(db, { code: "STRM23", name: "같이 출발", createdBy: findUserByHandle(db, "alice")!.id });
  assert.equal((await api("GET", "/v1/rooms/STRM23", alice)).status, 200);

  const result = await api("GET", "/v1/rooms/%C5%BFTRM23", alice);
  assertError(result, 404);
  assert.deepEqual(result.body, { error: { code: "ROOM_NOT_FOUND", message: "방을 찾을 수 없습니다." } });
});

test("소문자 ASCII 방 코드는 기존 대문자 방을 200으로 조회한다", { timeout: 15_000 }, async (t) => {
  const { db, api, signup } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  const room = createRoom(db, { code: "STRM23", name: "같이 출발", createdBy: findUserByHandle(db, "alice")!.id })!;

  const result = await api("GET", "/v1/rooms/strm23", alice);
  assert.equal(result.status, 200);
  assert.equal(result.body.room.code, room.code);
});

test("모든 방 경로는 소문자와 혼합 대소문자를 같은 방으로 정규화한다", { timeout: 15_000 }, async (t) => {
  const { db, api, signup, events, hub } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  const bob = await signup("bob", "보비");
  // 숫자만 생성되는 우연에도 검증이 빠지지 않도록 영문이 든 코드를 고정한다.
  const room = createRoom(db, { code: "ABC234", name: "같이 출발", createdBy: findUserByHandle(db, "alice")!.id })!;
  const details = await api("GET", "/v1/rooms/aBc234", alice);
  assert.equal(details.status, 200);
  assert.equal(details.body.room.code, room.code);
  const aliceEvents = await events("abc234", alice);
  assert.equal((await aliceEvents.next("hello")).self.handle, "alice");

  const joined = await api("POST", "/v1/rooms/abc234/join", bob);
  assert.equal(joined.status, 200);
  assert.equal(joined.body.room.code, "ABC234");
  assert.equal((await aliceEvents.next("member-joined")).handle, "bob");
  const bobEvents = await events("aBc234", bob);
  assert.equal((await bobEvents.next("hello")).members.length, 2);
  assert.equal(hub.subscriberCount("ABC234"), 2);
  assert.equal(hub.subscriberCount("abc234"), 0);

  const sent = await api("POST", "/v1/rooms/abc234/signal", alice, { to: "bob", kind: "custom", payload: null });
  assert.equal(sent.status, 202);
  assert.deepEqual(sent.body, { delivered: true });
  assert.deepEqual(await bobEvents.next("signal"), { from: "alice", kind: "custom", payload: null });
  assert.equal((await api("POST", "/v1/rooms/aBc234/leave", bob)).status, 204);
  assert.equal((await aliceEvents.next("member-left")).handle, "bob");
  assert.equal((await bobEvents.next("member-left")).handle, "bob");
  assert.equal(hub.subscriberCount("ABC234"), 1);
  assert.deepEqual((await api("GET", "/v1/rooms/abc234", alice)).body.members.map((member: { handle: string }) => member.handle), ["alice"]);
});

test("PATCH /v1/me는 표시 이름만 변경하고 회원가입과 같은 이름 규칙을 적용한다", { timeout: 15_000 }, async (t) => {
  const { api, signup } = await fixture(t);
  const alice = await signup("alice", "앨리스");
  const bob = await signup("bob", "보비");
  assertError(await api("PATCH", "/v1/me", undefined, { displayName: "새 이름" }), 401);
  const updated = await api("PATCH", "/v1/me", alice, {
    displayName: "  새 이름  ", handle: "changed", password: "changed-password",
  });
  assert.equal(updated.status, 200);
  assert.deepEqual(updated.body, { user: { handle: "alice", displayName: "새 이름" } });
  assert.deepEqual((await api("GET", "/v1/me", alice)).body, { ...updated.body, room: null });
  assert.deepEqual((await api("GET", "/v1/users/alice", bob)).body, updated.body);
  assert.deepEqual((await api("GET", "/v1/me", bob)).body, { user: { handle: "bob", displayName: "보비" }, room: null });
  assert.equal((await api("POST", "/v1/auth/login", undefined, { handle: "alice", password: "password123!" })).status, 200);

  for (const body of [{}, { displayName: "가" }, { displayName: "  가  " }, { displayName: "" },
    { displayName: "가".repeat(21) }, { displayName: null }, { displayName: 123 }]) {
    assertError(await api("PATCH", "/v1/me", alice, body), 400);
  }
  assert.deepEqual((await api("GET", "/v1/me", alice)).body, { ...updated.body, room: null });
  for (const displayName of ["새봄", "🚗".repeat(20)]) {
    const boundary = await api("PATCH", "/v1/me", alice, { displayName });
    assert.equal(boundary.status, 200);
    assert.deepEqual(boundary.body, { user: { handle: "alice", displayName } });
  }
});

test("입력 오류·충돌·미존재·폐기 및 만료 토큰을 정해진 JSON 오류로 돌려준다", { timeout: 15_000 }, async (t) => {
  const { api, signup, db } = await fixture(t);
  assertError(await api("GET", "/v1/me"), 401);
  assertError(await api("GET", "/v1/me", "invalid-token"), 401);
  const alice = await signup("alice", "앨리스");
  await signup("bob", "보비");
  assertError(await api("POST", "/v1/auth/signup", undefined, { handle: "alice", displayName: "앨리스", password: "password123!" }), 409);
  for (const body of [
    { handle: "Alice", displayName: "앨리스", password: "password123!" },
    { handle: "new_user", displayName: "가", password: "password123!" },
    { handle: "new_user", displayName: "앨리스", password: "short" },
  ]) assertError(await api("POST", "/v1/auth/signup", undefined, body), 400);
  assertError(await api("POST", "/v1/auth/login", undefined, { handle: "alice", password: "incorrect123" }), 401);
  assertError(await api("POST", "/v1/auth/login", undefined, { handle: "missing", password: "password123!" }), 401);
  assertError(await api("POST", "/v1/auth/login", undefined, {}), 400);
  assertError(await api("GET", "/v1/users/missing", alice), 404);
  assertError(await api("GET", "/v1/users/Alice", alice), 400);
  assertError(await api("GET", "/v1/users/%ZZ", alice), 400);
  assertError(await api("POST", "/v1/contacts", alice, { handle: "missing" }), 404);
  assertError(await api("POST", "/v1/contacts", alice, { handle: "alice" }), 409);
  assert.equal((await api("POST", "/v1/contacts", alice, { handle: "bob" })).status, 201);
  assertError(await api("POST", "/v1/contacts", alice, { handle: "bob" }), 409);
  assertError(await api("POST", "/v1/rooms", alice, { invitees: ["missing"] }), 404);
  for (const body of [{ name: 1 }, { invitees: null }, { invitees: "bob" }, { invitees: ["BOB"] }]) {
    assertError(await api("POST", "/v1/rooms", alice, body), 400);
  }
  assertError(await api("GET", "/v1/rooms/XXXXXX", alice), 404);
  assertError(await api("GET", "/v1/unknown", alice), 404);
  const room = await api("POST", "/v1/rooms", alice, {});
  assert.equal(room.status, 201);
  for (const body of [
    { to: "alice", kind: "unknown", payload: null },
    { to: "alice", kind: "custom" },
    { to: "Alice", kind: "custom", payload: null },
  ]) assertError(await api("POST", `/v1/rooms/${room.body.room.code}/signal`, alice, body), 400);
  const expired = issueToken(db, findUserByHandle(db, "alice")!.id, new Date("2000-01-01T00:00:00.000Z"));
  assertError(await api("GET", "/v1/me", expired), 401);
  assert.equal((await api("POST", "/v1/auth/logout", alice)).status, 204);
  assertError(await api("POST", "/v1/auth/logout", alice), 401);
});

test("JSON 형식·Content-Type·64KB 바이트 제한을 적용한다", { timeout: 15_000 }, async (t) => {
  const { base, signup } = await fixture(t);
  const token = await signup("alice", "앨리스");
  async function raw(body: string | Uint8Array, contentType: string) {
    const response = await fetch(`${base}/v1/rooms`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": contentType },
      body,
      signal: AbortSignal.timeout(5000),
    });
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    return { status: response.status, body: await response.json() };
  }
  assertError(await raw("{}", "text/plain"), 415);
  for (const body of ["{", "", "null", "[]", "1", '"string"']) assertError(await raw(body, "application/json"), 400);
  assertError(await raw(new Uint8Array([0x7b, 0xff, 0x7d]), "application/json"), 400);
  const overhead = Buffer.byteLength(JSON.stringify({ name: "" }));
  const exact = JSON.stringify({ name: "a".repeat(64 * 1024 - overhead) });
  assert.equal(Buffer.byteLength(exact), 64 * 1024);
  assert.equal((await raw(exact, "application/json; charset=utf-8")).status, 201);
  assertError(await raw(`${exact} `, "application/json"), 413);
  assertError(await raw(JSON.stringify({ name: "한".repeat(24_000) }), "application/json"), 413);

  // Content-Length 없는 전송도 실제 수신 바이트 수로 제한한다.
  const chunked = await new Promise<{ status: number; body: unknown }>((resolve, reject) => {
    const request = httpRequest(`${base}/v1/rooms`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.once("error", reject);
      response.once("end", () => {
        try {
          resolve({ status: response.statusCode!, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
        } catch (error) {
          reject(error);
        }
      });
    });
    request.once("error", reject);
    request.setTimeout(5000, () => request.destroy(new Error("청크 전송 시간 초과")));
    request.write('{"name":"');
    for (let index = 0; index < 9; index += 1) request.write("a".repeat(8192));
    request.end('"}');
  });
  assertError(chunked, 413);
});

test("HTTP follow v2 pending·ID·revision·수신자별 trail·무변경 방송 0·속도 제한", { timeout: 30_000 }, async (t) => {
  const { api, signup, events } = await fixture(t);
  const alice = await signup("alice", "앨리스"), bob = await signup("bob", "보비"), charlie = await signup("charlie", "찰리");
  const code = (await api("POST", "/v1/rooms", alice, {})).body.room.code;
  const path = `/v1/rooms/${code}`;
  await api("POST", `${path}/join`, bob, {});
  await api("POST", `${path}/join`, charlie, {});
  const a = await events(code, alice), b = await events(code, bob), c = await events(code, charlie);
  for (const stream of [a, b, c]) assert.deepEqual((await stream.next("hello")).trails, {});
  const pending = await api("POST", `${path}/follow`, bob, { target: "alice" });
  assert.equal(pending.body.accepted, false);
  const request = await a.next("follow-request");
  assert.equal(request.requestId, pending.body.requestId);
  assert.equal(request.displayName, "보비");
  assertError(await api("POST", `${path}/follow`, bob, { target: "alice" }), 429);
  assertError(await api("DELETE", `${path}/follow`, bob), 429);
  assertError(await api("POST", `${path}/follow/respond`, alice, { requestId: "wrong", accepted: true }), 404);
  const awaiting = await events(code, bob);
  const awaitingHello = await awaiting.next("hello");
  assert.equal(awaitingHello.followTarget, null);
  assert.equal(awaitingHello.pendingFollow, "alice");
  assert.equal(awaitingHello.followRequestId, request.requestId);
  await awaiting.close();
  const accepted = await api("POST", `${path}/follow/respond`, alice, { requestId: request.requestId, accepted: true });
  assert.ok(accepted.body.revision > pending.body.revision);
  assert.deepEqual((await b.next("trail")).points, []);
  assert.equal((await b.next("follow-response")).requestId, request.requestId);
  assert.equal((await a.next("follow-cancelled")).reason, "accepted");
  await api("POST", `${path}/location`, alice, {
    stream: "0123456789abcdef", lat: 37, lng: 127, heading: 90, at: 0, seq: 0,
  });
  await b.next("location");
  await c.next("location"); // 비팔로워에게 trail은 전송하지 않았다.
  const extra = await api("POST", `${path}/follow`, charlie, { target: "alice" });
  assert.equal(extra.body.accepted, true);
  assert.equal((await c.next("trail")).points.length, 1);
  assert.equal((await c.next("follow-response")).requestId, extra.body.requestId);
  const reconnect = await events(code, bob);
  const hello = await reconnect.next("hello");
  assert.equal(hello.followTarget, "alice");
  assert.equal(hello.pendingFollow, null);
  assert.deepEqual(Object.keys(hello.trails), ["alice"]);
  await reconnect.close();
  await new Promise((resolve) => setTimeout(resolve, 1050));
  const repeated = await api("POST", `${path}/follow`, charlie, { target: "alice" });
  assert.equal(repeated.body.requestId, extra.body.requestId);
  assert.equal(repeated.body.revision, hello.revision);
  // 다음 표식 앞에 불필요한 follow/trail 방송이 하나라도 있으면 next가 실패한다.
  for (const [handle, stream] of [["alice", a], ["bob", b], ["charlie", c]] as const) {
    await api("POST", `${path}/signal`, alice, { to: handle, kind: "custom", payload: "marker" });
    assert.equal((await stream.next("signal")).payload, "marker");
  }
  await api("DELETE", `${path}/follow`, bob);
  await a.next("follow-cancelled");
  assert.deepEqual((await api("GET", `${path}/positions`, bob)).body.trails, {});
});

for (const expired of [false, true]) {
  test(`HTTP 마지막 SSE 단절 ${expired ? "유예 만료" : "유예 내 재구독"}`, { timeout: 45_000 }, async (t) => {
    const { api, signup, events, locations } = await fixture(t);
    const alice = await signup("alice", "앨리스"), bob = await signup("bob", "보비");
    const code = (await api("POST", "/v1/rooms", alice, {})).body.room.code;
    const path = `/v1/rooms/${code}`;
    await api("POST", `${path}/join`, bob, {});
    await api("POST", `${path}/location`, alice, { stream: "0123456789abcdef", lat: 37, lng: 127, at: 0, seq: 0 });
    await api("POST", `${path}/follow`, bob, { target: "alice" });
    const a = await events(code, alice), b = await events(code, bob);
    await a.next("hello"); await b.next("hello");
    await a.close();
    // 닫힘 전달을 기다린 뒤 유예 타이머가 실제로 시작된 상태를 검사한다.
    for (let attempt = 0; attempt < 100 && locations.disconnectedAt(code, "alice") === undefined; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.notEqual(locations.disconnectedAt(code, "alice"), undefined);
    if (expired) {
      await new Promise((resolve) => setTimeout(resolve, LOCATION_DISCONNECT_GRACE_MS + 100));
      assert.equal((await b.next("follow-response")).reason, "left");
      assert.equal((await b.next("location-stopped")).reason, "left");
      assert.equal(locations.targetOf(code, "bob"), null);
    } else {
      const restored = await events(code, alice);
      assert.equal((await restored.next("hello")).positions.length, 1);
      assert.equal(locations.disconnectedAt(code, "alice"), undefined);
      assert.equal(locations.targetOf(code, "bob"), "alice");
    }
  });
}

test("HTTP 잘못된 seq·stale·leave 권한 경계", { timeout: 15_000 }, async (t) => {
  const { api, signup, events, locations } = await fixture(t);
  const alice = await signup("alice", "앨리스"), bob = await signup("bob", "보비"), outsider = await signup("outsider", "외부인");
  const code = (await api("POST", "/v1/rooms", alice, {})).body.room.code;
  const path = `/v1/rooms/${code}`;
  await api("POST", `${path}/join`, bob, {});
  const fix = { handle: "alice", stream: "0123456789abcdef", lat: 37, lng: 127, at: 0, seq: 0 };
  for (const seq of [1e100, 2 ** 53, -1, NaN]) assertError(await api("POST", `${path}/location`, alice, { ...fix, seq }), 400);
  const relation = locations.requestFollow(code, "bob", "alice");
  locations.respondFollow(code, "alice", relation.requestId, true);
  const b = await events(code, bob);
  await b.next("hello");
  locations.accept(code, fix, Date.now() - LOCATION_STALE_MS);
  const snapshot = await api("GET", `${path}/positions`, bob);
  assert.deepEqual(snapshot.body.positions, []);
  assert.equal((await b.next("follow-response")).reason, "stale");
  assert.equal((await b.next("location-stopped")).reason, "stale");
  assertError(await api("POST", `${path}/leave`, outsider), 403);
  assert.equal((await api("POST", `${path}/leave`, bob)).status, 204);
  assert.equal((await api("POST", `${path}/leave`, bob)).status, 204);
});
