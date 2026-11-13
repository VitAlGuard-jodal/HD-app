import { randomInt } from "node:crypto";
import { EventEmitter } from "node:events";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export const SIGNAL_BACKLOG_TTL_MS = 60_000;
export const SIGNAL_BACKLOG_LIMIT = 64;
const SIGNAL_BACKLOG_SWEEP_INTERVAL_MS = 30_000;

export function generateRoomCode(): string {
  return Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join("");
}

type SendEvent = (name: string, data: unknown) => boolean | void;
interface Subscriber {
  handle: string;
  tokenHash: string;
  device: string;
  send: SendEvent;
  close: () => void;
}

export class RoomEventHub extends EventEmitter {
  #subscribers = new Map<string, Set<Subscriber>>();
  #senders = new Map<string, Map<string, { device: string; tokenHash: string }>>();
  #backlog = new Map<string, Map<string, { at: number; name: string; data: unknown }[]>>();
  #sweepTimer = setInterval(() => this.#sweepSignals(), SIGNAL_BACKLOG_SWEEP_INTERVAL_MS).unref();

  // Explicit entry may replace an owner; resume may claim only a vacant slot.
  // Socket loss never releases ownership, so stale retries cannot take it back.
  claim(code: string, handle: string, device: string, tokenHash: string): void {
    let senders = this.#senders.get(code);
    if (!senders) { senders = new Map(); this.#senders.set(code, senders); }
    const previous = senders.get(handle);
    if (previous?.device === device) return;
    senders.set(handle, { device, tokenHash });
    if (previous) {
      this.clearPeerSignals(code, handle);
      for (const subscriber of [...(this.#subscribers.get(code) ?? [])]) {
        if (subscriber.handle !== handle || subscriber.device === device) continue;
        try { subscriber.send("device-replaced", { handle }); } catch { /* close below */ }
        this.#disconnect(code, subscriber);
      }
      this.emit("sender-changed", { code, handle });
      this.broadcastExcept(code, handle, "member-device-changed", { handle });
    }
  }

  isSender(code: string, handle: string, device: string): boolean {
    return this.#senders.get(code)?.get(handle)?.device === device;
  }

  hasSender(code: string, handle: string): boolean {
    return this.#senders.get(code)?.has(handle) ?? false;
  }

  forgetSender(code: string, handle: string): void {
    const senders = this.#senders.get(code);
    senders?.delete(handle);
    if (senders?.size === 0) this.#senders.delete(code);
    this.clearPeerSignals(code, handle);
  }

  subscribe(code: string, handle: string, tokenHash: string, send: SendEvent, close: () => void = () => {}, device = tokenHash): () => void {
    this.claim(code, handle, device, tokenHash);
    let subscribers = this.#subscribers.get(code);
    if (!subscribers) {
      subscribers = new Set();
      this.#subscribers.set(code, subscribers);
    }
    const subscriber = { handle, tokenHash, device, send, close };
    subscribers.add(subscriber);
    this.emit("subscribed", { code, handle });
    return () => this.#remove(code, subscriber);
  }

  subscriberCount(code: string, handle?: string): number {
    const subscribers = this.#subscribers.get(code);
    return handle === undefined ? subscribers?.size ?? 0
      : [...(subscribers ?? [])].filter((subscriber) => subscriber.handle === handle).length;
  }

  broadcast(code: string, name: string, data: unknown): number {
    return this.#deliver(code, () => true, name, data);
  }

  broadcastExcept(code: string, handle: string, name: string, data: unknown): number {
    return this.#deliver(code, (subscriber) => subscriber.handle !== handle, name, data);
  }

  sendTo(code: string, handle: string, name: string, data: unknown): boolean {
    if (name === "signal") {
      // Even overlapping SSE sockets of the SAME device get only one copy.
      const receiver = [...(this.#subscribers.get(code) ?? [])].reverse().find(
        (s) => s.handle === handle && this.isSender(code, handle, s.device),
      );
      return receiver !== undefined && this.#deliver(code, (s) => s === receiver, name, data) > 0;
    }
    return this.#deliver(code, (subscriber) => subscriber.handle === handle, name, data) > 0;
  }

  followResponse(code: string, requestId: string, requester: string, target: string, accepted: boolean, revision: number, reason?: string): void {
    this.sendTo(code, requester, "follow-response", { requestId, requester, target, accepted, revision, ...(reason ? { reason } : {}) });
  }

  queueSignal(code: string, handle: string, name: string, data: unknown, now = Date.now()): void {
    let backlog = this.#backlog.get(code);
    if (!backlog) {
      backlog = new Map();
      this.#backlog.set(code, backlog);
    }
    const signals = (backlog.get(handle) ?? []).filter((signal) => now - signal.at <= SIGNAL_BACKLOG_TTL_MS);
    signals.push({ at: now, name, data });
    if (signals.length > SIGNAL_BACKLOG_LIMIT) signals.splice(0, signals.length - SIGNAL_BACKLOG_LIMIT);
    backlog.set(handle, signals);
  }

  replaySignals(code: string, handle: string, send: SendEvent, now = Date.now()): number {
    const backlog = this.#backlog.get(code);
    if (!backlog) return 0;
    const signals = (backlog.get(handle) ?? []).filter((signal) => now - signal.at <= SIGNAL_BACKLOG_TTL_MS);
    if (signals.length === 0) {
      this.clearSignals(code, handle);
      return 0;
    }
    backlog.set(handle, signals);
    let delivered = 0;
    for (const { name, data } of signals) {
      if (send(name, data) === false) break;
      delivered += 1;
    }
    return delivered;
  }

  clearSignals(code: string, handle?: string): void {
    if (handle === undefined) {
      this.#backlog.delete(code);
      return;
    }
    const backlog = this.#backlog.get(code);
    backlog?.delete(handle);
    if (backlog?.size === 0) this.#backlog.delete(code);
  }

  clearPeerSignals(code: string, handle: string): void {
    this.clearSignals(code, handle);
    const backlog = this.#backlog.get(code);
    for (const [recipient, signals] of backlog ?? []) {
      const retained = signals.filter((signal) => (signal.data as { from?: string } | null)?.from !== handle);
      if (retained.length) backlog!.set(recipient, retained);
      else backlog!.delete(recipient);
    }
    if (backlog?.size === 0) this.#backlog.delete(code);
  }

  clearRoom(code: string): void {
    this.#senders.delete(code);
    this.clearSignals(code);
  }

  disconnectUser(code: string, handle: string): void {
    for (const subscriber of [...(this.#subscribers.get(code) ?? [])]) {
      if (subscriber.handle === handle) this.#disconnect(code, subscriber);
    }
  }

  disconnectToken(tokenHash: string): void {
    // 로그아웃한 토큰의 모든 방 연결을 닫되 다른 기기의 토큰은 유지한다.
    for (const [code, subscribers] of [...this.#subscribers]) {
      for (const subscriber of [...subscribers]) {
        if (subscriber.tokenHash === tokenHash) this.#disconnect(code, subscriber);
      }
    }
    for (const [code, senders] of [...this.#senders]) {
      for (const [handle, sender] of [...senders]) {
        if (sender.tokenHash === tokenHash) {
          this.forgetSender(code, handle);
          this.emit("sender-revoked", { code, handle });
        }
      }
    }
  }

  close(): void {
    this.emit("closing");
    clearInterval(this.#sweepTimer);
    for (const [code, subscribers] of [...this.#subscribers]) {
      for (const subscriber of [...subscribers]) this.#disconnect(code, subscriber);
    }
    this.#backlog.clear();
    this.#senders.clear();
  }

  #sweepSignals(): void {
    const now = Date.now();
    for (const [code, backlog] of this.#backlog) {
      for (const [handle, queued] of backlog) {
        const signals = queued.filter((signal) => now - signal.at <= SIGNAL_BACKLOG_TTL_MS);
        if (signals.length === 0) backlog.delete(handle);
        else backlog.set(handle, signals);
      }
      if (backlog.size === 0) this.#backlog.delete(code);
    }
  }

  #remove(code: string, subscriber: Subscriber): void {
    const subscribers = this.#subscribers.get(code);
    if (!subscribers?.delete(subscriber)) return;
    if (subscribers.size === 0) this.#subscribers.delete(code);
    this.emit("unsubscribed", { code, handle: subscriber.handle });
  }

  #disconnect(code: string, subscriber: Subscriber): void {
    this.#remove(code, subscriber);
    try {
      subscriber.close();
    } catch {
      // 끊어진 연결의 정리 실패가 다른 참여자에게 영향을 주지 않게 한다.
    }
  }

  #deliver(code: string, matches: (subscriber: Subscriber) => boolean, name: string, data: unknown): number {
    let delivered = 0;
    for (const subscriber of [...(this.#subscribers.get(code) ?? [])]) {
      if (!matches(subscriber)) continue;
      try {
        if (subscriber.send(name, data) === false) this.#disconnect(code, subscriber);
        else delivered += 1;
      } catch {
        this.#disconnect(code, subscriber);
      }
    }
    return delivered;
  }
}
