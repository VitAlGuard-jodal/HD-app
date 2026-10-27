import assert from "node:assert/strict";
import { test } from "node:test";
import { generateRoomCode, RoomEventHub } from "../../src/rooms.ts";

test("방 코드는 혼동 문자를 제외한 대문자 영숫자 6자다", () => {
  const codes = Array.from({ length: 128 }, generateRoomCode);
  for (const code of codes) assert.match(code, /^[A-HJ-NP-Z2-9]{6}$/);
  assert.ok(new Set(codes).size > 1);
});

test("브로드캐스트는 해당 방의 모든 연결에만 전달된다", () => {
  const hub = new RoomEventHub();
  const received: unknown[] = [];
  hub.subscribe("ABC234", "alice", (name, data) => { received.push(["alice", name, data]); });
  hub.subscribe("ABC234", "bob", (name, data) => { received.push(["bob", name, data]); });
  hub.subscribe("DEF567", "alice", () => assert.fail("다른 방에 전달하면 안 됩니다."));
  assert.equal(hub.broadcast("ABC234", "member-joined", { handle: "charlie" }), 2);
  assert.deepEqual(received, [
    ["alice", "member-joined", { handle: "charlie" }],
    ["bob", "member-joined", { handle: "charlie" }],
  ]);
});

test("지정 수신자의 여러 연결에 시그널을 모두 전달한다", () => {
  const hub = new RoomEventHub();
  const received: unknown[] = [];
  const payload = { from: "alice", kind: "custom", payload: [null, true, "안녕"] };
  hub.subscribe("ABC234", "alice", () => assert.fail("다른 수신자에게 전달하면 안 됩니다."));
  hub.subscribe("ABC234", "bob", (name, data) => { received.push([name, data]); });
  hub.subscribe("ABC234", "bob", (name, data) => { received.push([name, data]); });
  hub.subscribe("DEF567", "bob", () => assert.fail("다른 방에 전달하면 안 됩니다."));
  assert.equal(hub.sendTo("ABC234", "bob", "signal", payload), true);
  assert.deepEqual(received, [["signal", payload], ["signal", payload]]);
  assert.equal(hub.subscriberCount("ABC234"), 3);
});

test("연결하지 않은 수신자는 미전달로 처리한다", () => {
  const hub = new RoomEventHub();
  assert.equal(hub.sendTo("ABC234", "bob", "signal", null), false);
  hub.subscribe("ABC234", "alice", () => {});
  assert.equal(hub.sendTo("ABC234", "bob", "signal", null), false);
  assert.equal(hub.broadcast("DEF567", "member-left", { handle: "bob" }), 0);
});

test("구독 해제는 멱등이며 같은 사용자의 다른 연결은 유지한다", () => {
  const hub = new RoomEventHub();
  const events: unknown[] = [];
  hub.on("subscribed", (event) => events.push(["subscribed", event]));
  hub.on("unsubscribed", (event) => events.push(["unsubscribed", event]));
  const first = hub.subscribe("ABC234", "bob", () => {});
  const second = hub.subscribe("ABC234", "bob", () => {});
  first();
  first();
  assert.equal(hub.subscriberCount("ABC234"), 1);
  assert.equal(hub.sendTo("ABC234", "bob", "signal", null), true);
  second();
  assert.equal(hub.subscriberCount("ABC234"), 0);
  assert.deepEqual(events.map((event) => (event as unknown[])[0]), ["subscribed", "subscribed", "unsubscribed", "unsubscribed"]);
});

test("실패한 연결을 정리하면서 정상 연결에는 계속 전달한다", () => {
  const hub = new RoomEventHub();
  let closed = 0;
  let delivered = 0;
  hub.subscribe("ABC234", "bob", () => false, () => { closed += 1; });
  hub.subscribe("ABC234", "bob", () => { throw new Error("끊어진 연결"); }, () => { closed += 1; });
  hub.subscribe("ABC234", "bob", () => { delivered += 1; });
  assert.equal(hub.sendTo("ABC234", "bob", "signal", null), true);
  assert.equal(closed, 2);
  assert.equal(delivered, 1);
  assert.equal(hub.subscriberCount("ABC234"), 1);
});

test("모든 연결이 실패하면 미전달로 응답한다", () => {
  const hub = new RoomEventHub();
  hub.subscribe("ABC234", "bob", () => false);
  hub.subscribe("ABC234", "bob", () => { throw new Error("끊어진 연결"); });
  assert.equal(hub.sendTo("ABC234", "bob", "signal", null), false);
  assert.equal(hub.subscriberCount("ABC234"), 0);
});

test("명시적인 나가기는 해당 방의 해당 사용자 연결만 닫는다", () => {
  const hub = new RoomEventHub();
  let closed = 0;
  const first = hub.subscribe("ABC234", "bob", () => {}, () => { closed += 1; });
  hub.subscribe("ABC234", "bob", () => {}, () => { closed += 1; });
  hub.subscribe("ABC234", "alice", () => {}, () => assert.fail("다른 참여자는 유지해야 합니다."));
  hub.subscribe("DEF567", "bob", () => {}, () => assert.fail("다른 방은 유지해야 합니다."));
  hub.disconnectUser("ABC234", "bob");
  first();
  hub.disconnectUser("ABC234", "bob");
  assert.equal(closed, 2);
  assert.equal(hub.subscriberCount("ABC234"), 1);
  assert.equal(hub.subscriberCount("DEF567"), 1);
});

test("종료 시 모든 방의 연결을 정리하며 정리 오류도 격리한다", () => {
  const hub = new RoomEventHub();
  let closed = 0;
  hub.subscribe("ABC234", "alice", () => {}, () => { closed += 1; throw new Error("정리 오류"); });
  hub.subscribe("DEF567", "bob", () => {}, () => { closed += 1; });
  hub.close();
  hub.close();
  assert.equal(closed, 2);
  assert.equal(hub.subscriberCount("ABC234"), 0);
  assert.equal(hub.subscriberCount("DEF567"), 0);
});
