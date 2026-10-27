import type { ServerResponse } from "node:http";

export const PING_INTERVAL_MS = 15_000;

export function formatEvent(name: string, data: unknown): string {
  if (!/^[a-z][a-z-]*$/.test(name) || name.includes("\n")) {
    throw new TypeError("올바르지 않은 SSE 이벤트 이름입니다.");
  }
  const json = JSON.stringify(data);
  if (json === undefined) throw new TypeError("SSE 데이터는 JSON 값이어야 합니다.");
  return `event: ${name}\ndata: ${json}\n\n`;
}

export function openEventStream(response: ServerResponse, onClose: () => void = () => {}) {
  response.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  response.flushHeaders();
  let closed = false;
  const pingTimer = setInterval(() => write(": ping\n\n"), PING_INTERVAL_MS);
  pingTimer.unref?.();

  function cleanup(): void {
    if (closed) return;
    closed = true;
    clearInterval(pingTimer);
    response.off("close", cleanup);
    response.off("error", close);
    onClose();
  }

  function close(): void {
    cleanup();
    if (!response.destroyed && !response.writableEnded) response.end();
  }

  function write(value: string): boolean {
    if (closed || response.destroyed || response.writableEnded) {
      cleanup();
      return false;
    }
    try {
      // write()의 false는 버퍼에 들어갔다는 뜻이므로 미전달로 처리하지 않는다.
      response.write(value);
      return true;
    } catch {
      close();
      return false;
    }
  }

  response.once("close", cleanup);
  response.once("error", close);
  return { send: (name: string, data: unknown) => write(formatEvent(name, data)), close };
}
