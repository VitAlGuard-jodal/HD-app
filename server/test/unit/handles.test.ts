import assert from "node:assert/strict";
import { test } from "node:test";
import { isValidDisplayName, isValidHandle, isValidPassword } from "../../src/handles.ts";

test("아이디는 허용 문자와 3~20자 경계를 지킨다", () => {
  for (const value of ["abc", "a_0", "123", "a".repeat(20)]) assert.equal(isValidHandle(value), true);
  for (const value of ["", "ab", "a".repeat(21), "Alice", "한글아이디", "ab-c", " abc", "abc ", "abc\n", "a.b"]) {
    assert.equal(isValidHandle(value), false, JSON.stringify(value));
  }
});

test("아이디 검증은 문자열 이외의 값을 거부한다", () => {
  for (const value of [null, undefined, 123, {}, [], true]) assert.equal(isValidHandle(value), false);
});

test("표시 이름은 앞뒤 공백을 제거한 2~20자다", () => {
  for (const value of ["모두", "  모두모아  ", "가".repeat(20), "🚗🚙"]) assert.equal(isValidDisplayName(value), true);
  for (const value of ["", "   ", " 가 ", "가".repeat(21), "🚗".repeat(21), null, 20]) {
    assert.equal(isValidDisplayName(value), false);
  }
});

test("비밀번호는 공백을 보존하며 8~72자다", () => {
  for (const value of ["a".repeat(8), "a".repeat(72), "  abcdef", "🚗".repeat(8)]) {
    assert.equal(isValidPassword(value), true);
  }
  for (const value of ["a".repeat(7), "a".repeat(73), "🚗".repeat(73), null, 12345678]) {
    assert.equal(isValidPassword(value), false);
  }
});
