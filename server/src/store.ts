import type { DatabaseSync } from "node:sqlite";

export type AvatarKind = null | "mascot-01" | "mascot-02" | "mascot-03" | "mascot-04" | "mascot-05" | "photo";
export interface Avatar {
  kind: AvatarKind;
  version: number;
}

export interface PublicUser {
  handle: string;
  displayName: string;
  avatar: Avatar;
}

export interface StoredUser extends PublicUser {
  id: number;
  passwordHash: string;
  createdAt: string;
}

export interface ConsentRecord {
  privacy: { version: string; at: string } | null;
  location: { version: string; at: string } | null;
}

export interface PublicRoom {
  code: string;
  name: string;
  createdBy: string;
  createdAt: string;
  leader: string;
}

export interface StoredRoom extends Omit<PublicRoom, "leader"> {
  id: number;
}

export interface RoomMember extends PublicUser {
  joinedAt: string;
  order: number;
}

type UserRow = Omit<StoredUser, "avatar"> & { avatarKind: AvatarKind; avatarVersion: number };

function storedUser(row: UserRow | undefined): StoredUser | undefined {
  if (!row) return undefined;
  const { avatarKind, avatarVersion, ...user } = row;
  return { ...user, avatar: { kind: avatarKind, version: avatarVersion } };
}

// 스키마와 쿼리를 한곳에 두어 다른 모듈이 저장 방식에 의존하지 않게 한다.
export function initializeSchema(db: DatabaseSync): void {
  db.exec(`
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY,
      handle TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS tokens (
      token_hash TEXT PRIMARY KEY NOT NULL,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      expires_at TEXT NOT NULL,
      revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
    );
    CREATE INDEX IF NOT EXISTS tokens_user_id ON tokens(user_id);
    CREATE TABLE IF NOT EXISTS contacts (
      owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      contact_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      created_at TEXT NOT NULL,
      PRIMARY KEY (owner_id, contact_id),
      CHECK (owner_id <> contact_id)
    );
    CREATE TABLE IF NOT EXISTS rooms (
      id INTEGER PRIMARY KEY,
      code TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      created_by INTEGER NOT NULL REFERENCES users(id),
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS room_members (
      room_id INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      joined_at TEXT NOT NULL,
      left_at TEXT,
      PRIMARY KEY (room_id, user_id)
    );
  `);
  // 기존 계정 DB에도 기본 프로필을 부여한다. 반복 초기화는 무변경이다.
  const columns = db.prepare("PRAGMA table_info(users)").all() as { name: string }[];
  if (!columns.some((column) => column.name === "avatar_kind")) {
    db.exec(`ALTER TABLE users ADD COLUMN avatar_kind TEXT DEFAULT NULL
      CHECK (avatar_kind IS NULL OR avatar_kind IN ('mascot-01','mascot-02','mascot-03','mascot-04','mascot-05','photo'))`);
  }
  if (!columns.some((column) => column.name === "avatar_version")) {
    db.exec("ALTER TABLE users ADD COLUMN avatar_version INTEGER NOT NULL DEFAULT 0 CHECK (avatar_version >= 0)");
  }
  for (const name of ["age_confirmed_at", "privacy_version", "privacy_consented_at", "location_version", "location_consented_at"]) {
    if (!columns.some((column) => column.name === name)) {
      db.exec(`ALTER TABLE users ADD COLUMN ${name} TEXT`);
    }
  }
}

export function publicUser(user: PublicUser): PublicUser {
  return { handle: user.handle, displayName: user.displayName, avatar: { ...user.avatar } };
}

export function publicRoom(room: Omit<PublicRoom, "leader">): PublicRoom {
  return {
    code: room.code,
    name: room.name,
    createdBy: room.createdBy,
    createdAt: room.createdAt,
    leader: room.createdBy,
  };
}

export function publicRoomDetails(db: DatabaseSync, room: StoredRoom): PublicRoom & { members: RoomMember[] } {
  return { ...publicRoom(room), members: listRoomMembers(db, room.id) };
}

export function findUserByHandle(db: DatabaseSync, handle: string): StoredUser | undefined {
  const row = db.prepare(`
    SELECT id, handle, display_name AS displayName,
           password_hash AS passwordHash, created_at AS createdAt,
           avatar_kind AS avatarKind, avatar_version AS avatarVersion
    FROM users WHERE handle = ?
  `).get(handle) as UserRow | undefined;
  return storedUser(row);
}

export function createUser(
  db: DatabaseSync,
  input: { handle: string; displayName: string; passwordHash: string; ageConfirmedAt?: string },
  now = new Date().toISOString(),
): StoredUser | undefined {
  const result = db.prepare(`
    INSERT INTO users (handle, display_name, password_hash, created_at, age_confirmed_at)
    VALUES (?, ?, ?, ?, ?) ON CONFLICT(handle) DO NOTHING
  `).run(input.handle, input.displayName.trim(), input.passwordHash, now, input.ageConfirmedAt ?? null);
  return result.changes ? findUserByHandle(db, input.handle) : undefined;
}

export function readUserConsent(db: DatabaseSync, userId: number): ConsentRecord {
  const row = db.prepare(`
    SELECT privacy_version AS privacyVersion, privacy_consented_at AS privacyAt,
           location_version AS locationVersion, location_consented_at AS locationAt
    FROM users WHERE id = ?
  `).get(userId) as {
    privacyVersion: string | null; privacyAt: string | null;
    locationVersion: string | null; locationAt: string | null;
  } | undefined;
  return {
    privacy: row?.privacyVersion && row.privacyAt ? { version: row.privacyVersion, at: row.privacyAt } : null,
    location: row?.locationVersion && row.locationAt ? { version: row.locationVersion, at: row.locationAt } : null,
  };
}

export function updateUserConsent(
  db: DatabaseSync,
  userId: number,
  input: { privacyVersion?: string; locationVersion?: string },
  now = new Date().toISOString(),
): ConsentRecord {
  // 두 항목은 한 UPDATE로 저장하며, 생략한 항목의 버전·시각은 보존한다.
  db.prepare(`
    UPDATE users SET
      privacy_version = COALESCE(?, privacy_version),
      privacy_consented_at = CASE WHEN ? IS NOT NULL THEN ? ELSE privacy_consented_at END,
      location_version = COALESCE(?, location_version),
      location_consented_at = CASE WHEN ? IS NOT NULL THEN ? ELSE location_consented_at END
    WHERE id = ?
  `).run(input.privacyVersion ?? null, input.privacyVersion ?? null, now,
    input.locationVersion ?? null, input.locationVersion ?? null, now, userId);
  return readUserConsent(db, userId);
}

export function updateDisplayName(db: DatabaseSync, userId: number, displayName: string): StoredUser | undefined {
  const row = db.prepare(`
    UPDATE users SET display_name = ? WHERE id = ?
    RETURNING id, handle, display_name AS displayName,
              password_hash AS passwordHash, created_at AS createdAt,
              avatar_kind AS avatarKind, avatar_version AS avatarVersion
  `).get(displayName.trim(), userId) as UserRow | undefined;
  return storedUser(row);
}

export function updateAvatar(db: DatabaseSync, userId: number, kind: AvatarKind): StoredUser | undefined {
  const row = db.prepare(`
    UPDATE users SET avatar_kind = ?, avatar_version = avatar_version + 1 WHERE id = ?
    RETURNING id, handle, display_name AS displayName,
              password_hash AS passwordHash, created_at AS createdAt,
              avatar_kind AS avatarKind, avatar_version AS avatarVersion
  `).get(kind, userId) as UserRow | undefined;
  return storedUser(row);
}

export function userRoomCodes(db: DatabaseSync, userId: number): string[] {
  const rows = db.prepare(`
    SELECT r.code FROM room_members m JOIN rooms r ON r.id = m.room_id
    WHERE m.user_id = ? AND m.left_at IS NULL
    ORDER BY r.id
  `).all(userId) as { code: string }[];
  return rows.map((row) => row.code);
}

export function saveToken(
  db: DatabaseSync,
  tokenHash: string,
  userId: number,
  expiresAt: string,
): void {
  db.prepare(`
    INSERT INTO tokens (token_hash, user_id, expires_at, revoked) VALUES (?, ?, ?, 0)
  `).run(tokenHash, userId, expiresAt);
}

export function findTokenUser(
  db: DatabaseSync,
  tokenHash: string,
  now: string,
): StoredUser | undefined {
  const row = db.prepare(`
    SELECT u.id, u.handle, u.display_name AS displayName,
           u.password_hash AS passwordHash, u.created_at AS createdAt,
           u.avatar_kind AS avatarKind, u.avatar_version AS avatarVersion
    FROM tokens t JOIN users u ON u.id = t.user_id
    WHERE t.token_hash = ? AND t.revoked = 0 AND t.expires_at > ?
  `).get(tokenHash, now) as UserRow | undefined;
  return storedUser(row);
}

export function revokeTokenHash(db: DatabaseSync, tokenHash: string): void {
  db.prepare("UPDATE tokens SET revoked = 1 WHERE token_hash = ?").run(tokenHash);
}

export function listContacts(db: DatabaseSync, ownerId: number): PublicUser[] {
  const rows = db.prepare(`
    SELECT u.handle, u.display_name AS displayName,
           u.avatar_kind AS avatarKind, u.avatar_version AS avatarVersion
    FROM contacts c JOIN users u ON u.id = c.contact_id
    WHERE c.owner_id = ? ORDER BY u.handle
  `).all(ownerId) as { handle: string; displayName: string; avatarKind: AvatarKind; avatarVersion: number }[];
  return rows.map(({ handle, displayName, avatarKind, avatarVersion }) => ({
    handle, displayName, avatar: { kind: avatarKind, version: avatarVersion },
  }));
}

export function addContact(
  db: DatabaseSync,
  ownerId: number,
  contactId: number,
  now = new Date().toISOString(),
): boolean {
  if (ownerId === contactId) return false;
  return Boolean(db.prepare(`
    INSERT INTO contacts (owner_id, contact_id, created_at)
    VALUES (?, ?, ?) ON CONFLICT(owner_id, contact_id) DO NOTHING
  `).run(ownerId, contactId, now).changes);
}

export function deleteContact(db: DatabaseSync, ownerId: number, handle: string): boolean {
  return Boolean(db.prepare(`
    DELETE FROM contacts
    WHERE owner_id = ? AND contact_id = (SELECT id FROM users WHERE handle = ?)
  `).run(ownerId, handle).changes);
}

export function findRoomByCode(db: DatabaseSync, code: string): StoredRoom | undefined {
  const row = db.prepare(`
    SELECT r.id, r.code, r.name, u.handle AS createdBy, r.created_at AS createdAt
    FROM rooms r JOIN users u ON u.id = r.created_by WHERE r.code = ?
  `).get(code) as StoredRoom | undefined;
  return row ? { ...row } : undefined;
}

export function findCurrentRoom(db: DatabaseSync, userId: number): StoredRoom | undefined {
  const row = db.prepare(`
    SELECT r.id, r.code, r.name, u.handle AS createdBy, r.created_at AS createdAt
    FROM room_members m
    JOIN rooms r ON r.id = m.room_id
    JOIN users u ON u.id = r.created_by
    WHERE m.user_id = ? AND m.left_at IS NULL
    ORDER BY m.joined_at DESC, r.id DESC LIMIT 1
  `).get(userId) as StoredRoom | undefined;
  return row ? { ...row } : undefined;
}

export function createRoom(
  db: DatabaseSync,
  input: { code: string; name: string; createdBy: number },
  now = new Date().toISOString(),
): StoredRoom | undefined {
  // 방과 만든 사람의 참여 기록은 함께 저장되거나 함께 취소되어야 한다.
  db.exec("BEGIN");
  try {
    const result = db.prepare(`
      INSERT INTO rooms (code, name, created_by, created_at)
      VALUES (?, ?, ?, ?) ON CONFLICT(code) DO NOTHING
    `).run(input.code, input.name, input.createdBy, now);
    if (!result.changes) {
      db.exec("ROLLBACK");
      return undefined;
    }
    db.prepare(`
      INSERT INTO room_members (room_id, user_id, joined_at, left_at)
      VALUES (?, ?, ?, NULL)
    `).run(result.lastInsertRowid, input.createdBy, now);
    const room = findRoomByCode(db, input.code);
    db.exec("COMMIT");
    return room;
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function joinRoom(
  db: DatabaseSync,
  roomId: number,
  userId: number,
  now = new Date().toISOString(),
): boolean {
  // 재입장도 첫 참여 시각을 보존하여 방 안 색상·순번이 바뀌지 않는다.
  return Boolean(db.prepare(`
    INSERT INTO room_members (room_id, user_id, joined_at, left_at)
    VALUES (?, ?, ?, NULL)
    ON CONFLICT(room_id, user_id) DO UPDATE
    SET left_at = NULL
    WHERE room_members.left_at IS NOT NULL
  `).run(roomId, userId, now).changes);
}

export function leaveRoom(
  db: DatabaseSync,
  roomId: number,
  userId: number,
  now = new Date().toISOString(),
): boolean {
  return Boolean(db.prepare(`
    UPDATE room_members SET left_at = ?
    WHERE room_id = ? AND user_id = ? AND left_at IS NULL
  `).run(now, roomId, userId).changes);
}

export function isRoomMember(db: DatabaseSync, roomId: number, userId: number): boolean {
  return Boolean(db.prepare(`
    SELECT 1 FROM room_members WHERE room_id = ? AND user_id = ? AND left_at IS NULL
  `).get(roomId, userId));
}

export function deleteEmptyRoom(db: DatabaseSync, roomId: number): boolean {
  return Boolean(db.prepare(`
    DELETE FROM rooms WHERE id = ? AND NOT EXISTS (
      SELECT 1 FROM room_members WHERE room_id = rooms.id AND left_at IS NULL
    )
  `).run(roomId).changes);
}

export function findRoomMembership(db: DatabaseSync, roomId: number, userId: number): {
  joinedAt: string; leftAt: string | null;
} | undefined {
  const row = db.prepare(`
    SELECT joined_at AS joinedAt, left_at AS leftAt
    FROM room_members WHERE room_id = ? AND user_id = ?
  `).get(roomId, userId) as { joinedAt: string; leftAt: string | null } | undefined;
  return row ? { ...row } : undefined;
}

export function listRoomMembers(db: DatabaseSync, roomId: number): RoomMember[] {
  const rows = db.prepare(`
    WITH ordered AS (
      SELECT user_id, joined_at, left_at,
             ROW_NUMBER() OVER (ORDER BY joined_at, rowid) - 1 AS member_order
      FROM room_members WHERE room_id = ?
    )
    SELECT u.handle, u.display_name AS displayName, m.joined_at AS joinedAt,
           m.member_order AS "order", u.avatar_kind AS avatarKind, u.avatar_version AS avatarVersion
    FROM ordered m JOIN users u ON u.id = m.user_id
    WHERE m.left_at IS NULL ORDER BY m.member_order
  `).all(roomId) as (Omit<RoomMember, "avatar"> & { avatarKind: AvatarKind; avatarVersion: number })[];
  return rows.map(({ avatarKind, avatarVersion, ...member }) => ({
    ...member, avatar: { kind: avatarKind, version: avatarVersion },
  }));
}
