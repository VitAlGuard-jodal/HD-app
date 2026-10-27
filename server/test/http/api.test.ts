import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer, request as httpRequest } from "node:http";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { createApp } from "../../src/app.ts";
import { issueToken } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { findUserByHandle } from "../../src/store.ts";

// 이 파일은 루프백 소켓을 열 수 있는 환경에서만 실행한다.
async function fixture(t: TestContext) {
  const db = openDb(":memory:");
  const hub = new RoomEventHub();
  const server = createServer(createApp({ db, hub }));
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

  return { db, hub, base, api, signup, events };
}

function assertError(result: { status: number; body: unknown }, status: number): void {
  assert.equal(result.status, status);
  const body = result.body as { error: { code: string; message: string } };
  assert.equal(typeof body.error.code, "string");
  assert.ok(body.error.code.length > 0);
  assert.equal(typeof body.error.message, "string");
  assert.ok(body.error.message.length > 0);
}

test("회원가입부터 친구·방·다중 SSE·시그널·재연결·나가기·로그아웃까지", { timeout: 30_000 }, async (t) => {
  const { api, signup, events, hub } = await fixture(t);
  const signupToken = await signup("alice", "  앨리스  ");
  const bob = await signup("bob", "보비");
  const charlie = await signup("charlie", "찰리");
  const login = await api("POST", "/v1/auth/login", undefined, { handle: "alice", password: "password123!" });
  assert.equal(login.status, 200);
  const alice = login.body.token as string;
  assert.notEqual(alice, signupToken);
  assert.deepEqual((await api("GET", "/v1/me", alice)).body, { user: { handle: "alice", displayName: "앨리스" } });
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
  assert.deepEqual(await aliceEvents.next("member-joined"), { handle: "bob" });
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
  const left = await api("POST", `/v1/rooms/${code}/leave`, bob);
  assert.equal(left.status, 204);
  assert.equal(left.body, undefined);
  assert.deepEqual(await aliceEvents.next("member-left"), { handle: "bob" });
  assert.deepEqual(await reconnected.next("member-left"), { handle: "bob" });
  await reconnected.close();
  assert.equal(hub.subscriberCount(code), 1);
  assert.deepEqual((await api("GET", `/v1/rooms/${code}`, alice)).body.members.map((member: { handle: string }) => member.handle), ["alice"]);
  assertError(await api("POST", `/v1/rooms/${code}/signal`, alice, { to: "bob", kind: "custom", payload: null }), 403);
  assertError(await api("GET", `/v1/rooms/${code}/events`, bob), 403);
  assert.equal((await api("POST", `/v1/rooms/${code}/leave`, bob)).status, 204);
  assert.equal((await api("POST", `/v1/rooms/${code}/join`, bob)).status, 200);
  assert.deepEqual(await aliceEvents.next("member-joined"), { handle: "bob" });
  assert.equal((await api("GET", `/v1/rooms/${code}`, alice)).body.members.length, 2);

  assert.equal((await api("DELETE", "/v1/contacts/bob", alice)).status, 204);
  assert.deepEqual((await api("GET", "/v1/contacts", alice)).body.contacts, []);
  assert.equal((await api("POST", "/v1/auth/logout", alice)).status, 204);
  assertError(await api("GET", "/v1/me", alice), 401);
  assert.equal((await api("GET", "/v1/me", signupToken)).status, 200);
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
