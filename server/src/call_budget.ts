import { RouteError } from "./route_contract.ts";

export const DEFAULT_ROUTE_LIMITS = { accountPerMinute: 2, accountPerHour: 60, providerPerMinute: 60, providerPerHour: 1800 };
export interface BudgetLimits { accountPerMinute: number; accountPerHour: number; providerPerMinute: number; providerPerHour: number }
export interface Reservation {
  start(handle: string): void;
  release(handle: string): void;
  releaseUnused(): void;
}
interface Slot { started: boolean }

// No await between checking all accounts/global capacity and reserving it.
// Pending slots count against quota but become calls only at transport start.
export class CallBudget {
  #clock: () => number;
  #limits: BudgetLimits;
  #interval: number;
  #accounts = new Map<string, number[]>();
  #provider: number[] = [];
  #slots = new Map<string, Slot>();
  #retryAt = 0;
  constructor(options: { clock?: () => number; limits?: Partial<BudgetLimits>; defaults?: BudgetLimits; intervalMs?: number } = {}) {
    this.#clock = options.clock ?? (() => performance.now());
    const defaults = options.defaults ?? DEFAULT_ROUTE_LIMITS;
    this.#limits = { ...defaults, ...options.limits }; this.#interval = options.intervalMs ?? 30_000;
    for (const [name, value] of Object.entries(this.#limits)) if (!Number.isSafeInteger(value) || value < 1
      || value > defaults[name as keyof BudgetLimits]) throw new Error("Invalid route limit");
  }
  sweep(): void {
    const now = this.#clock();
    for (const [handle, times] of this.#accounts) {
      const recent = times.filter((at) => now - at < 3_600_000);
      if (recent.length) this.#accounts.set(handle, recent); else this.#accounts.delete(handle);
    }
    this.#provider = this.#provider.filter((at) => now - at < 3_600_000);
  }
  defer(ms: number): void { this.#retryAt = Math.max(this.#retryAt, this.#clock() + ms); }
  reserve(handles: string[]): Reservation {
    if (!handles.length || new Set(handles).size !== handles.length) throw new RouteError("INVALID_REQUEST");
    this.sweep();
    if (handles.some((h) => this.#slots.has(h))) throw new RouteError("ROUTE_IN_PROGRESS");
    const now = this.#clock(); let wait = Math.max(0, this.#retryAt - now);
    for (const handle of handles) {
      const times = this.#accounts.get(handle) ?? [];
      if (times.length) wait = Math.max(wait, times.at(-1)! + this.#interval - now);
      for (const [period, limit] of [[60_000, this.#limits.accountPerMinute], [3_600_000, this.#limits.accountPerHour]]) {
        const recent = times.filter((at) => now - at < period);
        if (recent.length >= limit) wait = Math.max(wait, recent[recent.length - limit] + period - now);
      }
    }
    const pending = [...this.#slots.values()].filter((s) => !s.started).length;
    for (const [period, limit] of [[60_000, this.#limits.providerPerMinute], [3_600_000, this.#limits.providerPerHour]]) {
      const recent = this.#provider.filter((at) => now - at < period);
      const needed = recent.length + pending + handles.length - limit;
      if (needed > 0) wait = Math.max(wait, needed <= recent.length ? recent[needed - 1] + period - now : period);
    }
    if (wait > 0) throw new RouteError("RATE_LIMITED", Math.ceil(wait));
    const owned = new Map(handles.map((handle) => [handle, { started: false }]));
    for (const [handle, slot] of owned) this.#slots.set(handle, slot);
    const release = (handle: string) => { if (this.#slots.get(handle) === owned.get(handle)) this.#slots.delete(handle); owned.delete(handle); };
    return {
      start: (handle) => {
        const slot = owned.get(handle);
        if (!slot || slot.started || this.#slots.get(handle) !== slot) throw new RouteError("CONTEXT_MISMATCH");
        slot.started = true;
        const at = this.#clock();
        this.#accounts.set(handle, [...(this.#accounts.get(handle) ?? []), at]); this.#provider.push(at);
      },
      release,
      releaseUnused: () => { for (const [handle, slot] of owned) if (!slot.started) release(handle); },
    };
  }
}
