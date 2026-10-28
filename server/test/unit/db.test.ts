import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { openDb } from "../../src/db.ts";
import { resolveDbPath } from "../../src/main.ts";

test("resolveDbPath는 빈 HDAPP_DB에 기본 파일 경로를 사용한다", () => {
  assert.equal(resolveDbPath(""), fileURLToPath(new URL("../../data/hdapp.sqlite", import.meta.url)));
});

test("resolveDbPath는 미설정 HDAPP_DB에 기본 파일 경로를 사용한다", () => {
  assert.equal(resolveDbPath(undefined), fileURLToPath(new URL("../../data/hdapp.sqlite", import.meta.url)));
});

test("resolveDbPath는 HDAPP_DB에 지정한 절대경로를 유지한다", () => {
  const path = fileURLToPath(new URL("../../data/custom.sqlite", import.meta.url));
  assert.equal(resolveDbPath(path), path);
});

test("openDb는 없는 상위 폴더를 재귀적으로 만든다", () => {
  // 임시 DB도 서버 폴더 안에 만들고 검증 뒤 함께 지운다.
  const directory = mkdtempSync(fileURLToPath(new URL("../../data/db-test-", import.meta.url)));
  const parent = join(directory, "missing", "nested");
  const path = join(parent, "hdapp.sqlite");
  let db: ReturnType<typeof openDb> | undefined;
  try {
    assert.equal(existsSync(parent), false);
    db = openDb(path);
    assert.equal(statSync(parent).isDirectory(), true);
    assert.equal(statSync(path).isFile(), true);
  } finally {
    db?.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
