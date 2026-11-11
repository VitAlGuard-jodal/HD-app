import type { IncomingMessage, RequestListener, ServerResponse } from "node:http";
import type { DatabaseSync } from "node:sqlite";
import { hashPassword, issueToken, lookupToken, revokeToken, tokenHash, verifyPassword } from "./auth.ts";
import { isValidDisplayName, isValidHandle, isValidPassword } from "./handles.ts";
import { RoomLocationStore } from "./locations.ts";
import { generateRoomCode, RoomEventHub } from "./rooms.ts";
import { openEventStream } from "./sse.ts";
import { issueIceServers } from "./turn.ts";
import {
  addContact, createRoom, createUser, deleteContact, deleteEmptyRoom, findCurrentRoom, findRoomByCode, findUserByHandle,
  isRoomMember, joinRoom, leaveRoom, listContacts, listRoomMembers, publicRoom, publicRoomDetails, publicUser,
  updateDisplayName,
} from "./store.ts";
import type { StoredRoom, StoredUser } from "./store.ts";

const MAX_BODY_BYTES = 64 * 1024;
const SIGNAL_KINDS = new Set(["offer", "answer", "ice", "custom"]);

class HttpError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function invalid(message: string): never {
  throw new HttpError(400, "INVALID_INPUT", message);
}

function json(response: ServerResponse, status: number, body?: unknown): void {
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.end(status === 204 ? undefined : JSON.stringify(body));
}

function readBody(request: IncomingMessage): Promise<Buffer> {
  if (Number(request.headers["content-length"]) > MAX_BODY_BYTES) {
    request.resume();
    return Promise.reject(new HttpError(413, "BODY_TOO_LARGE", "본문은 64KB 이하여야 합니다."));
  }
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let length = 0;

    function cleanup(): void {
      request.off("data", onData);
      request.off("end", onEnd);
      request.off("error", onError);
      request.off("aborted", onAborted);
    }

    function fail(error: Error): void {
      cleanup();
      reject(error);
    }

    function onData(chunk: Buffer): void {
      length += chunk.length;
      if (length > MAX_BODY_BYTES) {
        fail(new HttpError(413, "BODY_TOO_LARGE", "본문은 64KB 이하여야 합니다."));
        // 소켓을 파괴하지 않고 남은 본문을 버려 413 응답을 전달한다.
        request.resume();
        return;
      }
      chunks.push(chunk);
    }

    function onEnd(): void {
      cleanup();
      resolve(Buffer.concat(chunks, length));
    }

    function onError(): void {
      fail(new HttpError(400, "INVALID_BODY", "본문을 읽을 수 없습니다."));
    }

    function onAborted(): void {
      fail(new HttpError(400, "INVALID_BODY", "요청이 중단되었습니다."));
    }

    request.on("data", onData);
    request.once("end", onEnd);
    request.once("error", onError);
    request.once("aborted", onAborted);
  });
}

async function readJson(request: IncomingMessage, allowEmpty = false): Promise<Record<string, unknown>> {
  const raw = await readBody(request);
  if (raw.length === 0 && allowEmpty) return {};
  if (!/^application\/json\s*(?:;|$)/i.test(request.headers["content-type"] ?? "")) {
    throw new HttpError(415, "UNSUPPORTED_MEDIA_TYPE", "Content-Type은 application/json이어야 합니다.");
  }
  let value: unknown;
  try {
    // 잘못된 UTF-8을 대체 문자로 저장하지 않고 입력 오류로 돌려준다.
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    invalid("올바른 JSON 본문이 필요합니다.");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid("본문은 JSON 객체여야 합니다.");
  }
  return value as Record<string, unknown>;
}

function pathValue(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    invalid("경로 인코딩이 올바르지 않습니다.");
  }
}

// 로그에 요청자 아이디만 남긴다(토큰·본문·헤더는 남기지 않는다).
const actors = new WeakMap<ServerResponse, string>();

function authenticate(db: DatabaseSync, request: IncomingMessage): { user: StoredUser; token: string } {
  const match = /^Bearer +([^\s]+)$/i.exec(request.headers.authorization ?? "");
  const token = match?.[1];
  const user = token ? lookupToken(db, token) : undefined;
  if (!user || !token) throw new HttpError(401, "UNAUTHORIZED", "유효한 인증 토큰이 필요합니다.");
  return { user, token };
}

function requireMember(db: DatabaseSync, room: StoredRoom, user: StoredUser): void {
  if (!isRoomMember(db, room.id, user.id)) {
    throw new HttpError(403, "NOT_ROOM_MEMBER", "방 참여자만 사용할 수 있습니다.");
  }
}

export function createApp({ db, hub = new RoomEventHub(), locations = new RoomLocationStore() }: {
  db: DatabaseSync; hub?: RoomEventHub; locations?: RoomLocationStore;
}): RequestListener {
  const locationCounts = new Map<string, { accepted: number; dropped: number; rate: number }>();
  let locationLogTimer: ReturnType<typeof setTimeout> | undefined;
  function countLocation(code: string, outcome: "accepted" | "dropped" | "rate"): void {
    const counts = locationCounts.get(code) ?? { accepted: 0, dropped: 0, rate: 0 };
    counts[outcome] += 1;
    locationCounts.set(code, counts);
    locationLogTimer ??= setTimeout(() => {
      for (const [roomCode, totals] of locationCounts) {
        process.stdout.write(`location: code=${roomCode} accepted=${totals.accepted} dropped=${totals.dropped} rate=${totals.rate}\n`);
      }
      locationCounts.clear();
      locationLogTimer = undefined;
    }, 60_000).unref();
  }

  function announceTrails(code: string): void {
    hub.broadcast(code, "trails", { trails: locations.snapshot(code).trails });
  }

  function removeLocation(code: string, handle: string, reason = "left", announce = false): void {
    const { target, requesters } = locations.removeFollows(code, handle);
    if (target) hub.sendTo(code, target, "follow-cancelled", { requester: handle });
    for (const requester of requesters) {
      hub.followResponse(code, requester, handle, false, reason);
      hub.sendTo(code, handle, "follow-cancelled", { requester });
    }
    if (locations.remove(code, handle) || announce) {
      hub.broadcastExcept(code, handle, "location-stopped", { handle });
    }
    if (target || requesters.length) announceTrails(code);
  }

  hub.on("unsubscribed", ({ code, handle }: { code: string; handle: string }) => {
    // 다른 기기/재접속 소켓이 남아 있으면 공유·따라가기를 유지한다.
    // DB 멤버십은 보존하지만 마지막 연결의 위치·follow 관계는 정리한다.
    if (hub.subscriberCount(code, handle) === 0) removeLocation(code, handle);
  });

  async function route(request: IncomingMessage, response: ServerResponse, path: string): Promise<void> {
    const method = request.method;

    if (method === "POST" && path === "/v1/auth/signup") {
      const body = await readJson(request);
      if (!isValidHandle(body.handle)) invalid("아이디는 소문자 영문·숫자·밑줄 3~20자여야 합니다.");
      if (!isValidDisplayName(body.displayName)) invalid("표시 이름은 앞뒤 공백을 제외하고 2~20자여야 합니다.");
      if (!isValidPassword(body.password)) invalid("비밀번호는 8~72자여야 합니다.");
      if (findUserByHandle(db, body.handle)) {
        throw new HttpError(409, "HANDLE_TAKEN", "이미 사용 중인 아이디입니다.");
      }
      const passwordHash = await hashPassword(body.password);
      const user = createUser(db, { handle: body.handle, displayName: body.displayName, passwordHash });
      // 비밀번호 해시를 계산하는 동안 같은 아이디가 생성될 수도 있다.
      if (!user) throw new HttpError(409, "HANDLE_TAKEN", "이미 사용 중인 아이디입니다.");
      json(response, 201, { user: publicUser(user), token: issueToken(db, user.id) });
      return;
    }

    if (method === "POST" && path === "/v1/auth/login") {
      const body = await readJson(request);
      if (typeof body.handle !== "string" || typeof body.password !== "string") {
        invalid("아이디와 비밀번호가 필요합니다.");
      }
      const user = isValidHandle(body.handle) && isValidPassword(body.password)
        ? findUserByHandle(db, body.handle) : undefined;
      if (!user || !await verifyPassword(body.password, user.passwordHash)) {
        throw new HttpError(401, "INVALID_CREDENTIALS", "아이디 또는 비밀번호가 올바르지 않습니다.");
      }
      json(response, 200, { user: publicUser(user), token: issueToken(db, user.id) });
      return;
    }

    const { user, token } = authenticate(db, request);
    actors.set(response, user.handle);

    if (method === "GET" && path === "/v1/turn") {
      response.setHeader("cache-control", "no-store");
      json(response, 200, issueIceServers(user.handle));
      return;
    }

    if (method === "POST" && path === "/v1/auth/logout") {
      await readJson(request, true);
      revokeToken(db, token);
      hub.disconnectToken(tokenHash(token));
      json(response, 204);
      return;
    }

    if (method === "GET" && path === "/v1/me") {
      const room = findCurrentRoom(db, user.id);
      json(response, 200, { user: publicUser(user), room: room ? publicRoomDetails(db, room) : null });
      return;
    }

    if (method === "PATCH" && path === "/v1/me") {
      const body = await readJson(request);
      if (!isValidDisplayName(body.displayName)) invalid("표시 이름은 앞뒤 공백을 제외하고 2~20자여야 합니다.");
      const updated = updateDisplayName(db, user.id, body.displayName);
      if (!updated) throw new HttpError(404, "USER_NOT_FOUND", "사용자를 찾을 수 없습니다.");
      json(response, 200, { user: publicUser(updated) });
      return;
    }

    const userMatch = /^\/v1\/users\/([^/]+)$/.exec(path);
    if (method === "GET" && userMatch) {
      const handle = pathValue(userMatch[1]);
      if (!isValidHandle(handle)) invalid("아이디 형식이 올바르지 않습니다.");
      const found = findUserByHandle(db, handle);
      if (!found) throw new HttpError(404, "USER_NOT_FOUND", "사용자를 찾을 수 없습니다.");
      json(response, 200, { user: publicUser(found) });
      return;
    }

    if (path === "/v1/contacts") {
      if (method === "GET") {
        json(response, 200, { contacts: listContacts(db, user.id) });
        return;
      }
      if (method === "POST") {
        const body = await readJson(request);
        if (!isValidHandle(body.handle)) invalid("친구 아이디 형식이 올바르지 않습니다.");
        const contact = findUserByHandle(db, body.handle);
        if (!contact) throw new HttpError(404, "USER_NOT_FOUND", "사용자를 찾을 수 없습니다.");
        if (!addContact(db, user.id, contact.id)) {
          throw new HttpError(409, "CONTACT_CONFLICT", "자기 자신 또는 이미 추가한 친구입니다.");
        }
        json(response, 201, { contact: publicUser(contact) });
        return;
      }
    }

    const contactMatch = /^\/v1\/contacts\/([^/]+)$/.exec(path);
    if (method === "DELETE" && contactMatch) {
      const handle = pathValue(contactMatch[1]);
      if (!isValidHandle(handle)) invalid("친구 아이디 형식이 올바르지 않습니다.");
      deleteContact(db, user.id, handle);
      json(response, 204);
      return;
    }

    if (method === "POST" && path === "/v1/rooms") {
      const body = await readJson(request);
      if (body.name !== undefined && typeof body.name !== "string") invalid("방 이름은 문자열이어야 합니다.");
      const invitees = body.invitees === undefined ? [] : body.invitees;
      if (!Array.isArray(invitees) || !invitees.every(isValidHandle)) {
        invalid("초대 대상은 올바른 아이디의 배열이어야 합니다.");
      }
      for (const handle of new Set(invitees as string[])) {
        if (!findUserByHandle(db, handle)) {
          throw new HttpError(404, "USER_NOT_FOUND", "초대할 사용자를 찾을 수 없습니다.");
        }
      }
      for (let attempt = 0; attempt < 10; attempt += 1) {
        const room = createRoom(db, {
          code: generateRoomCode(),
          name: typeof body.name === "string" ? body.name.trim() : "",
          createdBy: user.id,
        });
        if (room) {
          json(response, 201, { room: publicRoom(room) });
          return;
        }
      }
      throw new HttpError(409, "ROOM_CODE_CONFLICT", "방 코드를 발급하지 못했습니다. 다시 시도해 주세요.");
    }

    const roomMatch = /^\/v1\/rooms\/([^/]+)(?:\/(join|leave|events|signal|location|positions|follow(?:\/respond)?))?$/.exec(path);
    if (roomMatch) {
      const rawCode = pathValue(roomMatch[1]);
      if (!/^[A-Za-z0-9]+$/.test(rawCode)) {
        throw new HttpError(404, "ROOM_NOT_FOUND", "방을 찾을 수 없습니다.");
      }
      const code = rawCode.toUpperCase();
      const action = roomMatch[2];
      const room = findRoomByCode(db, code);
      if (!room) throw new HttpError(404, "ROOM_NOT_FOUND", "방을 찾을 수 없습니다.");

      if (method === "GET" && !action) {
        json(response, 200, { room: publicRoom(room), members: listRoomMembers(db, room.id) });
        return;
      }
      if (method === "POST" && action === "join") {
        await readJson(request, true);
        if (joinRoom(db, room.id, user.id)) hub.broadcast(code, "member-joined", { handle: user.handle });
        json(response, 200, { room: publicRoom(room) });
        return;
      }
      if (method === "POST" && action === "leave") {
        await readJson(request, true);
        if (leaveRoom(db, room.id, user.id)) hub.broadcast(code, "member-left", { handle: user.handle });
        removeLocation(code, user.handle);
        hub.disconnectUser(code, user.handle);
        hub.clearSignals(code, user.handle);
        if (deleteEmptyRoom(db, room.id)) {
          locations.clear(code);
          hub.clearSignals(code);
        }
        json(response, 204);
        return;
      }
      if (action === "follow" && method === "POST") {
        requireMember(db, room, user);
        const body = await readJson(request);
        requireMember(db, room, user);
        if (!isValidHandle(body.target) || body.target === user.handle) invalid("다른 참여자의 아이디가 필요합니다.");
        const target = findUserByHandle(db, body.target);
        if (!target || !isRoomMember(db, room.id, target.id)) {
          throw new HttpError(403, "NOT_ROOM_MEMBER", "대상자가 방 참여자가 아닙니다.");
        }
        const previous = locations.targetOf(code, user.handle);
        const accepted = locations.requestFollow(code, user.handle, target.handle);
        if (previous && previous !== target.handle) hub.sendTo(code, previous, "follow-cancelled", { requester: user.handle });
        announceTrails(code);
        if (accepted) hub.followResponse(code, user.handle, target.handle, true);
        else hub.sendTo(code, target.handle, "follow-request", { requester: user.handle });
        json(response, 202, { accepted: true });
        return;
      }
      if (action === "follow/respond" && method === "POST") {
        requireMember(db, room, user);
        const body = await readJson(request);
        requireMember(db, room, user);
        if (!isValidHandle(body.requester) || typeof body.accepted !== "boolean") invalid("요청 아이디와 동의 여부가 필요합니다.");
        const requester = findUserByHandle(db, body.requester);
        if (!requester || !isRoomMember(db, room.id, requester.id)) {
          throw new HttpError(403, "NOT_ROOM_MEMBER", "요청자가 방 참여자가 아닙니다.");
        }
        const requesters = locations.respondFollow(code, user.handle, requester.handle, body.accepted);
        if (!requesters) throw new HttpError(409, "FOLLOW_EXPIRED", "이미 끝난 따라가기 요청입니다.");
        for (const handle of requesters) {
          hub.followResponse(code, handle, user.handle, body.accepted);
          hub.sendTo(code, user.handle, "follow-cancelled", { requester: handle });
        }
        announceTrails(code);
        json(response, 202, { accepted: true });
        return;
      }
      if (action === "follow" && method === "DELETE") {
        requireMember(db, room, user);
        const target = locations.unfollow(code, user.handle);
        if (target) {
          hub.sendTo(code, target, "follow-cancelled", { requester: user.handle });
          announceTrails(code);
        }
        json(response, 202, { accepted: true });
        return;
      }
      if (method === "POST" && action === "location") {
        requireMember(db, room, user);
        const body = await readJson(request);
        requireMember(db, room, user);
        const result = locations.accept(code, { ...body, handle: user.handle });
        if (!result.ok) {
          if (result.reason === "invalid") invalid("위치 표본이 올바르지 않습니다.");
          countLocation(code, "rate");
          throw new HttpError(429, "LOCATION_RATE_LIMIT", "위치를 너무 자주 보내고 있습니다.");
        }
        countLocation(code, result.dropped ? "dropped" : "accepted");
        if (!result.dropped) {
          hub.broadcastExcept(code, user.handle, "location", locations.position(code, user.handle));
        }
        json(response, 202, { accepted: true, dropped: result.dropped });
        return;
      }
      if (method === "GET" && action === "positions") {
        requireMember(db, room, user);
        response.setHeader("cache-control", "no-store");
        json(response, 200, locations.snapshot(code));
        return;
      }
      if (method === "DELETE" && action === "location") {
        requireMember(db, room, user);
        removeLocation(code, user.handle, "stopped", true);
        json(response, 202, { accepted: true });
        return;
      }
      if (method === "GET" && action === "events") {
        requireMember(db, room, user);
        let unsubscribe = () => {};
        const stream = openEventStream(response, () => unsubscribe(), () => Boolean(lookupToken(db, token)));
        unsubscribe = hub.subscribe(code, user.handle, tokenHash(token), stream.send, stream.close);
        if (!stream.send("hello", {
          self: publicUser(user), members: listRoomMembers(db, room.id),
          leader: room.createdBy, ...locations.snapshot(code),
          followTarget: locations.targetOf(code, user.handle),
          followRequests: locations.requestsFor(code, user.handle),
        })) {
          unsubscribe();
        } else {
          // 재전송 중 전송에 실패해도 스트림의 onClose에서 구독을 해제한다.
          hub.replaySignals(code, user.handle, stream.send);
        }
        return;
      }
      if (method === "POST" && action === "signal") {
        requireMember(db, room, user);
        const body = await readJson(request);
        if (!isValidHandle(body.to) || typeof body.kind !== "string" || !SIGNAL_KINDS.has(body.kind)
          || !Object.hasOwn(body, "payload")) {
          invalid("수신 아이디, offer·answer·ice·custom 중 종류, JSON payload가 필요합니다.");
        }
        // 본문을 받는 사이 나간 사용자도 시그널을 보내지 못하게 다시 확인한다.
        requireMember(db, room, user);
        const recipient = findUserByHandle(db, body.to);
        if (!recipient || !isRoomMember(db, room.id, recipient.id)) {
          throw new HttpError(403, "NOT_ROOM_MEMBER", "수신자가 방 참여자가 아닙니다.");
        }
        const signal = {
          from: user.handle, kind: body.kind, payload: body.payload,
        };
        hub.queueSignal(code, recipient.handle, "signal", signal);
        const delivered = hub.sendTo(code, recipient.handle, "signal", signal);
        json(response, 202, { delivered });
        return;
      }
    }

    throw new HttpError(404, "NOT_FOUND", "요청한 경로를 찾을 수 없습니다.");
  }

  return (request, response) => {
    const started = Date.now();
    // aborted 뒤에 오는 소켓 오류도 처리하여 연결 중단으로 서버가 종료되지 않게 한다.
    request.on("error", () => {});
    // 쿼리 문자열과 본문, 헤더는 로그에 남기지 않는다.
    const path = (request.url ?? "/").split("?", 1)[0];
    let logged = false;
    const log = () => {
      if (logged) return;
      logged = true;
      if (request.method === "POST" && /^\/v1\/rooms\/[^/]+\/location$/.test(path)) return;
      const actor = actors.get(response);
      process.stdout.write(`${request.method ?? "UNKNOWN"} ${path} ${response.statusCode} ${Date.now() - started}${actor ? ` ${actor}` : ""}\n`);
    };
    response.once("finish", log);
    response.once("close", log);
    void route(request, response, path).catch((error: unknown) => {
      request.resume();
      if (response.destroyed) return;
      if (response.headersSent) {
        response.end();
        return;
      }
      if (error instanceof HttpError) {
        json(response, error.status, { error: { code: error.code, message: error.message } });
      } else {
        json(response, 500, { error: { code: "INTERNAL_ERROR", message: "서버 오류가 발생했습니다." } });
      }
    });
  };
}
