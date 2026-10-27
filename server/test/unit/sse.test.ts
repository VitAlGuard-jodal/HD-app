import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ServerResponse } from "node:http";
import { test } from "node:test";
import { formatEvent, openEventStream, PING_INTERVAL_MS } from "../../src/sse.ts";

// 실제 소켓 대신 응답 이벤트와 버퍼만 재현한다.
class FakeResponse extends EventEmitter {
  statusCode = 0;
  headers: Record<string, string> = {};
  writes: string[] = [];
  flushed = false;
  destroyed = false;
  writableEnded = false;
  writeResult = true;
  throwOnWrite = false;

  writeHead(status: number, headers: Record<string, string>) {
    this.statusCode = status;
    this.headers = headers;
    return this;
  }

  flushHeaders() { this.flushed = true; }

  write(chunk: string): boolean {
    if (this.throwOnWrite) throw new Error("끊어진 연결");
    this.writes.push(chunk);
    return this.writeResult;
  }

  end() {
    this.writableEnded = true;
    this.emit("finish");
    this.emit("close");
    return this;
  }

  asResponse(): ServerResponse { return this as unknown as ServerResponse; }
}

test("SSE 이벤트는 이름과 한 줄 JSON, 빈 줄로 구성된다", () => {
  assert.equal(formatEvent("hello", { self: { handle: "alice", displayName: "앨리스" } }),
    'event: hello\ndata: {"self":{"handle":"alice","displayName":"앨리스"}}\n\n');
  assert.equal(formatEvent("signal", { payload: "한 줄\n다음 줄" }),
    'event: signal\ndata: {"payload":"한 줄\\n다음 줄"}\n\n');
});

test("SSE는 객체 외의 JSON 값도 그대로 인코딩한다", () => {
  for (const value of [null, false, 0, "문자열", [1, null]]) {
    assert.equal(formatEvent("signal", value), `event: signal\ndata: ${JSON.stringify(value)}\n\n`);
  }
});

test("SSE 이름의 줄바꿈과 JSON이 아닌 값은 거부한다", () => {
  assert.throws(() => formatEvent("signal\ndata: injected", {}), TypeError);
  assert.throws(() => formatEvent("hello\n", {}), TypeError);
  assert.throws(() => formatEvent("signal", undefined), TypeError);
});

test("SSE 연결은 헤더를 즉시 보내고 15초마다 주석 ping을 보낸다", (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const response = new FakeResponse();
  const stream = openEventStream(response.asResponse());
  t.after(() => stream.close());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.headers, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  assert.equal(response.flushed, true);
  assert.equal(PING_INTERVAL_MS, 15_000);
  t.mock.timers.tick(14_999);
  assert.deepEqual(response.writes, []);
  t.mock.timers.tick(1);
  assert.deepEqual(response.writes, [": ping\n\n"]);
  t.mock.timers.tick(15_000);
  assert.deepEqual(response.writes, [": ping\n\n", ": ping\n\n"]);
});

test("연결이 끊기면 구독 정리를 한 번 호출하고 ping을 중단한다", (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const response = new FakeResponse();
  let cleaned = 0;
  const stream = openEventStream(response.asResponse(), () => { cleaned += 1; });
  response.destroyed = true;
  response.emit("close");
  response.emit("close");
  t.mock.timers.tick(60_000);
  assert.equal(cleaned, 1);
  assert.deepEqual(response.writes, []);
  assert.equal(stream.send("signal", null), false);
  stream.close();
  assert.equal(cleaned, 1);
});

test("명시적인 스트림 종료는 응답과 타이머를 정리한다", (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const response = new FakeResponse();
  let cleaned = 0;
  const stream = openEventStream(response.asResponse(), () => { cleaned += 1; });
  assert.equal(stream.send("hello", { self: {} }), true);
  stream.close();
  stream.close();
  t.mock.timers.tick(30_000);
  assert.equal(response.writableEnded, true);
  assert.equal(cleaned, 1);
  assert.equal(response.writes.length, 1);
});

test("응답 버퍼의 역압은 미전달로 오인하지 않는다", (t) => {
  const response = new FakeResponse();
  response.writeResult = false;
  const stream = openEventStream(response.asResponse());
  t.after(() => stream.close());
  assert.equal(stream.send("signal", { payload: null }), true);
  assert.equal(response.writes.length, 1);
});

test("쓰기 예외는 연결을 정리하고 미전달로 처리한다", (t) => {
  const response = new FakeResponse();
  response.throwOnWrite = true;
  let cleaned = 0;
  const stream = openEventStream(response.asResponse(), () => { cleaned += 1; });
  t.after(() => stream.close());
  assert.equal(stream.send("signal", null), false);
  assert.equal(response.writableEnded, true);
  assert.equal(cleaned, 1);
});

test("응답 오류 이벤트도 연결과 ping을 정리한다", (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const response = new FakeResponse();
  let cleaned = 0;
  openEventStream(response.asResponse(), () => { cleaned += 1; });
  response.emit("error", new Error("응답 오류"));
  t.mock.timers.tick(15_000);
  assert.equal(response.writableEnded, true);
  assert.equal(cleaned, 1);
  assert.deepEqual(response.writes, []);
});
