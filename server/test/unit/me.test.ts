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
import { createRoom, createUser, findRoomMembership, joinRoom, leaveRoom, publicRoomDetails } from "../../src/store.ts";

// 실제 라우터·인증·SQLite를 사용하되 TCP listen 없이 JSON 응답을 수집한다.
class JsonResponse extends Writable {
  statusCode = 200;
  headersSent = false;
  readonly chunks: Buffer[] = [];
  readonly headers = new Map<string, string>();
  setHeader(name: string, value: string): void {
    this.headers.set(name, value);
  }
  override _write(chunk: Buffer, _encoding: BufferEncoding, done: () => void): void {
    this.headersSent = true;
    this.chunks.push(chunk);
    done();
  }
}

function fixture(t: TestContext) {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const alice = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "unused" })!;
  const bob = createUser(db, { handle: "bob", displayName: "보비", passwordHash: "unused" })!;
  const token = issueToken(db, bob.id);
  const app = createApp({ db });
  async function getRaw(path: string, authorization = token) {
    const request = new IncomingMessage(new Socket());
    request.method = "GET";
    request.url = path;
    request.headers = { authorization: `Bearer ${authorization}` };
    const response = new JsonResponse();
    const finished = new Promise<void>((resolve, reject) => {
      response.once("finish", resolve);
      response.once("error", reject);
    });
    app(request, response as unknown as ServerResponse);
    request.push(null);
    await finished;
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    return { status: response.statusCode, bytes: Buffer.concat(response.chunks) };
  }
  async function get(path: string, authorization = token) {
    const { status, bytes } = await getRaw(path, authorization);
    return { status, body: JSON.parse(bytes.toString()) };
  }
  return { db, alice, bob, get, getRaw };
}

test("방 조회 JSON은 기존 요약 분해 방식과 바이트 단위로 같다", async (t) => {
  const { db, alice, bob, getRaw } = fixture(t);
  const room = createRoom(db, {
    code: "ABC234", name: '한글 "통화방"\n둘째 줄', createdBy: alice.id,
  }, "2026-01-01T00:00:00.000Z")!;
  joinRoom(db, room.id, bob.id, "2026-01-01T00:00:00.000Z");

  for (const empty of [false, true]) {
    if (empty) {
      leaveRoom(db, room.id, alice.id);
      leaveRoom(db, room.id, bob.id);
    }
    const { members, ...summary } = publicRoomDetails(db, room);
    const expected = Buffer.from(JSON.stringify({ room: summary, members }));
    const response = await getRaw(`/v1/rooms/${room.code.toLowerCase()}`);
    assert.equal(response.status, 200);
    assert.deepEqual(response.bytes, expected);
  }
});

test("me 라우터: 참여 전·나간 뒤 room은 null, 참여 중에는 기존 방 응답과 같은 공개 요약", async (t) => {
  const { db, alice, bob, get } = fixture(t);
  const user = { handle: "bob", displayName: "보비", avatar: { kind: null, version: 0 }, order: null };
  const consent = { privacy: null, location: null };
  assert.deepEqual(await get("/v1/me"), { status: 200, body: { user, room: null, consent } });
  const room = createRoom(db, { code: "ABC234", name: "자동 복귀", createdBy: alice.id })!;
  joinRoom(db, room.id, bob.id);
  const details = (await get(`/v1/rooms/${room.code}`)).body;
  assert.deepEqual(await get("/v1/me"), {
    status: 200, body: { user: { ...user, order: 1 }, room: { ...details.room, members: details.members }, consent },
  });
  leaveRoom(db, room.id, bob.id);
  assert.deepEqual(await get("/v1/me"), { status: 200, body: { user, room: null, consent } });
});

test("me 라우터: 활성 방 하나만 복원하고 과거 joined_at을 보존한 재입장도 현재 방을 반환한다", async (t) => {
  const { db, alice, bob, get } = fixture(t);
  const charlie = createUser(db, { handle: "charlie", displayName: "찰리", passwordHash: "unused" })!;
  const first = createRoom(db, { code: "ABC234", name: "첫 방", createdBy: alice.id })!;
  const second = createRoom(db, { code: "DEF567", name: "둘째 방", createdBy: charlie.id })!;
  joinRoom(db, second.id, bob.id, "2026-01-01T00:00:00.000Z");
  assert.equal((await get("/v1/me")).body.room.code, second.code);
  assert.throws(() => joinRoom(db, first.id, bob.id), /UNIQUE/);
  leaveRoom(db, second.id, bob.id);
  assert.equal((await get("/v1/me")).body.room, null);
  joinRoom(db, first.id, bob.id, "2026-01-02T00:00:00.000Z");
  assert.equal((await get("/v1/me")).body.room.code, first.code);
  leaveRoom(db, first.id, bob.id);
  assert.equal((await get("/v1/me")).body.room, null);
  joinRoom(db, second.id, bob.id, "2026-01-03T00:00:00.000Z");
  assert.deepEqual(findRoomMembership(db, second.id, bob.id), { joinedAt: "2026-01-01T00:00:00.000Z", leftAt: null });
  assert.equal((await get("/v1/me")).body.room.code, second.code);
  leaveRoom(db, second.id, bob.id);
  assert.equal((await get("/v1/me")).body.room, null);
});

test("me 라우터: 유효하지 않은 토큰에는 방 정보를 반환하지 않는다", async (t) => {
  const { get } = fixture(t);
  const response = await get("/v1/me", "invalid");
  assert.equal(response.status, 401);
  assert.equal(response.body.error.code, "UNAUTHORIZED");
  assert.equal(response.body.room, undefined);
});
