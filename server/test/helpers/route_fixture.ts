import assert from "node:assert/strict";
import { IncomingMessage } from "node:http";
import type { RequestListener, ServerResponse } from "node:http";
import { Socket } from "node:net";
import { Writable } from "node:stream";
import type { TestContext } from "node:test";
import { issueToken, tokenHash } from "../../src/auth.ts";
import { openDb } from "../../src/db.ts";
import { RoomLocationStore } from "../../src/locations.ts";
import type { LocationFix } from "../../src/locations.ts";
import { RoomEventHub } from "../../src/rooms.ts";
import { createRoom, createUser, joinRoom, updateUserConsent } from "../../src/store.ts";
import { distance } from "../../src/route_contract.ts";
import type { FollowRouteRequest, Point } from "../../src/route_contract.ts";
import { parseNaverRoute } from "../../src/route_providers/naver.ts";
import type { NaverConfig, RouteConfig, RouteProvider } from "../../src/route_providers/naver.ts";
import type { RouteServiceOptions } from "../../src/routes.ts";

export const naverConfig: NaverConfig = { provider: "naver", keyId: "synthetic-key-id", key: "synthetic-secret" };
export const origin = { lat: 37.5, lng: 127 };
export const destination = { lat: 37.501, lng: 127 };
export const selfStream = "1111111111111111";
export const leaderStream = "2222222222222222";

// Deliberately invented coordinates and summaries; no captured API data.
export function naverBody(start: Point = origin, end: Point = destination) {
  return { code: 0, route: { traoptimal: [{
    summary: { start: { location: [start.lng, start.lat] }, goal: { location: [end.lng, end.lat] },
      distance: Math.ceil(distance(start, end)), duration: distance(start, end) === 0 ? 0 : 12_345 },
    path: [[start.lng, start.lat], [end.lng, end.lat]],
  }] } };
}

export function routeFixture(t: TestContext, options: RouteServiceOptions = {}) {
  const db = openDb(":memory:");
  const hub = new RoomEventHub();
  let now = Date.now();
  let monotonic = 0;
  let config: RouteConfig = naverConfig;
  let provider: RouteProvider = async (start, end) => parseNaverRoute(naverBody(start, end), start, end);
  let nextStarted = Promise.withResolvers<void>();
  const calls: { origin: Point; destination: Point; signal: AbortSignal }[] = [];
  const locations = new RoomLocationStore(() => now);
  const users = ["leader", "follower", "third", "outsider"].map((handle) =>
    createUser(db, { handle, displayName: handle, passwordHash: "unused" })!);
  const tokens = new Map(users.map((user) => [user.handle, issueToken(db, user.id)]));
  const room = createRoom(db, { code: "ABC234", name: "경로", createdBy: users[0].id })!;
  for (const user of users.slice(1, 3)) joinRoom(db, room.id, user.id);
  for (const user of users) updateUserConsent(db, user.id, { privacyVersion: "4", locationVersion: "4" });
  for (const user of users.slice(0, 3)) {
    const hash = tokenHash(tokens.get(user.handle)!);
    hub.claim(room.code, user.handle, hash, hash);
  }
  const relation = locations.requestFollow(room.code, "follower", "leader");
  locations.respondFollow(room.code, "leader", relation.requestId, true);
  const seqs = new Map<string, number>();
  function publish(handle: string, changes: Partial<LocationFix> = {}) {
    const seq = (seqs.get(handle) ?? -1) + 1;
    const fix = { handle, stream: handle === "leader" ? leaderStream : selfStream,
      ...(handle === "leader" ? destination : origin), at: now, acc: 3, seq, ...changes };
    assert.deepEqual(locations.accept(room.code, fix), { ok: true, dropped: false });
    seqs.set(handle, fix.seq);
    return fix;
  }
  publish("leader");
  publish("follower");
  const routeOptions: RouteServiceOptions = { ...options, now: () => now, monotonicNow: () => monotonic,
    config: () => config,
    provider: async (...args) => {
      calls.push({ origin: args[0], destination: args[1], signal: args[2] });
      nextStarted.resolve();
      nextStarted = Promise.withResolvers<void>();
      return provider(...args);
    },
  };
  let calculation = 0;
  function request(overrides: Partial<FollowRouteRequest> = {}): FollowRouteRequest {
    const id = ++calculation;
    const position = locations.position(room.code, "leader")!;
    const self = locations.position(room.code, "follower")!;
    return { schemaVersion: 1, followRequestId: locations.relationOf(room.code, "follower")!.requestId,
      guidanceGeneration: id, calculationId: `calculation-${id}`, requestId: `attempt-${id}`, mode: "A",
      originRef: { stream: self.stream, seq: self.seq }, anchor: { kind: "sample", ref: { stream: position.stream, seq: position.seq } },
      ...overrides };
  }
  function elapse(ms: number) { now += ms; monotonic += ms; }
  function advance(ms: number) {
    assert.equal(ms % 1000, 0);
    for (let i = 0; i < ms; i += 1000) {
      elapse(1000);
      publish("leader", { lat: destination.lat + (seqs.get("leader")! + 1) * .000001 });
      publish("follower", { lat: origin.lat + (seqs.get("follower")! + 1) * .000001 });
    }
  }
  t.after(() => { hub.close(); db.close(); });
  return { db, hub, locations, users, room, tokens, relation, calls, routeOptions, request, publish, elapse, advance,
    now: () => now, setConfig: (value: RouteConfig) => { config = value; },
    setProvider: (value: RouteProvider) => { provider = value; }, nextCall: () => nextStarted.promise,
  };
}

export class JsonReply extends Writable {
  statusCode = 200;
  headersSent = false;
  readonly chunks: Buffer[] = [];
  readonly headers = new Map<string, string>();
  setHeader(name: string, value: string): void { this.headers.set(name, value); }
  writeHead(status: number, headers: Record<string, string>): void {
    this.statusCode = status;
    for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
  }
  flushHeaders(): void { this.headersSent = true; }
  override _write(chunk: Buffer, _encoding: BufferEncoding, done: () => void): void {
    this.headersSent = true;
    this.chunks.push(Buffer.from(chunk));
    done();
  }
  json(): any { return JSON.parse(Buffer.concat(this.chunks).toString()); }
}

export function dispatch(app: RequestListener, token: string, body: unknown, options: {
  path?: string; method?: string; device?: string; raw?: string; headers?: Record<string, string>;
} = {}) {
  const request = new IncomingMessage(new Socket());
  request.method = options.method ?? "POST";
  request.url = options.path ?? "/v1/rooms/ABC234/follow-route";
  request.headers = { authorization: `Bearer ${token}`, "content-type": "application/json",
    ...(options.device ? { "x-unavo-device": options.device } : {}), ...options.headers };
  const response = new JsonReply();
  const done = new Promise<JsonReply>((resolve, reject) => {
    response.once("finish", () => resolve(response));
    response.once("error", reject);
  });
  app(request, response as unknown as ServerResponse);
  if (options.raw !== undefined) request.push(options.raw);
  else if (body !== undefined) request.push(JSON.stringify(body));
  request.complete = true;
  request.push(null);
  return { request, response, done };
}
