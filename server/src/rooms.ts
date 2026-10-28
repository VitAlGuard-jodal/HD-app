import { randomInt } from "node:crypto";
import { EventEmitter } from "node:events";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

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
