import { createServer } from "node:http";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createApp } from "./app.ts";
import { openDb } from "./db.ts";
import { RoomEventHub } from "./rooms.ts";

export function resolveDbPath(env: string | undefined): string {
  // 빈 값이나 미설정이면 데이터를 보존하는 기본 파일 DB를 사용한다.
  return env || fileURLToPath(new URL("../data/hdapp.sqlite", import.meta.url));
}

function main(): void {
  const portText = process.env.PORT ?? "8787";
  if (!/^\d+$/.test(portText) || Number(portText) > 65535) {
    throw new Error("PORT는 0~65535 사이의 정수여야 합니다.");
  }

  const db = openDb(resolveDbPath(process.env.HDAPP_DB));
  const hub = new RoomEventHub();
  const server = createServer(createApp({ db, hub }));
  let stopping = false;
  let dbClosed = false;

  function closeDb(): void {
    if (dbClosed) return;
    dbClosed = true;
    db.close();
  }

  function shutdown(): void {
    if (stopping) return;
    stopping = true;
    hub.close();
    // SSE와 유휴 연결을 먼저 닫고, 처리 중인 요청에는 최대 5초를 준다.
    const forceClose = setTimeout(() => server.closeAllConnections(), 5000);
    forceClose.unref();
    server.close(() => {
      clearTimeout(forceClose);
      closeDb();
    });
    server.closeIdleConnections();
  }

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  server.on("error", (error: Error & { code?: string }) => {
    hub.close();
    closeDb();
    process.stderr.write(`서버를 시작할 수 없습니다. code=${error.code ?? "UNKNOWN"} port=${portText}\n`);
    process.exitCode = 1;
  });
  server.listen(Number(portText));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
