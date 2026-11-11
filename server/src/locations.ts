export interface LocationFix {
  handle: string;
  stream: string;
  lat: number;
  lng: number;
  acc?: number;
  speed?: number;
  heading?: number;
  at: number;
  seq: number;
  receivedAt: number;
}

export const LOCATION_TRAIL_LIMIT = 7_200;
export const LOCATION_MIN_INTERVAL_MS = 400;

export interface LocationSnapshot {
  positions: LocationFix[];
  trails: Record<string, LocationFix[]>;
}

type Acceptance = { ok: false; reason: "invalid" | "rate" } | { ok: true; dropped: boolean };
interface RoomLocations {
  positions: Map<string, LocationFix>;
  trails: Map<string, LocationFix[]>;
  followers: Map<string, Set<string>>;
  pending: Map<string, string>;
  sharing: Set<string>;
  lastSeq: Map<string, number>;
  lastReceivedAt: Map<string, number>;
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
    && (fix.speed === undefined || finite(fix.speed) && fix.speed >= 0)
    && (fix.heading === undefined || finite(fix.heading) && fix.heading >= 0 && fix.heading <= 360)
    && finite(fix.at) && Number.isInteger(fix.seq) && (fix.seq as number) >= 0;
}

export class RoomLocationStore {
  #rooms = new Map<string, RoomLocations>();

  #room(code: string): RoomLocations {
    let room = this.#rooms.get(code);
    if (!room) {
      room = { positions: new Map(), trails: new Map(), followers: new Map(),
        pending: new Map(), sharing: new Set(), lastSeq: new Map(), lastReceivedAt: new Map() };
      this.#rooms.set(code, room);
    }
    return room;
  }

  targetOf(code: string, requester: string): string | null {
    for (const [target, followers] of this.#rooms.get(code)?.followers ?? []) {
      if (followers.has(requester)) return target;
    }
    return null;
  }

  requestsFor(code: string, target: string): string[] {
    return [...(this.#rooms.get(code)?.pending ?? [])]
      .filter(([, handle]) => handle === target).map(([requester]) => requester);
  }

  requestFollow(code: string, requester: string, target: string): boolean {
    if (this.targetOf(code, requester) !== target) this.unfollow(code, requester);
    const room = this.#room(code);
    let followers = room.followers.get(target);
    if (!followers) {
      followers = new Set();
      room.followers.set(target, followers);
      const current = room.positions.get(target);
      room.trails.set(target, current ? [current] : []);
    }
    followers.add(requester);
    const accepted = room.sharing.has(target);
    if (accepted) room.pending.delete(requester);
    else room.pending.set(requester, target);
    return accepted;
  }

  respondFollow(code: string, target: string, requester: string, accepted: boolean): string[] | null {
    const room = this.#rooms.get(code);
    if (room?.pending.get(requester) !== target) return null;
    if (!accepted) {
      this.unfollow(code, requester);
      return [requester];
    }
    // start() 이후 첫 GPS 표본이 오기 전에도 같은 세션의 공유 동의를 기억한다.
    room.sharing.add(target);
    const requesters = this.requestsFor(code, target);
    for (const handle of requesters) room.pending.delete(handle);
    return requesters;
  }

  unfollow(code: string, requester: string): string | null {
    const room = this.#rooms.get(code);
    const target = this.targetOf(code, requester);
    room?.pending.delete(requester);
    if (room && target) {
      const followers = room.followers.get(target)!;
      followers.delete(requester);
      if (followers.size === 0) {
        room.followers.delete(target);
        room.trails.delete(target);
      }
    }
    return target;
  }

  removeFollows(code: string, handle: string): { target: string | null; requesters: string[] } {
    const target = this.unfollow(code, handle);
    const room = this.#rooms.get(code);
    const requesters = [...(room?.followers.get(handle) ?? [])];
    for (const requester of requesters) this.unfollow(code, requester);
    return { target, requesters };
  }

  accept(code: string, fix: unknown, now = Date.now()): Acceptance {
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
      ...(fix.speed === undefined ? {} : { speed: fix.speed }),
      ...(fix.heading === undefined ? {} : { heading: fix.heading }),
      at: fix.at, seq: fix.seq, receivedAt: now,
    };
    room.positions.set(fix.handle, stored);
    room.lastSeq.set(sequenceKey, fix.seq);
    room.sharing.add(fix.handle);
    const trail = room.trails.get(fix.handle);
    if (trail) {
      trail.push(stored);
      if (trail.length > LOCATION_TRAIL_LIMIT) trail.splice(0, trail.length - LOCATION_TRAIL_LIMIT);
    }
    return { ok: true, dropped: false };
  }

  snapshot(code: string): LocationSnapshot {
    const room = this.#rooms.get(code);
    return {
      positions: [...(room?.positions.values() ?? [])].map((fix) => ({ ...fix })),
      trails: Object.fromEntries([...(room?.trails ?? [])]
        .map(([handle, points]) => [handle, points.map((fix) => ({ ...fix }))])),
    };
  }

  position(code: string, handle: string): LocationFix | undefined {
    const fix = this.#rooms.get(code)?.positions.get(handle);
    return fix ? { ...fix } : undefined;
  }

  remove(code: string, handle: string): boolean {
    // 순번은 같은 stream의 늦은 표본을 거르기 위해 방 수명 동안 보존한다.
    const room = this.#rooms.get(code);
    room?.sharing.delete(handle);
    return room?.positions.delete(handle) ?? false;
  }

  clear(code: string): void {
    this.#rooms.delete(code);
  }
}
