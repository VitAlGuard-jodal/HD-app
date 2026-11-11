import type { IncomingMessage, RequestListener, ServerResponse } from "node:http";
import type { DatabaseSync } from "node:sqlite";
import { avatarDirectory, avatarPng, isMascotKind, MAX_AVATAR_BODY_BYTES, readAvatar, saveAvatar } from "./avatars.ts";
import { hashPassword, issueToken, lookupToken, revokeToken, tokenHash, verifyPassword } from "./auth.ts";
import { isValidDisplayName, isValidHandle, isValidPassword } from "./handles.ts";
import { LOCATION_DISCONNECT_GRACE_MS, LOCATION_STALE_MS, LOCATION_SWEEP_INTERVAL_MS, RoomLocationStore } from "./locations.ts";
import { generateRoomCode, RoomEventHub } from "./rooms.ts";
import { openEventStream } from "./sse.ts";
import { issueIceServers } from "./turn.ts";
import {
  addContact, createRoom, createUser, deleteContact, deleteEmptyRoom, findCurrentRoom, findRoomByCode, findUserByHandle,
  findRoomMembership, isRoomMember, joinRoom, leaveRoom, listContacts, listRoomMembers, publicRoom, publicRoomDetails, publicUser,
  updateDisplayName, userRoomCodes,
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

function readBody(request: IncomingMessage, maxBytes = MAX_BODY_BYTES): Promise<Buffer> {
  const tooLarge = () => new HttpError(413, "BODY_TOO_LARGE", `본문은 ${Math.ceil(maxBytes / 1024)}KB 이하여야 합니다.`);
  if (Number(request.headers["content-length"]) > maxBytes) {
    request.resume();
    return Promise.reject(tooLarge());
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
      if (length > maxBytes) {
        fail(tooLarge());
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

async function readJson(request: IncomingMessage, allowEmpty = false, maxBytes = MAX_BODY_BYTES): Promise<Record<string, unknown>> {
  const raw = await readBody(request, maxBytes);
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

export function createApp({ db, hub = new RoomEventHub(), locations = new RoomLocationStore(), avatarsDir = avatarDirectory(db) }: {
  db: DatabaseSync; hub?: RoomEventHub; locations?: RoomLocationStore; avatarsDir?: string;
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

  const disconnectTimers = new Map<string, Map<string, ReturnType<typeof setTimeout>>>();
  let closing = false;
  function cancelDisconnect(code: string, handle: string): void {
    const timers = disconnectTimers.get(code);
    clearTimeout(timers?.get(handle));
    timers?.delete(handle);
    if (timers?.size === 0) disconnectTimers.delete(code);
  }

  function sendTrail(code: string, requester: string, target: string): void {
    hub.sendTo(code, requester, "trail", {
      handle: target, points: locations.snapshot(code, requester).trails[target] ?? [],
      revision: locations.revision(code),
    });
  }

  function cancelRequest(code: string, relation: { requestId: string; requester: string; target: string }, reason = "cancelled"): void {
    hub.sendTo(code, relation.target, "follow-cancelled", {
      requestId: relation.requestId, requester: relation.requester, reason, revision: locations.revision(code),
    });
  }

  function removeLocation(code: string, handle: string, reason = "left"): void {
    cancelDisconnect(code, handle);
    const { outgoing, incoming } = locations.removeFollows(code, handle);
    const removed = locations.remove(code, handle);
    const revision = locations.revision(code);
    if (outgoing) cancelRequest(code, outgoing);
    for (const request of incoming) {
      hub.followResponse(code, request.requestId, request.requester, handle, false, revision, reason);
      cancelRequest(code, request);
    }
    if (removed || outgoing || incoming.length) {
      hub.broadcastExcept(code, handle, "location-stopped", { handle, reason, revision });
    }
  }

  function expireLocations(): void {
    for (const { code, handle } of locations.stale()) removeLocation(code, handle, "stale");
  }

  function scheduleDisconnect(code: string, handle: string): void {
    cancelDisconnect(code, handle);
    let timers = disconnectTimers.get(code);
    if (!timers) { timers = new Map(); disconnectTimers.set(code, timers); }
    timers.set(handle, setTimeout(() => {
      cancelDisconnect(code, handle);
      if (closing || hub.subscriberCount(code, handle) !== 0) return;
      const lastReceivedAt = locations.lastReceivedAt(code, handle);
      if (locations.isSharing(code, handle) && lastReceivedAt !== undefined) {
        if (Date.now() - lastReceivedAt < LOCATION_STALE_MS) scheduleDisconnect(code, handle);
        // 위치까지 끊긴 공유자는 기존 sweep이 stale로 정리한다.
        return;
      }
      removeLocation(code, handle);
    }, LOCATION_DISCONNECT_GRACE_MS).unref());
  }

  const locationSweepTimer = setInterval(expireLocations, LOCATION_SWEEP_INTERVAL_MS).unref();
  hub.on("subscribed", ({ code, handle }: { code: string; handle: string }) => {
    cancelDisconnect(code, handle);
    locations.reconnected(code, handle);
  });
  hub.on("unsubscribed", ({ code, handle }: { code: string; handle: string }) => {
    if (closing || hub.subscriberCount(code, handle) !== 0) return;
    // 같은 handle의 마지막 소켓만 유예를 시작한다. 재구독은 이 타이머를 취소한다.
    locations.disconnected(code, handle);
    scheduleDisconnect(code, handle);
  });
  hub.once("closing", () => {
    closing = true;
    clearInterval(locationSweepTimer);
    clearTimeout(locationLogTimer);
    for (const timers of disconnectTimers.values()) for (const timer of timers.values()) clearTimeout(timer);
    disconnectTimers.clear();
  });

  function requireFollowRate(code: string, handle: string): void {
    if (!locations.allowFollow(code, handle)) {
      throw new HttpError(429, "FOLLOW_RATE_LIMIT", "따라가기 요청은 1초에 한 번만 보낼 수 있습니다.");
    }
  }

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
      for (const code of locations.codesFor(user.handle)) removeLocation(code, user.handle, "stopped");
      json(response, 204);
      return;
    }

    if (method === "GET" && path === "/v1/me") {
      const room = findCurrentRoom(db, user.id);
      const details = room ? publicRoomDetails(db, room) : null;
      json(response, 200, {
        user: { ...publicUser(user), order: details?.members.find((member) => member.handle === user.handle)?.order ?? null },
        room: details,
      });
      return;
    }

    if (path === "/v1/me/avatar" && (method === "PUT" || method === "DELETE")) {
      let kind: StoredUser["avatar"]["kind"] = null;
      let png: Buffer | undefined;
      if (method === "PUT") {
        const body = await readJson(request, false, MAX_AVATAR_BODY_BYTES);
        if (body.kind === "photo") {
          png = avatarPng(body.png);
          if (!png) invalid("프로필 사진은 300KB 이하의 256×256 PNG여야 합니다.");
          kind = "photo";
        } else if (isMascotKind(body.kind) && body.png === undefined) {
          kind = body.kind;
        } else {
          invalid("기본 아바타 또는 사진을 선택해 주세요.");
        }
      }
      // 본문을 기다리는 동안 로그아웃된 토큰은 저장에 사용할 수 없다.
      const current = authenticate(db, request).user;
      const updated = saveAvatar(db, avatarsDir, current, kind, png);
      for (const code of userRoomCodes(db, user.id)) {
        hub.broadcast(code, "member-updated", { handle: user.handle, avatar: updated.avatar });
      }
      response.setHeader("cache-control", "no-store");
      json(response, 200, { user: publicUser(updated) });
      return;
    }

    const avatarMatch = /^\/v1\/users\/([^/]+)\/avatar$/.exec(path);
    if (method === "GET" && avatarMatch) {
      response.setHeader("cache-control", "no-store");
      const handle = pathValue(avatarMatch[1]);
      if (!isValidHandle(handle)) invalid("아이디 형식이 올바르지 않습니다.");
      const found = findUserByHandle(db, handle);
      const version = new URL(request.url!, "http://localhost").searchParams.get("v");
      // 과거 버전 URL에 새 사진을 immutable로 저장하지 않는다.
      if (!found || found.avatar.kind !== "photo" || version !== String(found.avatar.version)) {
        throw new HttpError(404, "AVATAR_NOT_FOUND", "프로필 사진을 찾을 수 없습니다.");
      }
      const png = readAvatar(avatarsDir, handle);
      if (!png) throw new HttpError(404, "AVATAR_NOT_FOUND", "프로필 사진을 찾을 수 없습니다.");
      response.setHeader("content-type", "image/png");
      response.setHeader("cache-control", "private, max-age=31536000, immutable");
      response.setHeader("x-content-type-options", "nosniff");
      response.end(png);
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
        const room = findCurrentRoom(db, user.id);
        const orders = new Map(room ? listRoomMembers(db, room.id).map((member) => [member.handle, member.order]) : []);
        json(response, 200, { contacts: listContacts(db, user.id).map((contact) => ({
          ...contact, order: orders.get(contact.handle) ?? null,
        })) });
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
        if (joinRoom(db, room.id, user.id)) {
          hub.broadcast(code, "member-joined", { handle: user.handle, revision: locations.changed(code) });
        }
        json(response, 200, { room: publicRoom(room) });
        return;
      }
      if (method === "POST" && action === "leave") {
        await readJson(request, true);
        if (!findRoomMembership(db, room.id, user.id)) {
          throw new HttpError(403, "NOT_ROOM_MEMBER", "방 참여자만 사용할 수 있습니다.");
        }
        if (leaveRoom(db, room.id, user.id)) {
          hub.broadcast(code, "member-left", { handle: user.handle, revision: locations.changed(code) });
        }
        hub.disconnectUser(code, user.handle);
        removeLocation(code, user.handle);
        hub.clearSignals(code, user.handle);
        if (deleteEmptyRoom(db, room.id)) {
          for (const timer of disconnectTimers.get(code)?.values() ?? []) clearTimeout(timer);
          disconnectTimers.delete(code);
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
        requireFollowRate(code, user.handle);
        expireLocations();
        const previous = locations.relationOf(code, user.handle);
        const result = locations.requestFollow(code, user.handle, target.handle, user.displayName);
        if (result.changed) {
          if (previous) cancelRequest(code, previous, previous.requestId === result.requestId ? "accepted" : "cancelled");
          if (result.accepted) {
            sendTrail(code, user.handle, target.handle);
            hub.followResponse(code, result.requestId, user.handle, target.handle, true, result.revision);
          } else {
            hub.sendTo(code, target.handle, "follow-request", {
              requestId: result.requestId, requester: user.handle, displayName: user.displayName,
              revision: result.revision,
            });
          }
        }
        json(response, 202, { requestId: result.requestId, revision: result.revision, accepted: result.accepted });
        return;
      }
      if (action === "follow/respond" && method === "POST") {
        requireMember(db, room, user);
        const body = await readJson(request);
        requireMember(db, room, user);
        if (typeof body.requestId !== "string" || typeof body.accepted !== "boolean") invalid("요청 ID와 동의 여부가 필요합니다.");
        if (!locations.requestById(code, user.handle, body.requestId)) {
          throw new HttpError(404, "FOLLOW_EXPIRED", "이미 끝난 따라가기 요청입니다.");
        }
        requireFollowRate(code, user.handle);
        const requests = locations.respondFollow(code, user.handle, body.requestId, body.accepted)!;
        const revision = locations.revision(code);
        for (const request of requests) {
          if (body.accepted) sendTrail(code, request.requester, user.handle);
          hub.followResponse(code, request.requestId, request.requester, user.handle, body.accepted, revision);
          cancelRequest(code, request, body.accepted ? "accepted" : "declined");
        }
        json(response, 202, { accepted: body.accepted, revision });
        return;
      }
      if (action === "follow" && method === "DELETE") {
        requireMember(db, room, user);
        requireFollowRate(code, user.handle);
        const relation = locations.unfollow(code, user.handle);
        if (relation) cancelRequest(code, relation);
        json(response, 202, { accepted: true, revision: locations.revision(code) });
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
          hub.broadcastExcept(code, user.handle, "location", { ...locations.position(code, user.handle), revision: locations.revision(code) });
        }
        json(response, 202, { accepted: true, dropped: result.dropped });
        return;
      }
      if (method === "GET" && action === "positions") {
        requireMember(db, room, user);
        response.setHeader("cache-control", "no-store");
        expireLocations();
        json(response, 200, { ...locations.snapshot(code, user.handle), revision: locations.revision(code) });
        return;
      }
      if (method === "DELETE" && action === "location") {
        requireMember(db, room, user);
        removeLocation(code, user.handle, "stopped");
        json(response, 202, { accepted: true });
        return;
      }
      if (method === "GET" && action === "events") {
        requireMember(db, room, user);
        expireLocations();
        let unsubscribe = () => {};
        const stream = openEventStream(response, () => unsubscribe(), () => Boolean(lookupToken(db, token)));
        unsubscribe = hub.subscribe(code, user.handle, tokenHash(token), stream.send, stream.close);
        if (!stream.send("hello", {
          self: { ...publicUser(user), order: listRoomMembers(db, room.id).find((member) => member.handle === user.handle)?.order },
          members: listRoomMembers(db, room.id),
          leader: room.createdBy, ...locations.snapshot(code, user.handle),
          revision: locations.revision(code),
          followTarget: locations.targetOf(code, user.handle),
          pendingFollow: locations.pendingOf(code, user.handle),
          followRequestId: locations.relationOf(code, user.handle)?.requestId ?? null,
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
