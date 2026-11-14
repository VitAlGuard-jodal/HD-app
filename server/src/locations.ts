import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { SampleRef } from "./route_contract.ts";
import { STOP_EVIDENCE_RETENTION_MS } from "./location_quality.ts";

export interface LocationFix {
  handle: string;
  stream: string;
  lat: number;
  lng: number;
  acc?: number;
  // Client-reported sample source, not device identity or an authorization claim.
  src?: "vehicle";
  speed?: number;
  heading?: number;
  at: number;
  seq: number;
  receivedAt: number;
}

export const LOCATION_TRAIL_LIMIT = 7_200;
export const LOCATION_MIN_INTERVAL_MS = 400;
export const LOCATION_DISCONNECT_GRACE_MS = 30_000;
export const LOCATION_STALE_MS = 90_000;
export const LOCATION_SWEEP_INTERVAL_MS = 30_000;
export const FOLLOW_MIN_INTERVAL_MS = 1_000;
export const LOCATION_REFERENCE_AGE_MS = 10_000;
export const LOCATION_REFERENCE_LIMIT = 64;

export interface LocationInvalidation { code: string; requester?: string; handle?: string }

export interface FollowRelation {
  requestId: string;
  requester: string;
  target: string;
  displayName: string;
}
export interface LocationSnapshot {
  positions: LocationFix[];
  trails: Record<string, LocationFix[]>;
}

type Acceptance = { ok: false; reason: "invalid" | "rate" } | { ok: true; dropped: boolean };
interface RoomLocations {
  revision: number;
  positions: Map<string, LocationFix>;
  trails: Map<string, LocationFix[]>;
  followers: Map<string, Set<string>>;
  accepted: Map<string, FollowRelation>;
  pendingRequests: Map<string, FollowRelation>;
  sharing: Set<string>;
  disconnectedAt: Map<string, number>;
  lastSeq: Map<string, number>;
  lastReceivedAt: Map<string, number>;
  lastFollowAt: Map<string, number>;
  recent: Map<string, LocationFix[]>;
}

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function valid(value: unknown): value is Omit<LocationFix, "receivedAt"> {
  if (!value || typeof value !== "object") return false;
  const fix = value as Record<string, unknown>;
  return typeof fix.handle === "string" && fix.handle.length > 0
    && typeof fix.stream === "string" && /^[0-9a-f]{16}$/.test(fix.stream)
    && finite(fix.lat) && fix.lat >= -90 && fix.lat <= 90
    && finite(fix.lng) && fix.lng >= -180 && fix.lng <= 180
    && (fix.acc === undefined || finite(fix.acc) && fix.acc >= 0)
    && (fix.src === undefined || fix.src === "vehicle")
    && (fix.speed === undefined || finite(fix.speed) && fix.speed >= 0)
    && (fix.heading === undefined || finite(fix.heading) && fix.heading >= 0 && fix.heading <= 360)
    && finite(fix.at) && fix.at >= 0 && Number.isSafeInteger(fix.seq) && (fix.seq as number) >= 0;
}

export class RoomLocationStore extends EventEmitter {
  #rooms = new Map<string, RoomLocations>();
  #now: () => number;

  constructor(now = () => Date.now()) { super(); this.#now = now; }

  serverNowMs(): number { return this.#now(); }

  #room(code: string): RoomLocations {
    let room = this.#rooms.get(code);
    if (!room) {
      room = { revision: 0, positions: new Map(), trails: new Map(), followers: new Map(),
        accepted: new Map(), pendingRequests: new Map(), sharing: new Set(), disconnectedAt: new Map(),
        lastSeq: new Map(), lastReceivedAt: new Map(), lastFollowAt: new Map(), recent: new Map() };
      this.#rooms.set(code, room);
    }
    return room;
  }

  revision(code: string): number { return this.#rooms.get(code)?.revision ?? 0; }
  changed(code: string): number { return ++this.#room(code).revision; }

  allowFollow(code: string, handle: string): boolean {
    const room = this.#room(code);
    const now = this.#now();
    const previous = room.lastFollowAt.get(handle);
    if (previous !== undefined && now - previous < FOLLOW_MIN_INTERVAL_MS) return false;
    room.lastFollowAt.set(handle, now);
    return true;
  }

  disconnected(code: string, handle: string): void {
    const room = this.#room(code);
    if (room.disconnectedAt.has(handle)) return;
    room.disconnectedAt.set(handle, this.#now());
    room.revision++;
  }

  reconnected(code: string, handle: string): void {
    const room = this.#rooms.get(code);
    if (room?.disconnectedAt.delete(handle)) room.revision++;
  }

  disconnectedAt(code: string, handle: string): number | undefined {
    return this.#rooms.get(code)?.disconnectedAt.get(handle);
  }

  isSharing(code: string, handle: string): boolean {
    return this.#rooms.get(code)?.sharing.has(handle) ?? false;
  }

  lastReceivedAt(code: string, handle: string): number | undefined {
    const room = this.#rooms.get(code);
    // 중지 뒤 남겨 둔 속도 제한 시각은 새 공유의 위치 수신으로 보지 않는다.
    return room?.positions.has(handle) ? room.lastReceivedAt.get(handle) : undefined;
  }

  targetOf(code: string, requester: string): string | null {
    return this.#rooms.get(code)?.accepted.get(requester)?.target ?? null;
  }

  relationOf(code: string, requester: string): FollowRelation | undefined {
    const room = this.#rooms.get(code);
    const relation = room?.accepted.get(requester) ?? room?.pendingRequests.get(requester);
    return relation ? { ...relation } : undefined;
  }

  pendingOf(code: string, requester: string): string | null {
    return this.#rooms.get(code)?.pendingRequests.get(requester)?.target ?? null;
  }

  requestsFor(code: string, target: string): FollowRelation[] {
    return [...(this.#rooms.get(code)?.pendingRequests.values() ?? [])]
      .filter((request) => request.target === target).map((request) => ({ ...request }));
  }

  acceptedFollowersOf(code: string, target: string): FollowRelation[] {
    return [...(this.#rooms.get(code)?.accepted.values() ?? [])]
      .filter((relation) => relation.target === target).map((relation) => ({ ...relation }));
  }

  acceptedFollowerTargets(): { code: string; target: string }[] {
    return [...this.#rooms].flatMap(([code, room]) => [...room.followers.keys()].map((target) => ({ code, target })));
  }

  recentSamples(code: string, handle: string): LocationFix[] {
    return (this.#rooms.get(code)?.recent.get(handle) ?? [])
      .filter((fix) => this.#now() - fix.receivedAt <= STOP_EVIDENCE_RETENTION_MS).map((fix) => ({ ...fix }));
  }

  requestById(code: string, target: string, requestId: string): FollowRelation | undefined {
    return this.requestsFor(code, target).find((request) => request.requestId === requestId);
  }

  #addFollower(room: RoomLocations, relation: FollowRelation): void {
    let followers = room.followers.get(relation.target);
    if (!followers) {
      followers = new Set();
      room.followers.set(relation.target, followers);
      const current = room.positions.get(relation.target);
      room.trails.set(relation.target, current ? [current] : []);
    }
    followers.add(relation.requester);
    room.accepted.set(relation.requester, relation);
    room.pendingRequests.delete(relation.requester);
  }

  requestFollow(code: string, requester: string, target: string, displayName = requester) {
    const room = this.#room(code);
    const previous = this.relationOf(code, requester);
    if (previous?.target === target) {
      const promoted = !room.accepted.has(requester) && room.sharing.has(target);
      if (promoted) { this.#addFollower(room, previous); room.revision++; }
      if (promoted) this.emit("relations-changed", { code, target });
      return { ...previous, accepted: room.accepted.has(requester), changed: promoted, revision: room.revision };
    }
    this.unfollow(code, requester);
    const relation = { requestId: randomUUID(), requester, target, displayName };
    const accepted = room.sharing.has(target);
    if (accepted) this.#addFollower(room, relation);
    else room.pendingRequests.set(requester, relation);
    room.revision++;
    this.emit("relations-changed", { code, target });
    return { ...relation, accepted, changed: true, revision: room.revision };
  }

  respondFollow(code: string, target: string, requestId: string, accepted: boolean): FollowRelation[] | null {
    const room = this.#rooms.get(code);
    const request = this.requestById(code, target, requestId);
    if (!room || !request) return null;
    if (!accepted) {
      this.unfollow(code, request.requester);
      return [request];
    }
    // 같은 공유 동의로 이 대상에게 도착한 대기 요청들을 함께 수락한다.
    room.sharing.add(target);
    const requests = this.requestsFor(code, target);
    for (const relation of requests) this.#addFollower(room, relation);
    room.revision++;
    this.emit("relations-changed", { code, target });
    return requests;
  }

  unfollow(code: string, requester: string): FollowRelation | undefined {
    const room = this.#rooms.get(code);
    const relation = this.relationOf(code, requester);
    if (!room || !relation) return undefined;
    room.pendingRequests.delete(requester);
    room.accepted.delete(requester);
    const followers = room.followers.get(relation.target);
    followers?.delete(requester);
    if (followers?.size === 0) {
      room.followers.delete(relation.target);
      room.trails.delete(relation.target);
    }
    room.revision++;
    room.recent.delete(requester);
    this.emit("invalidated", { code, requester } satisfies LocationInvalidation);
    this.emit("relations-changed", { code, target: relation.target });
    return relation;
  }

  removeFollows(code: string, handle: string): { outgoing?: FollowRelation; incoming: FollowRelation[] } {
    const outgoing = this.unfollow(code, handle);
    const room = this.#rooms.get(code);
    const incoming = [...(room?.accepted.values() ?? []), ...(room?.pendingRequests.values() ?? [])]
      .filter((relation) => relation.target === handle);
    for (const relation of incoming) this.unfollow(code, relation.requester);
    return { outgoing, incoming };
  }

  accept(code: string, fix: unknown, now = this.#now()): Acceptance {
    if (!valid(fix) || !finite(now)) return { ok: false, reason: "invalid" };
    const room = this.#room(code);
    const lastReceivedAt = room.lastReceivedAt.get(fix.handle);
    if (lastReceivedAt !== undefined && now - lastReceivedAt < LOCATION_MIN_INTERVAL_MS) {
      return { ok: false, reason: "rate" };
    }
    room.lastReceivedAt.set(fix.handle, now);
    const sequenceKey = JSON.stringify([fix.handle, fix.stream]);
    if (fix.seq <= (room.lastSeq.get(sequenceKey) ?? -1)) return { ok: true, dropped: true };
    const stored: LocationFix = {
      handle: fix.handle, stream: fix.stream, lat: fix.lat, lng: fix.lng,
      ...(fix.acc === undefined ? {} : { acc: fix.acc }),
      ...(fix.src === undefined ? {} : { src: fix.src }),
      ...(fix.speed === undefined ? {} : { speed: fix.speed }),
      ...(fix.heading === undefined ? {} : { heading: fix.heading }),
      at: fix.at, seq: fix.seq, receivedAt: now,
    };
    room.positions.set(fix.handle, stored);
    const recent = (room.recent.get(fix.handle) ?? []).filter((sample) => now - sample.receivedAt <= STOP_EVIDENCE_RETENTION_MS);
    recent.push(stored);
    if (recent.length > LOCATION_REFERENCE_LIMIT) recent.splice(0, recent.length - LOCATION_REFERENCE_LIMIT);
    room.recent.set(fix.handle, recent);
    room.lastSeq.set(sequenceKey, fix.seq);
    room.sharing.add(fix.handle);
    const trail = room.trails.get(fix.handle);
    if (trail) {
      trail.push(stored);
      if (trail.length > LOCATION_TRAIL_LIMIT) trail.splice(0, trail.length - LOCATION_TRAIL_LIMIT);
    }
    room.revision++;
    this.emit("accepted", { code, fix: { ...stored } });
    return { ok: true, dropped: false };
  }

  snapshot(code: string, requester?: string): LocationSnapshot {
    const room = this.#rooms.get(code);
    const now = this.#now();
    const fresh = (fix: LocationFix) => now - fix.receivedAt < LOCATION_STALE_MS;
    const target = requester === undefined ? undefined : this.targetOf(code, requester);
    return {
      positions: [...(room?.positions.values() ?? [])].filter(fresh).map((fix) => ({ ...fix })),
      trails: Object.fromEntries([...(room?.trails ?? [])]
        .filter(([handle]) => (target === undefined || target === handle)
          && (!room?.positions.has(handle) || fresh(room.positions.get(handle)!)))
        .map(([handle, points]) => [handle, points.map((fix) => ({ ...fix }))])),
    };
  }

  stale(): { code: string; handle: string }[] {
    const expired: { code: string; handle: string }[] = [];
    for (const [code, room] of this.#rooms) {
      for (const fix of room.positions.values()) {
        if (this.#now() - fix.receivedAt >= LOCATION_STALE_MS) expired.push({ code, handle: fix.handle });
      }
    }
    return expired;
  }

  codesFor(handle: string): string[] {
    return [...this.#rooms].filter(([, room]) => room.sharing.has(handle)
      || room.disconnectedAt.has(handle) || room.accepted.has(handle) || room.pendingRequests.has(handle)
      || this.#requestsForRoom(room, handle)).map(([code]) => code);
  }

  #requestsForRoom(room: RoomLocations, handle: string): boolean {
    return [...room.accepted.values(), ...room.pendingRequests.values()].some((r) => r.target === handle);
  }

  position(code: string, handle: string): LocationFix | undefined {
    const fix = this.#rooms.get(code)?.positions.get(handle);
    return fix && this.#now() - fix.receivedAt < LOCATION_STALE_MS ? { ...fix } : undefined;
  }

  recentSample(code: string, handle: string, ref: SampleRef): LocationFix | undefined {
    // Route origins still expire at 10 s. Looking one up must not trim the
    // longer stop evidence used by editing and wait arrival.
    const fix = this.#rooms.get(code)?.recent.get(handle)?.find((fix) => fix.stream === ref.stream && fix.seq === ref.seq
      && this.#now() - fix.receivedAt <= LOCATION_REFERENCE_AGE_MS);
    return fix ? { ...fix } : undefined;
  }

  trail(code: string, handle: string): LocationFix[] {
    return (this.#rooms.get(code)?.trails.get(handle) ?? []).map((fix) => ({ ...fix }));
  }

  pruneReferences(): void {
    const now = this.#now();
    for (const room of this.#rooms.values()) for (const [handle, samples] of room.recent) {
      const recent = samples.filter((fix) => now - fix.receivedAt <= STOP_EVIDENCE_RETENTION_MS);
      if (recent.length) room.recent.set(handle, recent);
      else room.recent.delete(handle);
    }
  }

  remove(code: string, handle: string): boolean {
    // 순번은 같은 stream의 늦은 표본을 거르기 위해 방 수명 동안 보존한다.
    const room = this.#rooms.get(code);
    if (!room) return false;
    const sharing = room.sharing.delete(handle);
    const position = room.positions.delete(handle);
    const disconnected = room.disconnectedAt.delete(handle);
    room.recent.delete(handle);
    this.emit("invalidated", { code, handle } satisfies LocationInvalidation);
    if (sharing || position || disconnected) room.revision++;
    return sharing || position;
  }

  clear(code: string): void {
    this.#rooms.delete(code);
    this.emit("invalidated", { code } satisfies LocationInvalidation);
  }

  resetDevice(code: string, handle: string): void {
    const room = this.#rooms.get(code);
    if (!room) return;
    room.recent.delete(handle);
    this.emit("invalidated", { code, handle } satisfies LocationInvalidation);
    room.lastReceivedAt.delete(handle);
    room.lastFollowAt.delete(handle);
    for (const key of room.lastSeq.keys()) {
      if ((JSON.parse(key) as string[])[0] === handle) room.lastSeq.delete(key);
    }
  }
}
