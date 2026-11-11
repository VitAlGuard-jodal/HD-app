import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { updateAvatar } from "./store.ts";
import type { AvatarKind, StoredUser } from "./store.ts";

export const MAX_AVATAR_BYTES = 300 * 1024;
export const MAX_AVATAR_BODY_BYTES = Math.ceil(MAX_AVATAR_BYTES / 3) * 4 + 1024;
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

export function isMascotKind(value: unknown): value is Exclude<AvatarKind, null | "photo"> {
  return typeof value === "string" && /^mascot-0[1-5]$/.test(value);
}

// 크기는 디코딩 전에도 검사한다. Buffer.from의 관대한 base64 파싱은 허용하지 않는다.
export function avatarPng(value: unknown): Buffer | undefined {
  if (typeof value !== "string" || value.length === 0
    || value.length > Math.ceil(MAX_AVATAR_BYTES / 3) * 4
    || value.length % 4 !== 0
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return undefined;
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value || bytes.length > MAX_AVATAR_BYTES || bytes.length < 33
    || !bytes.subarray(0, 8).equals(signature)
    || bytes.readUInt32BE(8) !== 13 || bytes.toString("ascii", 12, 16) !== "IHDR"
    || bytes.readUInt32BE(16) !== 256 || bytes.readUInt32BE(20) !== 256) return undefined;
  // 잘린 파일·다른 형식의 후행 데이터도 저장하지 않는다.
  let offset = 8;
  let hasData = false;
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString("ascii", offset + 4, offset + 8);
    offset += 12 + length;
    if (offset > bytes.length) return undefined;
    if (type === "IDAT") hasData = true;
    if (type === "IEND") return hasData && length === 0 && offset === bytes.length ? bytes : undefined;
  }
  return undefined;
}

export function avatarDirectory(db: DatabaseSync): string {
  const main = (db.prepare("PRAGMA database_list").all() as { name: string; file: string }[])
    .find((entry) => entry.name === "main");
  return main?.file ? join(dirname(main.file), "avatars")
    : fileURLToPath(new URL("../data/avatars/", import.meta.url));
}

export function readAvatar(directory: string, handle: string): Buffer | undefined {
  try {
    return readFileSync(join(directory, `${handle}.png`));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

// 작은 파일과 동기 SQLite 변경을 한 작업으로 처리한다. 실패 시 이전 바이트를 복원한다.
export function saveAvatar(
  db: DatabaseSync, directory: string, user: StoredUser, kind: AvatarKind, png?: Buffer,
): StoredUser {
  const path = join(directory, `${user.handle}.png`);
  const previous = readAvatar(directory, user.handle);
  db.exec("BEGIN");
  try {
    if (kind === "photo") {
      if (!png) throw new Error("프로필 PNG가 필요합니다.");
      mkdirSync(directory, { recursive: true });
      writeFileSync(path, png, { mode: 0o600 });
    } else {
      rmSync(path, { force: true });
    }
    const updated = updateAvatar(db, user.id, kind);
    if (!updated) throw new Error("프로필 계정이 없습니다.");
    db.exec("COMMIT");
    return updated;
  } catch (error) {
    db.exec("ROLLBACK");
    if (previous) writeFileSync(path, previous, { mode: 0o600 });
    else rmSync(path, { force: true });
    throw error;
  }
}
