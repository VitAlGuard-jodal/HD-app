import { createHash, randomBytes, scrypt, timingSafeEqual } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import { findTokenUser, revokeTokenHash, saveToken } from "./store.ts";
import type { StoredUser } from "./store.ts";

export const TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const HASH_PREFIX = "scrypt$16384$8$1";

function deriveKey(password: string, salt: Uint8Array): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, 64, { N: 16384, r: 8, p: 1 }, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await deriveKey(password, salt);
  return `${HASH_PREFIX}$${salt.toString("hex")}$${key.toString("hex")}`;
}

export async function verifyPassword(password: string, passwordHash: string): Promise<boolean> {
  const parts = passwordHash.split("$");
  if (parts.length !== 6 || parts.slice(0, 4).join("$") !== HASH_PREFIX) return false;
  const saltHex = parts[4];
  const keyHex = parts[5];
  // 저장된 값이 손상되어도 임의의 비용 인자나 잘못된 길이로 scrypt를 실행하지 않는다.
  if (saltHex.length !== 32 || !/^[0-9a-f]+$/.test(saltHex)
    || keyHex.length !== 128 || !/^[0-9a-f]+$/.test(keyHex)) return false;
  const actual = await deriveKey(password, Buffer.from(saltHex, "hex"));
  return timingSafeEqual(actual, Buffer.from(keyHex, "hex"));
}

export function tokenHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function issueToken(db: DatabaseSync, userId: number, now = new Date()): string {
  const token = randomBytes(32).toString("base64url");
  saveToken(db, tokenHash(token), userId, new Date(now.getTime() + TOKEN_TTL_MS).toISOString());
  return token;
}

export function lookupToken(db: DatabaseSync, token: string, now = new Date()): StoredUser | undefined {
  if (typeof token !== "string" || token.length !== 43 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    return undefined;
  }
  return findTokenUser(db, tokenHash(token), now.toISOString());
}

export function revokeToken(db: DatabaseSync, token: string): void {
  revokeTokenHash(db, tokenHash(token));
}
