import assert from "node:assert/strict";
import { test } from "node:test";
import { performance } from "node:perf_hooks";
import { createApp } from "../../src/app.ts";
import { issueToken, tokenHash } from "../../src/auth.ts";
import { createUser, joinRoom, updateUserConsent } from "../../src/store.ts";
import { dispatch } from "../helpers/route_fixture.ts";
import { at, pin, planFixture } from "../helpers/plan_fixture.ts";

test("r11 B6: eight 1 Hz vehicles plus sweeps and snapshots leave at least 90% of the interval free", async (t) => {
  const f = planFixture(t); f.plans.close();
  t.mock.timers.enable({ apis: ["setInterval"] });
  const handles = ["leader", "follower", "third"];
  for (let i = 0; i < 5; i++) {
    const handle = `extra_${i}`;
    const user = createUser(f.db, { handle, displayName: handle, passwordHash: "unused" })!;
    joinRoom(f.db, f.room.id, user.id);
    updateUserConsent(f.db, user.id, { privacyVersion: "6", locationVersion: "6" });
    const token = issueToken(f.db, user.id); f.tokens.set(handle, token);
    f.hub.claim(f.room.code, handle, tokenHash(token), tokenHash(token));
    handles.push(handle);
  }
  const ids = handles.slice(1).map((handle) => f.locations.requestFollow(f.room.code, handle, "leader").requestId);
  f.rest(Object.fromEntries(handles.map((h) => [h, 0])));
  const app = createApp({ ...f, routeOptions: f.routeOptions });
  const api = (handle: string, path: string, body?: unknown, method = "POST") =>
    dispatch(app, f.tokens.get(handle)!, body, { path: `/v1/rooms/${f.room.code}/${path}`, method }).done;
  const saved = await api("leader", "follow-plans/self", { operationId: "load-plan", expectedPlanId: null, expectedRevision: 0,
    destination: pin(2000), joinPoint: pin(1000), policy: "wait", participantFollowRequestIds: ids, waitingPlaceConfirmed: true }, "PUT");
  assert.equal(saved.statusCode, 200);
  for (const [index, handle] of handles.slice(1).entries()) {
    assert.equal((await api(handle, "follow-plans/leader/participation", { operationId: `enroll-${handle}`,
      planId: saved.json().plan.planId, planRevision: 1, followRequestId: ids[index], enabled: true }, "PUT")).statusCode, 200);
  }
  let queries = 0;
  const prepare = f.db.prepare.bind(f.db);
  t.mock.method(f.db, "prepare", (...args: Parameters<typeof prepare>) => { queries++; return prepare(...args); });
  let maxTurnMs = 0;
  for (let second = 0; second < 10; second++) {
    const start = performance.now();
    f.elapse(1000);
    for (const handle of handles) f.publish(handle, { ...at(0), speed: 0 });
    t.mock.timers.tick(1000);
    const snapshot = await api("follower", "positions", undefined, "GET");
    assert.equal(snapshot.json().followPlans[0].runtime.enrollments.length, 7);
    await new Promise<void>((resolve) => setImmediate(resolve));
    maxTurnMs = Math.max(maxTurnMs, performance.now() - start);
  }
  t.diagnostic(`8 vehicles / 1 Hz: ${queries / 10} SQL prepares per interval, max event-loop turn ${maxTurnMs.toFixed(2)} ms`);
  assert.ok(maxTurnMs < 100, `8-car processing occupied ${maxTurnMs.toFixed(2)} ms of the 1000 ms interval`);
});
