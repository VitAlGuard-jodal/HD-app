import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { openDb } from "../../src/db.ts";
import {
  addContact, createRoom, createUser, deleteContact, findCurrentRoom, findRoomByCode, findRoomMembership,
  findUserByHandle, hasOtherValidTokens, isRoomMember, joinRoom, leaveRoom, listContacts, listRoomMembers, publicRoom, publicUser,
  initializeSchema, revokeTokenHash, saveToken, updateDisplayName,
} from "../../src/store.ts";

function fixture(t: TestContext) {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const alice = createUser(db, { handle: "alice", displayName: "  앨리스  ", passwordHash: "alice-hash" })!;
  const bob = createUser(db, { handle: "bob", displayName: "보비", passwordHash: "bob-hash" })!;
  return { db, alice, bob };
}

test("옛 users 스키마에 동의 열 5개를 추가하고 반복 초기화는 스키마와 기록을 보존한다", (t) => {
  const db = new DatabaseSync(":memory:");
  t.after(() => db.close());
  db.exec(`CREATE TABLE users (
    id INTEGER PRIMARY KEY, handle TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
    password_hash TEXT NOT NULL, created_at TEXT NOT NULL
  );
  INSERT INTO users VALUES (1, 'alice', '앨리스', 'stored-hash', '2026-01-01T00:00:00.000Z');`);
  const names = ["age_confirmed_at", "privacy_version", "privacy_consented_at", "location_version", "location_consented_at"];
  initializeSchema(db);
  const columns = db.prepare("PRAGMA table_info(users)").all();
  for (const name of names) {
    const column = columns.find((entry) => entry.name === name);
    assert.ok(column);
    assert.equal(column.type, "TEXT");
    assert.equal(column.notnull, 0);
    assert.equal(db.prepare(`SELECT ${name} AS value FROM users WHERE id = 1`).get()!.value, null);
  }
  db.exec("UPDATE users SET privacy_version = '3', privacy_consented_at = '2026-11-12T00:00:00.000Z' WHERE id = 1");
  const before = db.prepare("SELECT * FROM users").all();
  const schemaVersion = db.prepare("PRAGMA schema_version").get();
  initializeSchema(db);
  assert.deepEqual(db.prepare("PRAGMA table_info(users)").all(), columns);
  assert.deepEqual(db.prepare("PRAGMA schema_version").get(), schemaVersion);
  assert.deepEqual(db.prepare("SELECT * FROM users").all(), before);
});

for (const tied of [false, true]) {
  test(`중복 활성 멤버십 초기화는 ${tied ? "동률의 큰 room id" : "가장 최근 joined_at"}만 남기고 반복 실행은 무변경이다`, (t) => {
    const now = "2026-11-12T00:00:00.000Z";
    t.mock.timers.enable({ apis: ["Date"], now: Date.parse(now) });
    const { db, alice, bob } = fixture(t);
    // 부분 UNIQUE가 없던 기존 DB의 중복 참여 데이터를 재현한다.
    db.exec("DROP INDEX room_members_active_user");
    const first = createRoom(db, { code: "ABC234", name: "첫 방", createdBy: alice.id }, "2026-01-02T00:00:00.000Z")!;
    const second = createRoom(db, { code: "DEF567", name: "둘째 방", createdBy: alice.id },
      tied ? first.createdAt : "2026-01-01T00:00:00.000Z")!;
    joinRoom(db, first.id, bob.id, "2026-01-03T00:00:00.000Z");
    leaveRoom(db, first.id, bob.id, "2026-01-04T00:00:00.000Z");
    joinRoom(db, second.id, bob.id, "2026-01-05T00:00:00.000Z");
    const expected = findCurrentRoom(db, alice.id)!;
    assert.equal(expected.id, tied ? second.id : first.id);
    const before = db.prepare("SELECT * FROM room_members ORDER BY user_id, room_id").all();

    initializeSchema(db);

    assert.deepEqual(findCurrentRoom(db, alice.id), expected);
    assert.deepEqual(db.prepare("SELECT * FROM room_members ORDER BY user_id, room_id").all().map((row) => ({ ...row })), before.map((row) => ({
      ...row, left_at: row.user_id === alice.id && row.room_id !== expected.id ? now : row.left_at,
    })));
    assert.deepEqual(db.prepare("SELECT user_id, COUNT(*) AS count FROM room_members WHERE left_at IS NULL GROUP BY user_id ORDER BY user_id")
      .all().map((row) => ({ ...row })), [{ user_id: alice.id, count: 1 }, { user_id: bob.id, count: 1 }]);
    const index = db.prepare("PRAGMA index_list(room_members)").all().find((row) => row.name === "room_members_active_user");
    assert.ok(index);
    assert.equal(index.unique, 1);
    assert.equal(index.partial, 1);
    const rows = db.prepare("SELECT * FROM room_members ORDER BY user_id, room_id").all();
    const changes = db.prepare("SELECT total_changes() AS count").get();
    const schemaVersion = db.prepare("PRAGMA schema_version").get();
    initializeSchema(db);
    assert.deepEqual(db.prepare("SELECT * FROM room_members ORDER BY user_id, room_id").all(), rows);
    assert.deepEqual(db.prepare("SELECT total_changes() AS count").get(), changes);
    assert.deepEqual(db.prepare("PRAGMA schema_version").get(), schemaVersion);
    assert.throws(() => joinRoom(db, expected.id === first.id ? second.id : first.id, alice.id), /UNIQUE/);
  });
}

test("다른 유효 토큰은 같은 계정의 미폐기·미만료 토큰만 세며 현재 토큰을 제외한다", (t) => {
  const { db, alice, bob } = fixture(t);
  const now = "2026-11-12T00:00:00.000Z";
  const future = "2026-12-12T00:00:00.000Z";
  saveToken(db, "current", alice.id, future);
  saveToken(db, "other-user", bob.id, future);
  saveToken(db, "expired", alice.id, "2026-11-11T00:00:00.000Z");
  saveToken(db, "expires-now", alice.id, now);
  saveToken(db, "revoked", alice.id, future);
  revokeTokenHash(db, "revoked");
  assert.equal(hasOtherValidTokens(db, alice.id, "current", now), false);
  saveToken(db, "other-device", alice.id, future);
  assert.equal(hasOtherValidTokens(db, alice.id, "current", now), true);
  revokeTokenHash(db, "current");
  assert.equal(hasOtherValidTokens(db, alice.id, "current", now), true);
  revokeTokenHash(db, "other-device");
  assert.equal(hasOtherValidTokens(db, alice.id, "current", now), false);
});

test("사용자를 저장하고 공개 정보에서 내부 식별자와 해시를 숨긴다", (t) => {
  const { db, alice } = fixture(t);
  assert.equal(alice.displayName, "앨리스");
  assert.equal(findUserByHandle(db, "alice")?.passwordHash, "alice-hash");
  assert.deepEqual(publicUser(alice), { handle: "alice", displayName: "앨리스", avatar: { kind: null, version: 0 } });
  assert.equal(findUserByHandle(db, "unknown"), undefined);
  assert.equal(findUserByHandle(db, "' OR 1=1 --"), undefined);
  assert.equal(new Date(alice.createdAt).toISOString(), alice.createdAt);
});

test("같은 아이디의 중복 저장은 기존 계정을 바꾸지 않는다", (t) => {
  const { db, alice } = fixture(t);
  assert.equal(createUser(db, { handle: "alice", displayName: "다른사람", passwordHash: "changed" }), undefined);
  assert.deepEqual(findUserByHandle(db, "alice"), alice);
});

test("표시 이름만 갱신하고 사용자 조회·친구 목록·방 참여자에 반영한다", (t) => {
  const { db, alice, bob } = fixture(t);
  addContact(db, bob.id, alice.id);
  const room = createRoom(db, { code: "ABC234", name: "같이 출발", createdBy: alice.id })!;
  const updated = updateDisplayName(db, alice.id, "  새로운 이름  ");
  assert.deepEqual(updated, { ...alice, displayName: "새로운 이름" });
  assert.deepEqual(findUserByHandle(db, "alice"), updated);
  assert.deepEqual(findUserByHandle(db, "bob"), bob);
  assert.deepEqual(listContacts(db, bob.id), [{ handle: "alice", displayName: "새로운 이름", avatar: { kind: null, version: 0 } }]);
  assert.deepEqual(listRoomMembers(db, room.id), [
    { handle: "alice", displayName: "새로운 이름", avatar: { kind: null, version: 0 }, joinedAt: room.createdAt, order: 0 },
  ]);
  assert.equal(updateDisplayName(db, -1, "없는 사용자"), undefined);
});

test("친구는 단방향이며 자기 자신과 중복을 허용하지 않는다", (t) => {
  const { db, alice, bob } = fixture(t);
  assert.equal(addContact(db, alice.id, alice.id), false);
  assert.equal(addContact(db, alice.id, bob.id), true);
  assert.equal(addContact(db, alice.id, bob.id), false);
  assert.deepEqual(listContacts(db, alice.id), [publicUser(bob)]);
  assert.deepEqual(listContacts(db, bob.id), []);
});

test("친구 삭제는 요청한 소유자의 목록에만 적용된다", (t) => {
  const { db, alice, bob } = fixture(t);
  addContact(db, alice.id, bob.id);
  addContact(db, bob.id, alice.id);
  assert.equal(deleteContact(db, alice.id, bob.handle), true);
  assert.equal(deleteContact(db, alice.id, bob.handle), false);
  assert.equal(deleteContact(db, alice.id, "unknown"), false);
  assert.deepEqual(listContacts(db, alice.id), []);
  assert.deepEqual(listContacts(db, bob.id), [publicUser(alice)]);
});

test("존재하지 않는 사용자 참조는 외래 키로 거부된다", (t) => {
  const { db, alice } = fixture(t);
  assert.throws(() => addContact(db, alice.id, 99999), /FOREIGN KEY/);
  assert.deepEqual(listContacts(db, alice.id), []);
});

test("방 생성자는 자동 참여하고 방의 공개 정보에는 코드와 생성자 아이디가 있다", (t) => {
  const { db, alice } = fixture(t);
  const now = "2026-01-01T00:00:00.000Z";
  const room = createRoom(db, { code: "ABC234", name: "같이 출발", createdBy: alice.id }, now)!;
  assert.deepEqual(publicRoom(room), { code: "ABC234", name: "같이 출발", createdBy: "alice", createdAt: now, leader: "alice" });
  assert.deepEqual(listRoomMembers(db, room.id), [{ ...publicUser(alice), joinedAt: now, order: 0 }]);
  assert.equal(isRoomMember(db, room.id, alice.id), true);
  assert.deepEqual(findRoomByCode(db, room.code), room);
});

test("방 코드 충돌은 원래 방과 참여자를 바꾸지 않는다", (t) => {
  const { db, alice, bob } = fixture(t);
  const room = createRoom(db, { code: "ABC234", name: "원래 방", createdBy: alice.id })!;
  assert.equal(createRoom(db, { code: "ABC234", name: "충돌 방", createdBy: bob.id }), undefined);
  assert.deepEqual(findRoomByCode(db, room.code), room);
  assert.equal(isRoomMember(db, room.id, bob.id), false);
});

test("실패한 방 생성은 롤백되어 같은 코드를 다시 쓸 수 있다", (t) => {
  const { db, alice } = fixture(t);
  assert.throws(() => createRoom(db, { code: "ABC234", name: "실패", createdBy: 99999 }), /FOREIGN KEY/);
  assert.equal(findRoomByCode(db, "ABC234"), undefined);
  assert.ok(createRoom(db, { code: "ABC234", name: "성공", createdBy: alice.id }));
});

test("반복 참여는 멱등이며 최초 참여 시각을 유지한다", (t) => {
  const { db, alice, bob } = fixture(t);
  const room = createRoom(db, { code: "ABC234", name: "방", createdBy: alice.id })!;
  const joinedAt = "2026-01-02T00:00:00.000Z";
  assert.equal(joinRoom(db, room.id, bob.id, joinedAt), true);
  assert.equal(joinRoom(db, room.id, bob.id, "2026-01-03T00:00:00.000Z"), false);
  assert.deepEqual(findRoomMembership(db, room.id, bob.id), { joinedAt, leftAt: null });
  assert.equal(listRoomMembers(db, room.id).length, 2);
});

test("나가기는 기록을 남기고 재참여는 기록을 다시 활성화한다", (t) => {
  const { db, alice, bob } = fixture(t);
  const room = createRoom(db, { code: "ABC234", name: "방", createdBy: alice.id })!;
  const joinedAt = "2026-01-02T00:00:00.000Z";
  const leftAt = "2026-01-03T00:00:00.000Z";
  const rejoinedAt = "2026-01-04T00:00:00.000Z";
  joinRoom(db, room.id, bob.id, joinedAt);
  assert.equal(leaveRoom(db, room.id, bob.id, leftAt), true);
  assert.equal(leaveRoom(db, room.id, bob.id), false);
  assert.deepEqual(findRoomMembership(db, room.id, bob.id), { joinedAt, leftAt });
  assert.equal(isRoomMember(db, room.id, bob.id), false);
  assert.deepEqual(listRoomMembers(db, room.id).map((member) => member.handle), [alice.handle]);
  assert.equal(joinRoom(db, room.id, bob.id, rejoinedAt), true);
  assert.deepEqual(findRoomMembership(db, room.id, bob.id), { joinedAt, leftAt: null });
  assert.equal(isRoomMember(db, room.id, bob.id), true);
});

test("방별 참여 기록과 없는 기록은 구분된다", (t) => {
  const { db, alice, bob } = fixture(t);
  const first = createRoom(db, { code: "ABC234", name: "첫째", createdBy: alice.id })!;
  const second = createRoom(db, { code: "DEF567", name: "둘째", createdBy: bob.id })!;
  assert.equal(isRoomMember(db, first.id, bob.id), false);
  assert.equal(isRoomMember(db, second.id, alice.id), false);
  assert.equal(findRoomMembership(db, first.id, bob.id), undefined);
  assert.equal(leaveRoom(db, first.id, bob.id), false);
});

test("활성 멤버십 UNIQUE는 다른 방 생성·입장을 막고 퇴장 뒤 재입장은 허용한다", (t) => {
  const { db, alice, bob } = fixture(t);
  const first = createRoom(db, { code: "ABC234", name: "첫 방", createdBy: alice.id })!;
  const second = createRoom(db, { code: "DEF567", name: "둘째 방", createdBy: bob.id })!;
  assert.throws(() => createRoom(db, { code: "XYZ234", name: "중복 방", createdBy: alice.id }), /UNIQUE/);
  assert.equal(findRoomByCode(db, "XYZ234"), undefined);
  assert.throws(() => joinRoom(db, second.id, alice.id), /UNIQUE/);
  assert.equal(joinRoom(db, first.id, alice.id), false);
  assert.equal(leaveRoom(db, first.id, alice.id), true);
  assert.equal(joinRoom(db, second.id, alice.id), true);
  assert.throws(() => joinRoom(db, first.id, alice.id), /UNIQUE/);
  assert.equal(leaveRoom(db, second.id, alice.id), true);
  assert.equal(joinRoom(db, first.id, alice.id), true);
  assert.deepEqual(findRoomMembership(db, first.id, alice.id), { joinedAt: first.createdAt, leftAt: null });
});

test("파일 DB는 부모 폴더를 만들고 다시 열어도 데이터를 유지한다", () => {
  const directory = mkdtempSync(join(fileURLToPath(new URL("../../data/", import.meta.url)), "unit-"));
  const path = join(directory, "nested", "hdapp.sqlite");
  let db: ReturnType<typeof openDb> | undefined;
  try {
    db = openDb(path);
    const user = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "stored-hash" })!;
    const room = createRoom(db, { code: "ABC234", name: "영구 저장", createdBy: user.id })!;
    db.close();
    db = undefined;
    db = openDb(path);
    assert.deepEqual(findUserByHandle(db, "alice"), user);
    assert.deepEqual(findRoomByCode(db, room.code), room);
    assert.equal(isRoomMember(db, room.id, user.id), true);
  } finally {
    db?.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
