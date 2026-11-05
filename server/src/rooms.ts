import { randomInt } from "node:crypto";
import { EventEmitter } from "node:events";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export const SIGNAL_BACKLOG_TTL_MS = 60_000;
export const SIGNAL_BACKLOG_LIMIT = 64;

export function generateRoomCode(): string {
  return Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join("");
}

type SendEvent = (name: string, data: unknown) => boolean | void;
interface Subscriber {
  handle: string;
  tokenHash: string;
  send: SendEvent;
  close: () => void;
}

export class RoomEventHub extends EventEmitter {
  #subscribers = new Map<string, Set<Subscriber>>();
  #backlog = new Map<string, Map<string, { at: number; name: string; data: unknown }[]>>();

  subscribe(code: string, handle: string, tokenHash: string, send: SendEvent, close: () => void = () => {}): () => void {
    let subscribers = this.#subscribers.get(code);
    if (!subscribers) {
      subscribers = new Set();
      this.#subscribers.set(code, subscribers);
    }
    const subscriber = { handle, tokenHash, send, close };
    subscribers.add(subscriber);
    this.emit("subscribed", { code, handle });
    return () => this.#remove(code, subscriber);
  }

  subscriberCount(code: string): number {
    return this.#subscribers.get(code)?.size ?? 0;
  }

  broadcast(code: string, name: string, data: unknown): number {
    return this.#deliver(code, () => true, name, data);
  }

  sendTo(code: string, handle: string, name: string, data: unknown): boolean {
    return this.#deliver(code, (subscriber) => subscriber.handle === handle, name, data) > 0;
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
  }

  close(): void {
    for (const [code, subscribers] of [...this.#subscribers]) {
      for (const subscriber of [...subscribers]) this.#disconnect(code, subscriber);
    }
    this.#backlog.clear();
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
