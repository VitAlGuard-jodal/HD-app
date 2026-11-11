import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { openDb } from "../../src/db.ts";
import {
  addContact, createRoom, createUser, deleteContact, findRoomByCode, findRoomMembership,
  findUserByHandle, isRoomMember, joinRoom, leaveRoom, listContacts, listRoomMembers, publicRoom, publicUser,
  updateDisplayName,
} from "../../src/store.ts";

function fixture(t: TestContext) {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const alice = createUser(db, { handle: "alice", displayName: "  앨리스  ", passwordHash: "alice-hash" })!;
  const bob = createUser(db, { handle: "bob", displayName: "보비", passwordHash: "bob-hash" })!;
  return { db, alice, bob };
}

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
