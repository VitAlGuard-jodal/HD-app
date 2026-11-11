export interface LocationFix {
  handle: string;
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
  trail: { handle: string; points: LocationFix[] } | null;
}

type Acceptance = { ok: false; reason: "invalid" | "rate" } | { ok: true; dropped: boolean };
interface RoomLocations {
  positions: Map<string, LocationFix>;
  trail: LocationSnapshot["trail"];
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
    && finite(fix.lat) && fix.lat >= -90 && fix.lat <= 90
    && finite(fix.lng) && fix.lng >= -180 && fix.lng <= 180
    && (fix.acc === undefined || finite(fix.acc) && fix.acc >= 0)
    && (fix.speed === undefined || finite(fix.speed) && fix.speed >= 0)
    && (fix.heading === undefined || finite(fix.heading) && fix.heading >= 0 && fix.heading <= 360)
    && finite(fix.at) && Number.isInteger(fix.seq) && (fix.seq as number) >= 0;
}

export class RoomLocationStore {
  #rooms = new Map<string, RoomLocations>();

  accept(code: string, fix: unknown, leaderHandle: string, now = Date.now()): Acceptance {
    if (!valid(fix) || !finite(now)) return { ok: false, reason: "invalid" };
    let room = this.#rooms.get(code);
    if (!room) {
      room = { positions: new Map(), trail: null, lastSeq: new Map(), lastReceivedAt: new Map() };
      this.#rooms.set(code, room);
    }
    const lastReceivedAt = room.lastReceivedAt.get(fix.handle);
    if (lastReceivedAt !== undefined && now - lastReceivedAt < LOCATION_MIN_INTERVAL_MS) {
      return { ok: false, reason: "rate" };
    }
    room.lastReceivedAt.set(fix.handle, now);
    if (fix.seq <= (room.lastSeq.get(fix.handle) ?? -1)) return { ok: true, dropped: true };

    const stored: LocationFix = {
      handle: fix.handle, lat: fix.lat, lng: fix.lng,
      ...(fix.acc === undefined ? {} : { acc: fix.acc }),
      ...(fix.speed === undefined ? {} : { speed: fix.speed }),
      ...(fix.heading === undefined ? {} : { heading: fix.heading }),
      at: fix.at, seq: fix.seq, receivedAt: now,
    };
    room.positions.set(fix.handle, stored);
    room.lastSeq.set(fix.handle, fix.seq);
    if (fix.handle === leaderHandle) {
      room.trail ??= { handle: leaderHandle, points: [] };
      room.trail.points.push(stored);
      if (room.trail.points.length > LOCATION_TRAIL_LIMIT) {
        room.trail.points.splice(0, room.trail.points.length - LOCATION_TRAIL_LIMIT);
      }
    }
    return { ok: true, dropped: false };
  }

  snapshot(code: string): LocationSnapshot {
    const room = this.#rooms.get(code);
    return {
      positions: [...(room?.positions.values() ?? [])].map((fix) => ({ ...fix })),
      trail: room?.trail ? {
        handle: room.trail.handle, points: room.trail.points.map((fix) => ({ ...fix })),
      } : null,
    };
  }

  position(code: string, handle: string): LocationFix | undefined {
    const fix = this.#rooms.get(code)?.positions.get(handle);
    return fix ? { ...fix } : undefined;
  }

  remove(code: string, handle: string): boolean {
    // 중지·일시 단절에도 궤적과 순번은 방의 수명 동안 보존한다.
    return this.#rooms.get(code)?.positions.delete(handle) ?? false;
  }

  clear(code: string): void {
    this.#rooms.delete(code);
  }
}
