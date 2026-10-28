import assert from "node:assert/strict";
import { createHash, scryptSync } from "node:crypto";
import { test } from "node:test";
import { hashPassword, issueToken, lookupToken, revokeToken, tokenHash, TOKEN_TTL_MS, verifyPassword } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { createUser, findTokenUser } from "../../src/store.ts";

test("비밀번호 해시는 지정된 scrypt 인자, 16바이트 솔트, 64바이트 키를 쓴다", async () => {
  const password = "비밀번호 123";
  const hash = await hashPassword(password);
  const match = /^scrypt\$16384\$8\$1\$([0-9a-f]{32})\$([0-9a-f]{128})$/.exec(hash);
  assert.ok(match);
  const expected = scryptSync(password, Buffer.from(match[1], "hex"), 64, { N: 16384, r: 8, p: 1 });
  assert.equal(match[2], expected.toString("hex"));
  assert.equal(await verifyPassword(password, hash), true);
  assert.equal(await verifyPassword("다른 비밀번호", hash), false);
});

test("동일한 비밀번호도 무작위 솔트로 서로 다른 해시가 된다", async () => {
  const [first, second] = await Promise.all([hashPassword("password123"), hashPassword("password123")]);
  assert.notEqual(first, second);
  assert.equal(await verifyPassword("password123", first), true);
  assert.equal(await verifyPassword("password123", second), true);
});

test("비밀번호의 앞뒤 공백과 유니코드를 그대로 검증한다", async () => {
  const password = "  🚗한글비밀번호  ";
  const hash = await hashPassword(password);
  assert.equal(await verifyPassword(password, hash), true);
  assert.equal(await verifyPassword(password.trim(), hash), false);
});

test("손상되거나 비용 인자가 바뀐 해시는 안전하게 거부한다", async () => {
  const valid = await hashPassword("password123");
  for (const invalid of ["", "plain-text", valid.replace("16384", "32768"), valid.slice(0, -1), `${valid}\n`, `${valid}$extra`, valid.replace(/\$[0-9a-f]{32}\$/, "$zz$")]) {
    assert.equal(await verifyPassword("password123", invalid), false);
  }
});

test("토큰은 32바이트 base64url이며 원문 대신 SHA-256으로 조회된다", (t) => {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const user = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "hash" })!;
  const now = new Date("2026-01-01T00:00:00.000Z");
  const token = issueToken(db, user.id, now);
  assert.match(token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(Buffer.from(token, "base64url").length, 32);
  assert.equal(lookupToken(db, token, now)?.handle, "alice");
  const digest = createHash("sha256").update(token).digest("hex");
  assert.equal(tokenHash(token), digest);
  assert.equal(findTokenUser(db, digest, now.toISOString())?.id, user.id);
  assert.equal(findTokenUser(db, token, now.toISOString()), undefined);
});

test("토큰은 정확히 30일째 만료된다", (t) => {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const user = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "hash" })!;
  const now = new Date("2026-01-01T00:00:00.000Z");
  const token = issueToken(db, user.id, now);
  assert.equal(TOKEN_TTL_MS, 2_592_000_000);
  assert.ok(lookupToken(db, token, new Date(now.getTime() + TOKEN_TTL_MS - 1)));
  assert.equal(lookupToken(db, token, new Date(now.getTime() + TOKEN_TTL_MS)), undefined);
});

test("로그아웃은 해당 토큰만 폐기하고 다른 로그인은 유지한다", (t) => {
  const db = openDb(":memory:");
  t.after(() => db.close());
  const user = createUser(db, { handle: "alice", displayName: "앨리스", passwordHash: "hash" })!;
  const first = issueToken(db, user.id);
  const second = issueToken(db, user.id);
  assert.notEqual(first, second);
  revokeToken(db, first);
  revokeToken(db, first);
  assert.equal(lookupToken(db, first), undefined);
  assert.ok(lookupToken(db, second));
});

test("알 수 없거나 잘못된 모양의 토큰은 인증되지 않는다", (t) => {
  const db = openDb(":memory:");
  t.after(() => db.close());
  for (const token of ["", "short", "a".repeat(43), "a".repeat(44), `${"a".repeat(42)}\n`, "!".repeat(43)]) {
    assert.equal(lookupToken(db, token), undefined);
  }
});
