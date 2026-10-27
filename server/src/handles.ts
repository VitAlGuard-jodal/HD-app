export function isValidHandle(value: unknown): value is string {
  return typeof value === "string"
    && value === value.trim()
    && /^[a-z0-9_]{3,20}$/.test(value);
}

export function isValidDisplayName(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const length = Array.from(value.trim()).length;
  return length >= 2 && length <= 20;
}

export function isValidPassword(value: unknown): value is string {
  if (typeof value !== "string") return false;
  // 비밀번호의 공백도 원문에 포함하고, 글자 수는 유니코드 코드 포인트로 센다.
  const length = Array.from(value).length;
  return length >= 8 && length <= 72;
}
