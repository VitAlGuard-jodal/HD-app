import assert from "node:assert/strict";
import { mkdtempSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { IncomingMessage } from "node:http";
import type { ServerResponse } from "node:http";
import { Socket } from "node:net";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Writable } from "node:stream";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { crc32, deflateSync } from "node:zlib";
import { createApp } from "../../src/app.ts";
import { avatarDirectory, avatarPng, MAX_AVATAR_BYTES } from "../../src/avatars.ts";
import { issueToken } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { addContact, createRoom, createUser, findUserByHandle, initializeSchema, joinRoom, leaveRoom, listRoomMembers } from "../../src/store.ts";

const timeout = { timeout: 30_000 };

function chunk(type: string, data: Buffer): Buffer {
  const bytes = Buffer.alloc(data.length + 12);
  bytes.writeUInt32BE(data.length);
  bytes.write(type, 4, "ascii");
  data.copy(bytes, 8);
  bytes.writeUInt32BE(crc32(bytes.subarray(4, bytes.length - 4)), bytes.length - 4);
  return bytes;
}

function png({
  width = 256, height = 256, padding = 0, bitDepth = 8, colorType = 6,
  compression = 0, filterMethod = 0, interlace = 0, pixels, compressed, splitIdat = false,
}: {
  width?: number; height?: number; padding?: number; bitDepth?: number; colorType?: number;
  compression?: number; filterMethod?: number; interlace?: number;
  pixels?: Buffer; compressed?: Buffer; splitIdat?: boolean;
} = {}): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = bitDepth;
  header[9] = colorType;
  header[10] = compression;
  header[11] = filterMethod;
  header[12] = interlace;
  const data = compressed ?? deflateSync(pixels ?? Buffer.alloc((width * (colorType === 2 ? 3 : 4) + 1) * height));
  const middle = Math.floor(data.length / 2);
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    ...(splitIdat ? [chunk("IDAT", data.subarray(0, middle)), chunk("IDAT", data.subarray(middle))] : [chunk("IDAT", data)]),
    ...(padding ? [chunk("tEXt", Buffer.alloc(padding, 65))] : []), chunk("IEND", Buffer.alloc(0)),
  ]);
}

function invalidPngs(): [string, Buffer][] {
  const fake = png({ compressed: Buffer.from("not-zlib") });
  for (let offset = 8; offset < fake.length;) {
    const end = offset + 12 + fake.readUInt32BE(offset);
    fake.writeUInt32BE(0, end - 4);
    offset = end;
  }
  assert.equal(fake.length, 65);
  const cases: [string, Buffer][] = [
    ["CRC가 모두 0인 65바이트 가짜", fake],
    ["CRC는 맞지만 zlib이 아닌 IDAT", png({ compressed: Buffer.from("not-zlib") })],
    ["빈 IDAT", png({ compressed: Buffer.alloc(0) })],
    ["잘린 zlib 스트림", png({ compressed: deflateSync(Buffer.alloc(262400)).subarray(0, -1) })],
    ["비트 깊이 16", png({ bitDepth: 16 })],
    ["그레이스케일", png({ colorType: 0 })],
    ["팔레트 색상", png({ colorType: 3 })],
    ["알파 그레이스케일", png({ colorType: 4 })],
    ["압축 방식 1", png({ compression: 1 })],
    ["필터 방식 1", png({ filterMethod: 1 })],
    ["인터레이스 1", png({ interlace: 1 })],
  ];
  const valid = png({ padding: 1 });
  for (let offset = 8; offset < valid.length;) {
    const end = offset + 12 + valid.readUInt32BE(offset);
    const broken = Buffer.from(valid);
    broken[end - 1] ^= 1;
    cases.push([`${valid.toString("ascii", offset + 4, offset + 8)} CRC 한 개 오류`, broken]);
    offset = end;
  }
  for (const colorType of [2, 6]) {
    const rowLength = 1 + 256 * (colorType === 2 ? 3 : 4);
    const expected = 256 * rowLength;
    for (const row of [0, 255]) {
      const pixels = Buffer.alloc(expected);
      pixels[row * rowLength] = 5;
      cases.push([`색상 ${colorType}의 ${row + 1}번째 행 필터 5`, png({ colorType, pixels })]);
    }
    for (const difference of [-1, 1]) {
      cases.push([`색상 ${colorType}의 해제 길이 ${difference}`, png({ colorType, pixels: Buffer.alloc(expected + difference) })]);
    }
  }
  return cases;
}

class ResponseSink extends Writable {
  statusCode = 200;
  headersSent = false;
  readonly chunks: Buffer[] = [];
  readonly headers = new Map<string, string>();
  setHeader(name: string, value: string): void { this.headers.set(name.toLowerCase(), value); }
  writeHead(status: number, headers: Record<string, string>): this {
    this.statusCode = status;
    for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
    this.headersSent = true;
    return this;
  }
  flushHeaders(): void { this.headersSent = true; }
  override _write(chunk: Buffer, _encoding: BufferEncoding, done: () => void): void {
    this.headersSent = true;
    this.chunks.push(Buffer.from(chunk));
    done();
  }
}

function fixture(t: TestContext) {
  const directory = mkdtempSync(join(tmpdir(), "unavo-avatar-"));
  const avatarsDir = join(directory, "avatars");
  const db = openDb(":memory:");
  const hub = new RoomEventHub();
  const alice = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "unused" })!;
  const bob = createUser(db, { handle: "bob", displayName: "보비", passwordHash: "unused" })!;
  const token = issueToken(db, alice.id);
  const bobToken = issueToken(db, bob.id);
  const app = createApp({ db, hub, avatarsDir });
  t.after(() => { hub.close(); db.close(); rmSync(directory, { recursive: true, force: true }); });
  async function request(method: string, path: string, body?: unknown, authorization: string | null = token) {
    const req = new IncomingMessage(new Socket());
    req.method = method;
    req.url = path;
    req.headers = {
      ...(authorization ? { authorization: `Bearer ${authorization}` } : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    };
    const response = new ResponseSink();
    const done = new Promise<void>((resolve, reject) => {
      response.once("finish", resolve);
      response.once("error", reject);
    });
    app(req, response as unknown as ServerResponse);
    if (body !== undefined) req.push(Buffer.from(JSON.stringify(body)));
    req.push(null);
    await done;
    const bytes = Buffer.concat(response.chunks);
    return {
      status: response.statusCode, headers: response.headers, bytes,
      body: response.headers.get("content-type")?.startsWith("application/json") && bytes.length
        ? JSON.parse(bytes.toString()) : undefined,
    };
  }
  function hello(code: string) {
    const req = new IncomingMessage(new Socket());
    req.method = "GET";
    req.url = `/v1/rooms/${code}/events`;
    req.headers = { authorization: `Bearer ${token}` };
    const response = new ResponseSink();
    app(req, response as unknown as ServerResponse);
    req.push(null);
    const frame = Buffer.concat(response.chunks).toString();
    response.destroy();
    return JSON.parse(frame.split("\n").find((line) => line.startsWith("data: "))!.slice(6));
  }
  return { db, hub, alice, bob, avatarsDir, request, hello, bobToken };
}

test("기존 계정 스키마에 아바타 기본값을 마이그레이션하며 반복 실행해도 유지한다", timeout, () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`CREATE TABLE users (id INTEGER PRIMARY KEY, handle TEXT UNIQUE NOT NULL,
      display_name TEXT NOT NULL, password_hash TEXT NOT NULL, created_at TEXT NOT NULL);
      INSERT INTO users VALUES (1, 'alice', '앨리스', 'hash', '2026-01-01');`);
    initializeSchema(db);
    assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: null, version: 0 });
    db.exec("UPDATE users SET avatar_kind = 'mascot-05', avatar_version = 7");
    initializeSchema(db);
    assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: "mascot-05", version: 7 });
  } finally { db.close(); }
});

test("사진은 300KB 이하 PNG 시그니처·IHDR 256×256·완결된 청크만 허용한다", timeout, () => {
  const valid = png();
  const atLimit = png({ padding: MAX_AVATAR_BYTES - valid.length - 12 });
  assert.equal(atLimit.length, MAX_AVATAR_BYTES);
  assert.deepEqual(avatarPng(atLimit.toString("base64")), atLimit);
  for (const bytes of [png({ width: 255 }), png({ height: 257 }), valid.subarray(0, 32),
    Buffer.from("not png"), Buffer.concat([valid, Buffer.from([0])]),
    png({ padding: MAX_AVATAR_BYTES - valid.length - 11 })]) {
    assert.equal(avatarPng(bytes.toString("base64")), undefined);
  }
  const badSignature = Buffer.from(valid);
  badSignature[0] = 0;
  const badHeader = Buffer.from(valid);
  badHeader.writeUInt32BE(12, 8);
  for (const input of [undefined, "", "%%%%", valid.toString("base64") + "\n",
    badSignature.toString("base64"), badHeader.toString("base64")]) {
    assert.equal(avatarPng(input), undefined);
  }
});

test("사진은 deflateSync로 만든 8비트 RGB·RGBA와 분할 IDAT·행 필터 0~4를 허용한다", timeout, () => {
  for (const colorType of [2, 6]) {
    const plain = png({ colorType });
    assert.deepEqual(avatarPng(plain.toString("base64")), plain);
    const rowLength = 1 + 256 * (colorType === 2 ? 3 : 4);
    const pixels = Buffer.alloc(256 * rowLength, 127);
    for (let row = 0; row < 256; row++) pixels[row * rowLength] = row % 5;
    const filtered = png({ colorType, pixels, splitIdat: true });
    assert.deepEqual(avatarPng(filtered.toString("base64")), filtered);
  }
});

test("손상된 PNG는 INVALID_INPUT으로 거부하고 기존 사진·버전·방송을 보존한다", timeout, async (t) => {
  const { db, hub, alice, avatarsDir, request } = fixture(t);
  const previous = png();
  assert.equal((await request("PUT", "/v1/me/avatar", { kind: "photo", png: previous.toString("base64") })).status, 200);
  const room = createRoom(db, { code: "ABC234", name: "검증", createdBy: alice.id })!;
  const events: unknown[] = [];
  hub.subscribe(room.code, alice.handle, "test", (_name, data) => { events.push(data); return true; }, () => {});
  for (const [name, bytes] of invalidPngs()) {
    await t.test(name, timeout, async () => {
      assert.equal(avatarPng(bytes.toString("base64")), undefined);
      const rejected = await request("PUT", "/v1/me/avatar", { kind: "photo", png: bytes.toString("base64") });
      assert.equal(rejected.status, 400);
      assert.deepEqual(rejected.body.error, {
        code: "INVALID_INPUT", message: "프로필 사진은 300KB 이하의 256×256 PNG여야 합니다.",
      });
      assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: "photo", version: 1 });
      assert.deepEqual(readdirSync(avatarsDir), ["alice-1.png"]);
      assert.deepEqual(readFileSync(join(avatarsDir, "alice-1.png")), previous);
      const got = await request("GET", "/v1/users/alice/avatar?v=1");
      assert.equal(got.status, 200);
      assert.deepEqual(got.bytes, previous);
      assert.deepEqual(events, []);
    });
  }
});

test("PUT·사진 교체·마스코트·DELETE는 DB 버전 파일을 사용하고 이전 파일을 제거한다", timeout, async (t) => {
  const { db, avatarsDir, request } = fixture(t);
  assert.equal(existsSync(avatarsDir), false);
  const uploaded = await request("PUT", "/v1/me/avatar", { kind: "photo", png: png().toString("base64") });
  assert.equal(uploaded.status, 200);
  assert.deepEqual(uploaded.body.user.avatar, { kind: "photo", version: 1 });
  assert.deepEqual(readdirSync(avatarsDir), ["alice-1.png"]);
  const next = png({ colorType: 2 });
  const photo = await request("PUT", "/v1/me/avatar", { kind: "photo", png: next.toString("base64") });
  assert.equal(photo.status, 200);
  assert.deepEqual(photo.body.user.avatar, { kind: "photo", version: 2 });
  assert.deepEqual(findUserByHandle(db, "alice")?.avatar, photo.body.user.avatar);
  assert.deepEqual(readdirSync(avatarsDir), ["alice-2.png"]);
  assert.deepEqual(readFileSync(join(avatarsDir, "alice-2.png")), next);
  const replaced = await request("PUT", "/v1/me/avatar", { kind: "mascot-03" });
  assert.deepEqual(replaced.body.user.avatar, { kind: "mascot-03", version: 3 });
  assert.deepEqual(readdirSync(avatarsDir), []);
  await request("PUT", "/v1/me/avatar", { kind: "photo", png: png().toString("base64") });
  assert.deepEqual(readdirSync(avatarsDir), ["alice-4.png"]);
  const deleted = await request("DELETE", "/v1/me/avatar");
  assert.equal(deleted.status, 200);
  assert.deepEqual(deleted.body.user.avatar, { kind: null, version: 5 });
  assert.deepEqual(readdirSync(avatarsDir), []);
  assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: null, version: 5 });
});

test("DB COMMIT 실패 시 사진 교체·마스코트·DELETE 모두 이전 버전과 GET·방송을 보존한다", timeout, async (t) => {
  const { db, hub, alice, avatarsDir, request } = fixture(t);
  const previous = png();
  const next = png({ colorType: 2 });
  assert.equal((await request("PUT", "/v1/me/avatar", { kind: "photo", png: previous.toString("base64") })).status, 200);
  const room = createRoom(db, { code: "ABC234", name: "실패", createdBy: alice.id })!;
  const events: unknown[] = [];
  hub.subscribe(room.code, alice.handle, "test", (_name, data) => { events.push(data); return true; }, () => {});
  for (const kind of ["photo", "mascot-01", null]) {
    const observed: { phase: string; version: number; previous: Buffer; next?: Buffer }[] = [];
    const exec = db.exec.bind(db);
    const mocked = t.mock.method(db, "exec", (sql: string) => {
      if (sql === "BEGIN" || sql === "COMMIT") {
        const nextPath = join(avatarsDir, "alice-2.png");
        observed.push({
          phase: sql, version: findUserByHandle(db, "alice")!.avatar.version,
          previous: readFileSync(join(avatarsDir, "alice-1.png")),
          next: existsSync(nextPath) ? readFileSync(nextPath) : undefined,
        });
      }
      if (sql === "COMMIT") throw new Error("모의 COMMIT 실패");
      return exec(sql);
    });
    try {
      const failed = await request(kind === null ? "DELETE" : "PUT", "/v1/me/avatar",
        kind === null ? undefined : { kind, ...(kind === "photo" ? { png: next.toString("base64") } : {}) });
      assert.equal(failed.status, 500);
      assert.equal(failed.body.error.code, "INTERNAL_ERROR");
      assert.deepEqual(observed, [
        { phase: "BEGIN", version: 1, previous, next: kind === "photo" ? next : undefined },
        { phase: "COMMIT", version: 2, previous, next: kind === "photo" ? next : undefined },
      ]);
    } finally { mocked.mock.restore(); }
    assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: "photo", version: 1 });
    assert.deepEqual(readdirSync(avatarsDir), ["alice-1.png"]);
    const got = await request("GET", "/v1/users/alice/avatar?v=1");
    assert.equal(got.status, 200);
    assert.equal(got.headers.get("cache-control"), "private, max-age=31536000, immutable");
    assert.deepEqual(got.bytes, previous);
    const unpublished = await request("GET", "/v1/users/alice/avatar?v=2");
    assert.equal(unpublished.status, 404);
    assert.equal(unpublished.headers.get("cache-control"), "no-store");
    assert.deepEqual(events, []);
  }
  const retried = await request("PUT", "/v1/me/avatar", { kind: "photo", png: next.toString("base64") });
  assert.equal(retried.status, 200);
  assert.deepEqual(retried.body.user.avatar, { kind: "photo", version: 2 });
  assert.deepEqual(readdirSync(avatarsDir), ["alice-2.png"]);
  assert.equal(events.length, 1);
});

test("미커밋 고아 파일이 있어도 GET은 DB의 현재 사진만 반환하고 다음 저장은 고아 버전을 대체한다", timeout, async (t) => {
  const { avatarsDir, request } = fixture(t);
  const previous = png();
  await request("PUT", "/v1/me/avatar", { kind: "photo", png: previous.toString("base64") });
  writeFileSync(join(avatarsDir, "alice-2.png"), png({ colorType: 2 }));
  const current = await request("GET", "/v1/users/alice/avatar?v=1");
  assert.equal(current.status, 200);
  assert.deepEqual(current.bytes, previous);
  assert.equal((await request("GET", "/v1/users/alice/avatar?v=2")).status, 404);
  const next = png({ padding: 1 });
  const uploaded = await request("PUT", "/v1/me/avatar", { kind: "photo", png: next.toString("base64") });
  assert.equal(uploaded.status, 200);
  assert.deepEqual(uploaded.body.user.avatar, { kind: "photo", version: 2 });
  assert.deepEqual(readdirSync(avatarsDir), ["alice-2.png"]);
  assert.deepEqual((await request("GET", "/v1/users/alice/avatar?v=2")).bytes, next);
});

test("기존 handle.png는 현재 버전 GET에서 한 번 이동하고 다음 저장에서 제거한다", timeout, async (t) => {
  const { db, avatarsDir, request } = fixture(t);
  const previous = png();
  mkdirSync(avatarsDir);
  writeFileSync(join(avatarsDir, "alice.png"), previous);
  db.exec("UPDATE users SET avatar_kind = 'photo', avatar_version = 7 WHERE handle = 'alice'");
  assert.equal((await request("GET", "/v1/users/alice/avatar?v=6")).status, 404);
  assert.deepEqual(readdirSync(avatarsDir), ["alice.png"]);
  for (let attempt = 0; attempt < 2; attempt++) {
    const got = await request("GET", "/v1/users/alice/avatar?v=7");
    assert.equal(got.status, 200);
    assert.deepEqual(got.bytes, previous);
    assert.deepEqual(readdirSync(avatarsDir), ["alice-7.png"]);
    assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: "photo", version: 7 });
  }
  const uploaded = await request("PUT", "/v1/me/avatar", { kind: "photo", png: png({ colorType: 2 }).toString("base64") });
  assert.equal(uploaded.status, 200);
  assert.deepEqual(uploaded.body.user.avatar, { kind: "photo", version: 8 });
  assert.deepEqual(readdirSync(avatarsDir), ["alice-8.png"]);
});

test("조회는 인증·현재 version이 필요하고 PNG에 private immutable 헤더를 보낸다", timeout, async (t) => {
  const { request, bobToken } = fixture(t);
  const bytes = png();
  assert.equal((await request("PUT", "/v1/me/avatar", { kind: "mascot-01" }, null)).status, 401);
  await request("PUT", "/v1/me/avatar", { kind: "photo", png: bytes.toString("base64") });
  const path = "/v1/users/alice/avatar?v=1";
  assert.equal((await request("GET", path, undefined, null)).status, 401);
  const got = await request("GET", path, undefined, bobToken);
  assert.equal(got.status, 200);
  assert.equal(got.headers.get("content-type"), "image/png");
  assert.equal(got.headers.get("cache-control"), "private, max-age=31536000, immutable");
  assert.deepEqual(got.bytes, bytes);
  await request("PUT", "/v1/me/avatar", { kind: "photo", png: bytes.toString("base64") });
  const stale = await request("GET", path);
  assert.equal(stale.status, 404);
  assert.equal(stale.headers.get("cache-control"), "no-store");
  assert.equal((await request("GET", "/v1/users/alice/avatar?v=2")).status, 200);
  assert.equal((await request("GET", "/v1/users/alice%2F..%2Fbob/avatar?v=2")).status, 400);
  await request("DELETE", "/v1/me/avatar");
  assert.equal((await request("GET", "/v1/users/alice/avatar?v=3")).status, 404);
});

test("잘못된 업로드는 파일·버전·방송을 변경하지 않으며 일반 API 본문 제한은 그대로다", timeout, async (t) => {
  const { db, hub, alice, avatarsDir, request } = fixture(t);
  const room = createRoom(db, { code: "ABC234", name: "검증", createdBy: alice.id })!;
  const events: unknown[] = [];
  hub.subscribe(room.code, alice.handle, "test", (_name, data) => { events.push(data); return true; }, () => {});
  for (const body of [
    { kind: "mascot-06" }, { kind: null }, { kind: "mascot-01", png: "bad" },
    { kind: "photo", png: "no png" }, { kind: "photo", png: png({ width: 128 }).toString("base64") },
    { kind: "photo", png: Buffer.alloc(MAX_AVATAR_BYTES + 1).toString("base64") },
  ]) assert.equal((await request("PUT", "/v1/me/avatar", body)).status, 400);
  assert.equal((await request("PUT", "/v1/me/avatar", { kind: "photo", png: "a".repeat(500_000) })).status, 413);
  assert.equal((await request("PATCH", "/v1/me", { displayName: "a".repeat(70_000) })).status, 413);
  assert.deepEqual(findUserByHandle(db, "alice")?.avatar, { kind: null, version: 0 });
  assert.equal(existsSync(avatarsDir), false);
  assert.deepEqual(events, []);
});

test("첫 joined_at 순번·공개 아바타를 보존하고 현재 활성 방에만 아바타 변경을 방송한다", timeout, async (t) => {
  const { db, hub, alice, bob, request, hello } = fixture(t);
  const first = createRoom(db, { code: "ABC234", name: "첫 방", createdBy: bob.id }, "2026-01-01")!;
  joinRoom(db, first.id, alice.id, "2026-01-01");
  const third = createUser(db, { handle: "aaa", displayName: "세 번째", passwordHash: "unused" })!;
  joinRoom(db, first.id, third.id, "2026-01-01");
  assert.deepEqual(listRoomMembers(db, first.id).map((member) => [member.handle, member.order]), [["bob", 0], ["alice", 1], ["aaa", 2]]);
  leaveRoom(db, first.id, bob.id);
  assert.deepEqual(listRoomMembers(db, first.id).map((member) => member.order), [1, 2]);
  joinRoom(db, first.id, bob.id, "2026-12-01");
  assert.equal(listRoomMembers(db, first.id)[0].joinedAt, "2026-01-01");
  const fourth = createUser(db, { handle: "fourth", displayName: "네 번째", passwordHash: "unused" })!;
  const second = createRoom(db, { code: "DEF567", name: "나간 방", createdBy: fourth.id })!;
  leaveRoom(db, first.id, alice.id);
  joinRoom(db, second.id, alice.id);
  leaveRoom(db, second.id, alice.id);
  joinRoom(db, first.id, alice.id);
  leaveRoom(db, first.id, third.id);
  const absent = createRoom(db, { code: "XYZ234", name: "다른 방", createdBy: third.id })!;
  const events: { code: string; name: string; data: unknown }[] = [];
  for (const room of [first, second, absent]) {
    hub.subscribe(room.code, room.createdBy, "test", (name, data) => { events.push({ code: room.code, name, data }); return true; }, () => {});
  }
  addContact(db, alice.id, bob.id);
  addContact(db, alice.id, third.id);
  const updated = await request("PUT", "/v1/me/avatar", { kind: "mascot-05" });
  const avatar = { kind: "mascot-05", version: 1 };
  assert.deepEqual(updated.body.user.avatar, avatar);
  assert.deepEqual(events, [{ code: first.code, name: "member-updated", data: { handle: "alice", avatar } }]);
  const detail = (await request("GET", `/v1/rooms/${first.code}`)).body;
  assert.deepEqual(detail.members.find((member: { handle: string }) => member.handle === "alice").avatar, avatar);
  const snapshot = hello(first.code);
  assert.deepEqual(snapshot.self.avatar, avatar);
  assert.equal(snapshot.self.order, 1);
  assert.deepEqual(snapshot.members, detail.members);
  const me = (await request("GET", "/v1/me")).body;
  assert.deepEqual(me.user.avatar, avatar);
  assert.equal(me.user.order, 1);
  assert.equal(me.room.code, first.code);
  assert.equal(me.room.members[0].order, 0);
  // 연락처의 order는 조회자의 현재 방 기준이며 함께 참여하지 않으면 null이다.
  const contacts = (await request("GET", "/v1/contacts")).body.contacts;
  assert.deepEqual(contacts.find((contact: { handle: string }) => contact.handle === "bob").avatar, { kind: null, version: 0 });
  assert.equal(contacts.find((contact: { handle: string }) => contact.handle === "bob").order, 0);
  assert.equal(contacts.find((contact: { handle: string }) => contact.handle === "aaa").order, null);
  await request("DELETE", "/v1/me/avatar");
  assert.equal(events.length, 2);
  assert.equal(events.at(-1)?.code, first.code);
  assert.deepEqual(events.at(-1)?.data, { handle: "alice", avatar: { kind: null, version: 2 } });
});

test("파일 DB의 사진 디렉터리는 기존 DB 데이터 폴더를 따른다", timeout, (t) => {
  const directory = mkdtempSync(join(tmpdir(), "unavo-avatar-db-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const db = openDb(join(directory, "nested", "hdapp.sqlite"));
  try {
    const actual = avatarDirectory(db);
    // avatars는 첫 업로드 전엔 없으므로 존재하는 부모 경로만 정규화한다.
    assert.equal(
      join(realpathSync(dirname(actual)), basename(actual)),
      join(realpathSync(join(directory, "nested")), "avatars"),
    );
  }
  finally { db.close(); }
});
