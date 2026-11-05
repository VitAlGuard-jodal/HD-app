import assert from "node:assert/strict";
import { test } from "node:test";
import { RoomEventHub, SIGNAL_BACKLOG_LIMIT, SIGNAL_BACKLOG_TTL_MS } from "../../src/rooms.ts";

test("시그널은 저장한 순서대로 재전송하며 재구독해도 보관한다", () => {
  const hub = new RoomEventHub();
  const signals = [
    { from: "alice", kind: "offer", payload: { sdp: "offer-sdp" } },
    { from: "alice", kind: "ice", payload: { candidate: "candidate" } },
    { from: "alice", kind: "custom", payload: null },
  ];
  for (const [index, signal] of signals.entries()) hub.queueSignal("ABC234", "bob", "signal", signal, 1000 + index);
  const received: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (name, data) => { received.push([name, data]); }, 2000), 3);
  assert.deepEqual(received, signals.map((signal) => ["signal", signal]));
  const replayed: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (name, data) => {
    replayed.push([name, data]);
    return true;
  }, 2000), 3);
  assert.deepEqual(replayed, received);
});

test("시그널은 60초까지 유효하고 TTL을 초과하면 재전송하지 않는다", () => {
  const hub = new RoomEventHub();
  assert.equal(SIGNAL_BACKLOG_TTL_MS, 60_000);
  hub.queueSignal("ABC234", "bob", "signal", "오래된 시그널", 1000);
  hub.queueSignal("ABC234", "bob", "signal", "새 시그널", 1001);
  const received: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => { received.push(data); }, 1000 + SIGNAL_BACKLOG_TTL_MS), 2);
  assert.deepEqual(received, ["오래된 시그널", "새 시그널"]);
  const remaining: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => { remaining.push(data); }, 1001 + SIGNAL_BACKLOG_TTL_MS), 1);
  assert.deepEqual(remaining, ["새 시그널"]);
  assert.equal(hub.replaySignals("ABC234", "bob", () => assert.fail("만료된 시그널은 보내면 안 됩니다."), 1002 + SIGNAL_BACKLOG_TTL_MS), 0);
});

test("시그널을 추가할 때도 만료된 항목을 제거한다", () => {
  const hub = new RoomEventHub();
  hub.queueSignal("ABC234", "bob", "signal", "만료", 0);
  hub.queueSignal("ABC234", "bob", "signal", "유효", SIGNAL_BACKLOG_TTL_MS + 1);
  const received: unknown[] = [];
  // 재전송 시각을 되돌려도 추가할 때 제거한 항목이 되살아나지 않는다.
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => { received.push(data); }, SIGNAL_BACKLOG_TTL_MS), 1);
  assert.deepEqual(received, ["유효"]);
});

test("수신자별 64개를 넘으면 가장 오래된 시그널부터 버린다", () => {
  const hub = new RoomEventHub();
  assert.equal(SIGNAL_BACKLOG_LIMIT, 64);
  hub.queueSignal("ABC234", "alice", "signal", "다른 수신자", 0);
  for (let index = 0; index < SIGNAL_BACKLOG_LIMIT + 3; index += 1) {
    hub.queueSignal("ABC234", "bob", "signal", index, index);
  }
  const received: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => { received.push(data); }, 1000), SIGNAL_BACKLOG_LIMIT);
  assert.deepEqual(received, Array.from({ length: SIGNAL_BACKLOG_LIMIT }, (_, index) => index + 3));
  assert.equal(hub.replaySignals("ABC234", "alice", (_name, data) => { assert.equal(data, "다른 수신자"); }, 1000), 1);
});

test("재전송 실패 시 즉시 중단하고 성공한 개수만 반환하며 항목은 보관한다", () => {
  const hub = new RoomEventHub();
  for (const data of [1, 2, 3]) hub.queueSignal("ABC234", "bob", "signal", data, 1000);
  const attempted: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => {
    attempted.push(data);
    return data !== 2;
  }, 1000), 1);
  assert.deepEqual(attempted, [1, 2]);
  const replayed: unknown[] = [];
  assert.equal(hub.replaySignals("ABC234", "bob", (_name, data) => { replayed.push(data); }, 1000), 3);
  assert.deepEqual(replayed, [1, 2, 3]);
  let attemptedCount = 0;
  assert.equal(hub.replaySignals("ABC234", "bob", () => {
    attemptedCount += 1;
    return false;
  }, 1000), 0);
  assert.equal(attemptedCount, 1);
});

test("백로그 삭제는 지정한 수신자 또는 방에만 적용된다", () => {
  const hub = new RoomEventHub();
  hub.queueSignal("ABC234", "alice", "signal", "앨리스", 1000);
  hub.queueSignal("ABC234", "bob", "signal", "보비", 1000);
  hub.queueSignal("DEF567", "bob", "signal", "다른 방", 1000);
  hub.clearSignals("ABC234", "bob");
  hub.clearSignals("ABC234", "bob");
  assert.equal(hub.replaySignals("ABC234", "bob", () => assert.fail("삭제된 수신자에게 보내면 안 됩니다."), 1000), 0);
  assert.equal(hub.replaySignals("ABC234", "alice", (_name, data) => { assert.equal(data, "앨리스"); }, 1000), 1);
  assert.equal(hub.replaySignals("DEF567", "bob", (_name, data) => { assert.equal(data, "다른 방"); }, 1000), 1);
  hub.clearSignals("ABC234");
  hub.clearSignals("ABC234");
  assert.equal(hub.replaySignals("ABC234", "alice", () => assert.fail("삭제된 방에는 보내면 안 됩니다."), 1000), 0);
  assert.equal(hub.replaySignals("DEF567", "bob", (_name, data) => { assert.equal(data, "다른 방"); }, 1000), 1);
});

test("종료 시 모든 방의 시그널 백로그를 비운다", () => {
  const hub = new RoomEventHub();
  hub.queueSignal("ABC234", "alice", "signal", null, 1000);
  hub.queueSignal("ABC234", "bob", "signal", null, 1000);
  hub.queueSignal("DEF567", "bob", "signal", null, 1000);
  hub.close();
  hub.close();
  for (const [code, handle] of [["ABC234", "alice"], ["ABC234", "bob"], ["DEF567", "bob"]]) {
    assert.equal(hub.replaySignals(code, handle, () => assert.fail("종료 후에는 재전송하면 안 됩니다."), 1000), 0);
  }
});
