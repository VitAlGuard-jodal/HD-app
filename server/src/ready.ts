/** Ephemeral room readiness, with a revision to reject late HTTP snapshots. */
export class RoomReadyStore {
  #rooms = new Map<string, { revision: number; ready: Set<string> }>();

  revision(code: string): number { return this.#rooms.get(code)?.revision ?? 0; }
  isReady(code: string, handle: string): boolean { return this.#rooms.get(code)?.ready.has(handle) ?? false; }

  set(code: string, handle: string, ready: boolean) {
    let room = this.#rooms.get(code);
    if (!room) {
      room = { revision: 0, ready: new Set() };
      this.#rooms.set(code, room);
    }
    if (room.ready.has(handle) !== ready) {
      if (ready) room.ready.add(handle);
      else room.ready.delete(handle);
      room.revision++;
    }
    return { handle, ready, revision: room.revision };
  }

  remove(code: string, handle: string) { return this.set(code, handle, false); }
  clear(code: string): void { this.#rooms.delete(code); }
}
