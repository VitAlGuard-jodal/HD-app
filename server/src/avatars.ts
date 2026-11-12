import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { crc32, inflateSync } from "node:zlib";
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
    || bytes.readUInt32BE(16) !== 256 || bytes.readUInt32BE(20) !== 256
    || bytes[24] !== 8 || (bytes[25] !== 2 && bytes[25] !== 6)
    || bytes[26] !== 0 || bytes[27] !== 0 || bytes[28] !== 0) return undefined;
  const channels = bytes[25] === 2 ? 3 : 4;
  const rowLength = 1 + bytes.readUInt32BE(16) * channels;
  const expected = bytes.readUInt32BE(20) * rowLength;
  // 잘린 파일·다른 형식의 후행 데이터도 저장하지 않는다.
  let offset = 8;
  const data: Buffer[] = [];
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString("ascii", offset + 4, offset + 8);
    const end = offset + 12 + length;
    if (end > bytes.length
      || crc32(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)) return undefined;
    if (type === "IDAT") data.push(bytes.subarray(offset + 8, end - 4));
    if (type === "IEND") {
      if (data.length === 0 || length !== 0 || end !== bytes.length) return undefined;
      let pixels: Buffer;
      try {
        // 큰 압축 해제 결과를 먼저 할당하지 않도록 해제 중에도 출력 상한을 적용한다.
        pixels = inflateSync(Buffer.concat(data), { maxOutputLength: expected });
      } catch { return undefined; }
      if (pixels.length !== expected) return undefined;
      for (let row = 0; row < expected; row += rowLength) {
        if (pixels[row] > 4) return undefined;
      }
      return bytes;
    }
    offset = end;
  }
  return undefined;
}

export function avatarDirectory(db: DatabaseSync): string {
  const main = (db.prepare("PRAGMA database_list").all() as { name: string; file: string }[])
    .find((entry) => entry.name === "main");
  return main?.file ? join(dirname(main.file), "avatars")
    : fileURLToPath(new URL("../data/avatars/", import.meta.url));
}

function avatarPath(directory: string, handle: string, version: number): string {
  return join(directory, `${handle}-${version}.png`);
}

export function readAvatar(directory: string, handle: string, version: number): Buffer | undefined {
  const path = avatarPath(directory, handle, version);
  try {
    return readFileSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  // 이전 저장 규칙의 사진은 현재 DB 버전을 읽을 때 한 번 옮긴다.
  const legacyPath = join(directory, `${handle}.png`);
  try {
    const png = readFileSync(legacyPath);
    renameSync(legacyPath, path);
    return png;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

function removeAvatarFile(path: string): void {
  try { rmSync(path, { force: true }); }
  catch (error) {
    // 참조하지 않는 파일의 정리 실패가 이미 커밋된 저장·방송을 실패로 바꾸지는 않는다.
    process.stderr.write(`avatar cleanup failed: ${(error as NodeJS.ErrnoException).code ?? "unknown"}\n`);
  }
}

// 새 버전 파일의 쓰기·close가 끝난 뒤 DB 참조를 바꾼다. 이전 파일은 COMMIT 뒤에만 지운다.
export function saveAvatar(
  db: DatabaseSync, directory: string, user: StoredUser, kind: AvatarKind, png?: Buffer,
): StoredUser {
  const version = user.avatar.version + 1;
  const path = avatarPath(directory, user.handle, version);
  let wroteFile = false;
  let transactionStarted = false;
  let updated: StoredUser;
  try {
    if (kind === "photo") {
      if (!png) throw new Error("프로필 PNG가 필요합니다.");
      mkdirSync(directory, { recursive: true });
      wroteFile = true;
      writeFileSync(path, png, { mode: 0o600 });
    }
    db.exec("BEGIN");
    transactionStarted = true;
    const result = updateAvatar(db, user.id, kind);
    if (!result) throw new Error("프로필 계정이 없습니다.");
    if (result.avatar.version !== version) throw new Error("프로필 버전이 변경되었습니다.");
    db.exec("COMMIT");
    updated = result;
  } catch (error) {
    try {
      if (transactionStarted) db.exec("ROLLBACK");
    } finally {
      if (wroteFile) removeAvatarFile(path);
    }
    throw error;
  }
  removeAvatarFile(avatarPath(directory, user.handle, user.avatar.version));
  removeAvatarFile(join(directory, `${user.handle}.png`));
  return updated;
}
