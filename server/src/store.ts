import type { DatabaseSync } from "node:sqlite";

export interface PublicUser {
  handle: string;
  displayName: string;
}

export interface StoredUser extends PublicUser {
  id: number;
  passwordHash: string;
  createdAt: string;
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
}

export function publicUser(user: PublicUser): PublicUser {
  return { handle: user.handle, displayName: user.displayName };
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
           password_hash AS passwordHash, created_at AS createdAt
    FROM users WHERE handle = ?
  `).get(handle) as StoredUser | undefined;
  return row ? { ...row } : undefined;
}

export function createUser(
  db: DatabaseSync,
  input: { handle: string; displayName: string; passwordHash: string },
  now = new Date().toISOString(),
): StoredUser | undefined {
  const result = db.prepare(`
    INSERT INTO users (handle, display_name, password_hash, created_at)
    VALUES (?, ?, ?, ?) ON CONFLICT(handle) DO NOTHING
  `).run(input.handle, input.displayName.trim(), input.passwordHash, now);
  return result.changes ? findUserByHandle(db, input.handle) : undefined;
}

export function updateDisplayName(db: DatabaseSync, userId: number, displayName: string): StoredUser | undefined {
  const row = db.prepare(`
    UPDATE users SET display_name = ? WHERE id = ?
    RETURNING id, handle, display_name AS displayName,
              password_hash AS passwordHash, created_at AS createdAt
  `).get(displayName.trim(), userId) as StoredUser | undefined;
  return row ? { ...row } : undefined;
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
           u.password_hash AS passwordHash, u.created_at AS createdAt
    FROM tokens t JOIN users u ON u.id = t.user_id
    WHERE t.token_hash = ? AND t.revoked = 0 AND t.expires_at > ?
  `).get(tokenHash, now) as StoredUser | undefined;
  return row ? { ...row } : undefined;
}

export function revokeTokenHash(db: DatabaseSync, tokenHash: string): void {
  db.prepare("UPDATE tokens SET revoked = 1 WHERE token_hash = ?").run(tokenHash);
}

export function listContacts(db: DatabaseSync, ownerId: number): PublicUser[] {
  const rows = db.prepare(`
    SELECT u.handle, u.display_name AS displayName
    FROM contacts c JOIN users u ON u.id = c.contact_id
    WHERE c.owner_id = ? ORDER BY u.handle
  `).all(ownerId) as unknown as PublicUser[];
  return rows.map(publicUser);
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
  // 재접속으로 반복 호출되어도 이미 참여 중인 사람의 시각은 바꾸지 않는다.
  return Boolean(db.prepare(`
    INSERT INTO room_members (room_id, user_id, joined_at, left_at)
    VALUES (?, ?, ?, NULL)
    ON CONFLICT(room_id, user_id) DO UPDATE
    SET joined_at = excluded.joined_at, left_at = NULL
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
    SELECT u.handle, u.display_name AS displayName, m.joined_at AS joinedAt
    FROM room_members m JOIN users u ON u.id = m.user_id
    WHERE m.room_id = ? AND m.left_at IS NULL ORDER BY m.joined_at, u.handle
  `).all(roomId) as unknown as RoomMember[];
  return rows.map((row) => ({ ...row }));
}
