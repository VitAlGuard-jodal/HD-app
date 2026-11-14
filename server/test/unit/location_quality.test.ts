import assert from "node:assert/strict";
import { test } from "node:test";
import type { LocationFix } from "../../src/locations.ts";
import { context, stopped } from "../../src/location_quality.ts";

function fixes(times = [10_000, 15_000, 20_000]): LocationFix[] {
  return times.map((at, seq) => ({ handle: "self", stream: "1".repeat(16), seq, at, receivedAt: at + 200,
    lat: 37.5, lng: 127, acc: 2, speed: 0 }));
}
test("r10: only the newest parked fix must be fresh; moving context remains all-fresh", () => {
  const samples = fixes();
  for (const now of [20_200, 25_199, 30_000]) {
    assert.equal(stopped(samples, now), true);
    assert.equal(context(samples, now), false);
  }
  assert.equal(stopped(samples, 30_001), false);
  assert.equal(context(fixes([18_000, 19_000, 20_000]), 20_200), true);
});
test("r10: stop evidence accepts a 15 s window but never an unbounded history", () => {
  assert.equal(stopped(fixes([5000, 12_500, 20_000]), 20_200), true);
  assert.equal(stopped(fixes([4999, 12_500, 20_000]), 20_200), false);
});
for (const [name, change] of [
  ["missing sample", (s: LocationFix[]) => { s.shift(); }],
  ["duplicate sequence", (s: LocationFix[]) => { s[1].seq = s[0].seq; }],
  ["sequence gap", (s: LocationFix[]) => { s[2].seq++; }],
  ["different stream", (s: LocationFix[]) => { s[2].stream = "2".repeat(16); }],
  ["reversed measurement", (s: LocationFix[]) => { s[1].at = s[0].at; }],
  ["gap over 10 s", (s: LocationFix[]) => { s[0].at = s[1].at - 10_001; s[0].receivedAt = s[0].at + 200; }],
  ["future measurement", (s: LocationFix[]) => { s[2].at = s[2].receivedAt + 1; }],
  ["delayed old measurement", (s: LocationFix[]) => { s[0].at -= 10_001; }],
  ["compressed receipt span", (s: LocationFix[]) => { s[0].receivedAt = 19_000; s[1].receivedAt = 19_500; }],
  ["reversed receipt", (s: LocationFix[]) => { s[0].receivedAt = 16_000; }],
  ["receipt window over 15 s", (s: LocationFix[]) => { s[2].receivedAt = 25_201; }],
  ["poor accuracy", (s: LocationFix[]) => { s[1].acc = 26; }],
  ["phone without accuracy", (s: LocationFix[]) => { s[1].acc = undefined; }],
  ["speed at 2 m/s", (s: LocationFix[]) => { s[2].speed = 2; }],
  ["negative speed", (s: LocationFix[]) => { s[2].speed = -1; }],
  ["non-finite speed", (s: LocationFix[]) => { s[2].speed = NaN; }],
  ["displacement despite zero speed", (s: LocationFix[]) => { s[2].lat += 3.1 / 111195; }],
  ["excursion then return", (s: LocationFix[]) => { s[1].lat += 3.1 / 111195; }],
] as const) test(`r10: stop evidence rejects ${name}`, () => {
  const samples = fixes(); change(samples);
  assert.equal(stopped(samples, Math.max(20_200, samples.at(-1)!.receivedAt)), false);
});
test("r10: unknown speed still needs stationary fixes and vehicle accuracy fallback stays explicit", () => {
  const samples = fixes();
  for (const s of samples) { s.speed = undefined; s.acc = undefined; s.src = "vehicle"; }
  assert.equal(stopped(samples, 20_200), true);
  samples[1].lat += 3.1 / 111195;
  assert.equal(stopped(samples, 20_200), false);
});
