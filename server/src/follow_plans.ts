import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { LocationFix, LocationInvalidation, RoomLocationStore } from "./locations.ts";
import { context, continuous, recordedTraceContinuous, fresh, quality, stopped, STOP_EVIDENCE_MIN_SAMPLES, STOP_EVIDENCE_MIN_SPAN_MS } from "./location_quality.ts";
import { canonicalJson, distance, RouteError, sameRef } from "./route_contract.ts";
import type { PlanRouteRequest, Point, RouteAnchor, SampleRef } from "./route_contract.ts";
import { parseDeletePlan, parseDepart, parseGuidanceStatus, parseParticipation, parsePassEvidence, parseSavePlan } from "./follow_plan_contract.ts";
import type { FollowPlan, PlanRuntime, PlanSnapshot, PlanVehicle, RecommendRequest } from "./follow_plan_contract.ts";

interface Evidence {
  since: number; first: SampleRef | null; waitingFix?: LocationFix; movingFrom?: SampleRef;
  pendingPassAt?: number; pendingPassClock?: number;
  nearJoin?: boolean;
}
interface Entry {
  plan: FollowPlan; runtime: PlanRuntime; evidence: Map<string, Evidence>;
  announcedClock?: number; orderTimer?: ReturnType<typeof setTimeout>;
}
interface Operation { fingerprint: string; planId: string; deleted: boolean; until: number; code: string; handle: string }
export interface PlanOptions {
  now?: () => number; monotonicNow?: () => number;
  // The application supplies persisted consent, membership and active-sender checks.
  eligible: (code: string, handle: string) => boolean;
}
function sampleRef(fix: SampleRef): SampleRef { return { stream: fix.stream, seq: fix.seq }; }
function vehicle(handle: string, followRequestId: string | null, phase: PlanVehicle["phase"]): PlanVehicle {
  return { handle, followRequestId, phase, branch: "pending", arrivedAtMs: null, passedAtMs: null,
    condition: null, reportedStage: null, etaSeconds: null, calculatedAtMs: null };
}
function runtime(plan: FollowPlan): PlanRuntime {
  return { planId: plan.planId, revision: plan.revision, runtimeRevision: 0, phase: "idle", enrollments: [],
    vehicles: [vehicle(plan.leaderHandle, null, "toJoin")], leaderPassRef: null, traceStartRef: null,
    departureCohort: null, departureAnnouncedAtMs: null, departedAtMs: null };
}
function key(code: string, leader: string): string { return JSON.stringify([code, leader]); }
function destinationOnly(plan: FollowPlan): boolean {
  // Only coincident user-confirmed pins are destinationOnly. The 100 m rule is
  // measured along the recommended route, never between arbitrary manual pins.
  return !!plan.joinPoint && distance(plan.destination, plan.joinPoint) <= 1;
}
export function segmentProjection(a: Point, b: Point, p: Point): { fraction: number; distance: number } {
  const k = Math.cos(p.lat * Math.PI / 180);
  const x = (b.lng - a.lng) * k, y = b.lat - a.lat;
  const fraction = x === 0 && y === 0 ? 0 : Math.max(0, Math.min(1, ((p.lng - a.lng) * k * x + (p.lat - a.lat) * y) / (x * x + y * y)));
  return { fraction, distance: distance(p, { lat: a.lat + y * fraction, lng: a.lng + (b.lng - a.lng) * fraction }) };
}

export class FollowPlanService extends EventEmitter {
  #locations: RoomLocationStore;
  #options: PlanOptions;
  #now: () => number;
  #clock: () => number;
  #entries = new Map<string, Entry>();
  #operations = new Map<string, Operation>();
  #participantLists = new Map<string, { code: string; fingerprint: string }>();
  #closed = false;
  #accepted: (event: { code: string; fix: LocationFix }) => void;
  #invalidated: (event: LocationInvalidation) => void;
  #relations: (event: { code: string; target: string }) => void;

  constructor(locations: RoomLocationStore, options: PlanOptions) {
    super();
    this.#locations = locations; this.#options = options;
    this.#now = options.now ?? (() => Date.now()); this.#clock = options.monotonicNow ?? (() => performance.now());
    for (const { code, target } of locations.acceptedFollowerTargets()) this.#participantsChanged(code, target);
    this.#accepted = ({ code }) => this.sweep(code);
    this.#invalidated = (event) => {
      if (!event.handle && !event.requester) {
        for (const [id, list] of this.#participantLists) if (list.code === event.code) this.#participantLists.delete(id);
      }
      for (const entry of [...this.#entries.values()]) {
        if (entry.plan.roomCode !== event.code) continue;
        if (!event.handle && !event.requester || event.handle === entry.plan.leaderHandle) this.#clear(entry, "locationEnded");
        else {
          if (event.handle && entry.runtime.enrollments.some((e) => e.handle === event.handle)) {
            this.#unenroll(entry, event.handle); this.#changed(entry);
          }
          this.#refresh(entry);
        }
      }
      for (const [id, op] of this.#operations) if (op.code === event.code
        && (!event.handle && !event.requester || op.handle === (event.handle ?? event.requester))) this.#operations.delete(id);
    };
    this.#relations = ({ code, target }) => {
      const entry = this.#entries.get(key(code, target));
      if (entry) this.#refresh(entry);
      if (this.#participantsChanged(code, target)) {
        this.emit("participants-changed", { code, leaderHandle: target, participants: this.participants(code, target) });
      }
    };
    locations.on("accepted", this.#accepted);
    locations.on("invalidated", this.#invalidated);
    locations.on("relations-changed", this.#relations);
  }
  feature() { return { enabled: !this.#closed }; }
  #participantsChanged(code: string, leader: string): boolean {
    const id = key(code, leader);
    // Relation notifications include pending requests. Compare accepted identities,
    // not transient readiness, and treat an unseen/empty group as unchanged.
    const followers = this.#locations.acceptedFollowersOf(code, leader).sort((a, b) => a.requester.localeCompare(b.requester));
    const fingerprint = JSON.stringify(followers);
    if ((this.#participantLists.get(id)?.fingerprint ?? "[]") === fingerprint) return false;
    if (followers.length) this.#participantLists.set(id, { code, fingerprint });
    else this.#participantLists.delete(id);
    return true;
  }
  participants(code: string, leader: string) {
    return this.#locations.acceptedFollowersOf(code, leader).map((r) => {
      const sharing = this.#locations.isSharing(code, r.requester);
      const locationReady = sharing && fresh(this.#locations.position(code, r.requester), this.#now());
      const consentReady = this.#options.eligible(code, r.requester);
      return { followRequestId: r.requestId, handle: r.requester, displayName: r.displayName,
        sharing, locationReady, consentReady, ready: locationReady && consentReady };
    });
  }
  readers(code: string, leader: string): string[] {
    return [leader, ...this.#locations.acceptedFollowersOf(code, leader).map((r) => r.requester)];
  }
  #readable(code: string, leader: string, requester: string): void {
    if (requester !== leader && this.#locations.targetOf(code, requester) !== leader) throw new RouteError("PLAN_NOT_PARTICIPANT");
  }
  get(code: string, leader: string, requester: string): PlanSnapshot {
    this.#readable(code, leader, requester);
    const entry = this.#entries.get(key(code, leader));
    if (entry) this.#refresh(entry);
    return this.#snapshot(this.#entries.get(key(code, leader)));
  }
  snapshots(code: string, requester: string): PlanSnapshot[] {
    const leaders = new Set([requester, this.#locations.targetOf(code, requester)].filter((x): x is string => !!x));
    return [...leaders].map((leader) => this.get(code, leader, requester)).filter((s) => s.plan !== null);
  }
  #snapshot(entry?: Entry): PlanSnapshot {
    return { plan: entry ? structuredClone(entry.plan) : null, runtime: entry ? structuredClone(entry.runtime) : null, serverNowMs: this.#now() };
  }
  #usable(code: string, handle: string): LocationFix {
    if (!this.#options.eligible(code, handle)) throw new RouteError("CONSENT_REQUIRED_SELF");
    const fix = this.#locations.position(code, handle);
    if (!this.#locations.isSharing(code, handle) || !fresh(fix, this.#now())) throw new RouteError("LOCATION_NOT_READY");
    return fix;
  }
  assertEditable(code: string, handle: string): void {
    if (this.#closed) throw new RouteError("PLAN_NOT_READY");
    this.#usable(code, handle);
    if (!stopped(this.#window(this.#locations.recentSamples(code, handle)), this.#now())) throw new RouteError("STOP_REQUIRED");
  }
  #window(samples: LocationFix[]): LocationFix[] {
    if (!samples.length) return [];
    let start = samples.length - 1;
    while (start > 0 && (samples.length - start < STOP_EVIDENCE_MIN_SAMPLES
      || samples.at(-1)!.at - samples[start].at < STOP_EVIDENCE_MIN_SPAN_MS
      || samples.at(-1)!.receivedAt - samples[start].receivedAt < STOP_EVIDENCE_MIN_SPAN_MS)) {
      if (!continuous(samples[start - 1], samples[start])) break;
      start--;
    }
    return samples.slice(start);
  }
  #checkSelection(code: string, leader: string, ids: string[]): void {
    const accepted = new Set(this.#locations.acceptedFollowersOf(code, leader).map((r) => r.requestId));
    if (ids.some((id) => !accepted.has(id))) throw new RouteError("PLAN_NOT_PARTICIPANT");
  }
  #entry(code: string, leader: string, planId: string, revision: number): Entry {
    const entry = this.#entries.get(key(code, leader));
    if (!entry || entry.plan.planId !== planId || entry.plan.revision !== revision) throw new RouteError("PLAN_CHANGED");
    return entry;
  }
  #operation(code: string, handle: string, operationId: string, input: unknown): Operation | undefined {
    const operation = this.#operations.get(key(key(code, handle), operationId));
    if (!operation || this.#clock() >= operation.until) return undefined;
    if (operation.fingerprint !== canonicalJson(input)) throw new RouteError("CONTEXT_MISMATCH");
    return operation;
  }
  #remember(code: string, handle: string, operationId: string, input: unknown, planId: string, deleted = false): void {
    for (const [id, op] of this.#operations) if (this.#clock() >= op.until) this.#operations.delete(id);
    const own = [...this.#operations].filter(([, op]) => op.code === code && op.handle === handle);
    if (own.length >= 128) this.#operations.delete(own[0][0]);
    this.#operations.set(key(key(code, handle), operationId), { fingerprint: canonicalJson(input), code, handle, planId, deleted, until: this.#clock() + 120_000 });
  }
  #replay(code: string, leader: string, operation: Operation): PlanSnapshot {
    const entry = this.#entries.get(key(code, leader));
    if (operation.deleted ? !!entry : entry?.plan.planId !== operation.planId) throw new RouteError("PLAN_CHANGED");
    return this.#snapshot(entry);
  }
  #changed(entry: Entry, event = "follow-plan-progress"): void {
    entry.runtime.runtimeRevision++;
    this.emit("change", { code: entry.plan.roomCode, leaderHandle: entry.plan.leaderHandle, event,
      data: event === "follow-plan-updated" ? this.#snapshot(entry) : { planId: entry.plan.planId,
        revision: entry.plan.revision, runtimeRevision: entry.runtime.runtimeRevision,
        runtime: structuredClone(entry.runtime), serverNowMs: this.#now() } });
  }
  #clear(entry: Entry, reason: string): void {
    this.#entries.delete(key(entry.plan.roomCode, entry.plan.leaderHandle));
    clearTimeout(entry.orderTimer);
    this.emit("invalidated", { code: entry.plan.roomCode, planId: entry.plan.planId, leaderHandle: entry.plan.leaderHandle });
    this.emit("change", { code: entry.plan.roomCode, leaderHandle: entry.plan.leaderHandle, event: "follow-plan-cleared",
      data: { planId: entry.plan.planId, leaderHandle: entry.plan.leaderHandle, revision: entry.plan.revision, reason } });
  }
  save(code: string, leader: string, raw: unknown): PlanSnapshot {
    const input = parseSavePlan(raw);
    const replay = this.#operation(code, leader, input.operationId, input);
    if (replay) return this.#replay(code, leader, replay);
    this.assertEditable(code, leader);
    let entry = this.#entries.get(key(code, leader));
    if (input.expectedPlanId === null ? !!entry : !entry || entry.plan.planId !== input.expectedPlanId || entry.plan.revision !== input.expectedRevision) throw new RouteError("PLAN_CHANGED");
    if (entry?.runtime.enrollments.length) throw new RouteError("PLAN_LOCKED");
    this.#checkSelection(code, leader, input.participantFollowRequestIds);
    const changedDestination = !!entry && canonicalJson(entry.plan.destination) !== canonicalJson(input.destination);
    const joinPoint = changedDestination ? null : input.joinPoint;
    const plan: FollowPlan = { planId: entry?.plan.planId ?? randomUUID(), leaderHandle: leader, roomCode: code,
      revision: (entry?.plan.revision ?? 0) + 1, destination: input.destination, joinPoint, policy: input.policy,
      participantFollowRequestIds: input.participantFollowRequestIds, waitingPlaceConfirmed: !changedDestination && input.waitingPlaceConfirmed,
      createdAtMs: entry?.plan.createdAtMs ?? this.#now(), updatedAtMs: this.#now(),
      status: joinPoint && (input.policy === "proceed" || input.waitingPlaceConfirmed) ? "ready" : "draft" };
    if (entry) clearTimeout(entry.orderTimer);
    this.emit("invalidated", { code, planId: entry?.plan.planId ?? plan.planId, leaderHandle: leader });
    entry = { plan, runtime: runtime(plan), evidence: new Map() };
    this.#entries.set(key(code, leader), entry);
    this.#syncInvites(entry);
    this.#remember(code, leader, input.operationId, input, plan.planId);
    this.#changed(entry, "follow-plan-updated");
    return this.#snapshot(entry);
  }
  remove(code: string, leader: string, raw: unknown): PlanSnapshot {
    const input = parseDeletePlan(raw);
    const replay = this.#operation(code, leader, input.operationId, input);
    if (replay) return this.#replay(code, leader, replay);
    this.assertEditable(code, leader);
    const entry = this.#entry(code, leader, input.planId, input.expectedRevision);
    this.#clear(entry, "cancelled");
    this.#remember(code, leader, input.operationId, input, input.planId, true);
    return this.#snapshot();
  }
  #begin(entry: Entry, handle: string): void {
    const current = this.#locations.position(entry.plan.roomCode, handle);
    entry.evidence.set(handle, { since: this.#now(), first: current ? sampleRef(current) : null });
  }
  participate(code: string, leader: string, requester: string, raw: unknown): PlanSnapshot {
    const input = parseParticipation(raw);
    const replay = this.#operation(code, requester, input.operationId, input);
    if (replay) return this.#replay(code, leader, replay);
    this.assertEditable(code, requester);
    const entry = this.#entry(code, leader, input.planId, input.planRevision);
    this.#relation(entry, requester, input.followRequestId, false);
    this.#usable(code, leader);
    this.#refresh(entry);
    const r = entry.runtime;
    const enrolled = r.enrollments.some((e) => e.followRequestId === input.followRequestId);
    if (input.enabled && !enrolled) {
      if (entry.plan.status !== "ready") throw new RouteError("PLAN_NOT_READY");
      if (r.departedAtMs !== null || r.departureCohort || r.vehicles.some((v) => v.passedAtMs !== null)) throw new RouteError("PLAN_DEPARTED");
      if (!entry.plan.participantFollowRequestIds.includes(input.followRequestId)) throw new RouteError("PLAN_NOT_PARTICIPANT");
      if (!r.enrollments.length && r.phase === "idle") { r.phase = "approaching"; this.#begin(entry, leader); }
      r.enrollments.push({ handle: requester, followRequestId: input.followRequestId });
      const v = r.vehicles.find((v) => v.handle === requester)!;
      Object.assign(v, vehicle(requester, input.followRequestId, "toJoin"));
      this.#begin(entry, requester);
    } else if (!input.enabled && enrolled) this.#unenroll(entry, requester);
    this.#remember(code, requester, input.operationId, input, entry.plan.planId);
    if (enrolled !== input.enabled) { this.#unprepare(entry); this.#changed(entry); }
    return this.#snapshot(entry);
  }
  #relation(entry: Entry, requester: string, followRequestId: string | null, requireEnrollment = true): void {
    if (requester === entry.plan.leaderHandle) {
      if (followRequestId !== null) throw new RouteError("PLAN_NOT_OWNER");
      return;
    }
    const relation = this.#locations.relationOf(entry.plan.roomCode, requester);
    if (!followRequestId || relation?.requestId !== followRequestId || this.#locations.targetOf(entry.plan.roomCode, requester) !== entry.plan.leaderHandle
      || requireEnrollment && !entry.runtime.enrollments.some((e) => e.handle === requester && e.followRequestId === followRequestId)) {
      throw new RouteError("PLAN_NOT_PARTICIPANT");
    }
  }
  #syncInvites(entry: Entry): void {
    const accepted = this.#locations.acceptedFollowersOf(entry.plan.roomCode, entry.plan.leaderHandle);
    entry.runtime.vehicles = entry.runtime.vehicles.filter((v) => v.handle === entry.plan.leaderHandle
      || accepted.some((a) => a.requestId === v.followRequestId));
    for (const a of accepted) if (entry.plan.participantFollowRequestIds.includes(a.requestId)
      && !entry.runtime.vehicles.some((v) => v.followRequestId === a.requestId)) {
      entry.runtime.vehicles.push(vehicle(a.requester, a.requestId, "invited"));
    }
  }
  #unenroll(entry: Entry, handle: string): void {
    entry.runtime.enrollments = entry.runtime.enrollments.filter((e) => e.handle !== handle);
    const v = entry.runtime.vehicles.find((v) => v.handle === handle);
    if (v) Object.assign(v, vehicle(handle, v.followRequestId, "invited"));
    entry.evidence.delete(handle);
    this.#unprepare(entry);
    if (!entry.runtime.enrollments.length && entry.runtime.departedAtMs === null) {
      entry.runtime.phase = "idle";
      const leader = entry.runtime.vehicles.find((v) => v.handle === entry.plan.leaderHandle)!;
      Object.assign(leader, vehicle(entry.plan.leaderHandle, null, "toJoin"));
      entry.evidence.delete(entry.plan.leaderHandle);
    }
    this.emit("invalidated", { code: entry.plan.roomCode, planId: entry.plan.planId, requester: handle });
  }
  #unprepare(entry: Entry): void {
    if (entry.runtime.departedAtMs !== null) return;
    entry.runtime.departureAnnouncedAtMs = null; entry.runtime.departureCohort = null; entry.announcedClock = undefined;
  }
  #allReady(entry: Entry, leaderStarting = false): boolean {
    const r = entry.runtime;
    const handles = [entry.plan.leaderHandle, ...r.enrollments.map((e) => e.handle)];
    return r.enrollments.length > 0 && handles.every((h) => {
      const v = r.vehicles.find((v) => v.handle === h);
      const samples = this.#samples(entry, h);
      const waiting = leaderStarting && h === entry.plan.leaderHandle ? samples.slice(0, -1) : samples;
      return v?.phase === "atJoinWaiting" && v.condition === null && this.#options.eligible(entry.plan.roomCode, h)
        && fresh(this.#locations.position(entry.plan.roomCode, h), this.#now())
        && stopped(this.#window(waiting), this.#now());
    });
  }
  #prepare(entry: Entry, leaderStarting = false): void {
    const waiting = entry.evidence.get(entry.plan.leaderHandle)?.waitingFix;
    if (!waiting || !this.#allReady(entry, leaderStarting)) throw new RouteError("DEPARTURE_NOT_READY");
    entry.runtime.departureCohort = { followRequestIds: entry.runtime.enrollments.map((e) => e.followRequestId),
      runtimeRevision: entry.runtime.runtimeRevision, capturedAtMs: this.#now(), leaderWaitingRef: sampleRef(waiting) };
    entry.runtime.departureAnnouncedAtMs = this.#now(); entry.announcedClock = this.#clock();
  }
  depart(code: string, leader: string, raw: unknown): PlanSnapshot {
    const input = parseDepart(raw);
    const replay = this.#operation(code, leader, input.operationId, input);
    if (replay) return this.#replay(code, leader, replay);
    this.assertEditable(code, leader);
    const entry = this.#entry(code, leader, input.planId, input.planRevision);
    this.#refresh(entry);
    if (entry.runtime.runtimeRevision !== input.expectedRuntimeRevision) throw new RouteError("RUNTIME_CHANGED");
    if (entry.plan.policy !== "wait" || destinationOnly(entry.plan) || entry.runtime.departedAtMs !== null) throw new RouteError("DEPARTURE_NOT_READY");
    this.#prepare(entry); this.#remember(code, leader, input.operationId, input, input.planId);
    this.#changed(entry);
    return this.#snapshot(entry);
  }
  #samples(entry: Entry, handle: string): LocationFix[] {
    const evidence = entry.evidence.get(handle);
    if (!evidence) return [];
    return this.#locations.recentSamples(entry.plan.roomCode, handle).filter((s) => s.receivedAt >= evidence.since
      && (!evidence.first || s.stream !== evidence.first.stream || s.seq >= evidence.first.seq));
  }
  #traceValid(entry: Entry): boolean {
    const anchor = entry.runtime.traceStartRef;
    if (!anchor) return false;
    const trail = this.#locations.trail(entry.plan.roomCode, entry.plan.leaderHandle);
    const start = anchor.kind === "sample" ? anchor.ref : anchor.startRef;
    const index = trail.findIndex((s) => sameRef(s, start));
    if (index < 0 || !quality(trail[index])) return false;
    if (anchor.kind === "segment" && (!trail[index + 1] || !sameRef(trail[index + 1], anchor.endRef))) return false;
    return trail.slice(index + 1).every((s, i) => recordedTraceContinuous(trail[index + i], s));
  }
  #refresh(entry: Entry): void {
    const { plan, runtime: r } = entry;
    if (!this.#entries.has(key(plan.roomCode, plan.leaderHandle))) return;
    if (!this.#locations.isSharing(plan.roomCode, plan.leaderHandle) || !this.#options.eligible(plan.roomCode, plan.leaderHandle)) {
      this.#clear(entry, "ownerUnavailable"); return;
    }
    const before = JSON.stringify(r);
    for (const enrollment of [...r.enrollments]) {
      const relation = this.#locations.relationOf(plan.roomCode, enrollment.handle);
      if (relation?.requestId !== enrollment.followRequestId || this.#locations.targetOf(plan.roomCode, enrollment.handle) !== plan.leaderHandle
        || !this.#locations.isSharing(plan.roomCode, enrollment.handle) || !this.#options.eligible(plan.roomCode, enrollment.handle)) this.#unenroll(entry, enrollment.handle);
    }
    this.#syncInvites(entry);
    for (const v of r.vehicles) {
      if (v.phase === "invited") continue;
      const fix = this.#locations.position(plan.roomCode, v.handle);
      v.condition = !fix || !fresh(fix, this.#now()) ? fix && !quality(fix) ? "poorAccuracy" : "locationDelayed" : null;
      if (v.condition) { v.etaSeconds = null; v.calculatedAtMs = null; continue; }
      // Keep the calculation time after expiry so viewers can ask for a refresh.
      // Delayed/poor locations above still remove the entire ETA immediately.
      if (v.calculatedAtMs !== null && this.#now() - v.calculatedAtMs >= 60_000) v.etaSeconds = null;
    }
    if (r.departureCohort && r.departedAtMs === null && (entry.announcedClock === undefined || this.#clock() - entry.announcedClock >= 60_000
      || r.vehicles.some((v) => v.phase !== "invited" && v.condition !== null))) this.#unprepare(entry);
    if (r.phase !== "idle" && plan.joinPoint) {
      // Leader first so an automatically captured cohort refers to the instant
      // before the leader starts moving. An announced cohort survives motion.
      for (const v of r.vehicles) {
        if (v.phase === "invited" || v.phase === "completed" || v.condition) continue;
        const samples = this.#window(this.#samples(entry, v.handle));
        const motionContext = context(samples, this.#now());
        const stopEvidence = stopped(samples, this.#now());
        const current = samples.at(-1);
        if (!current) continue;
        const evidence = entry.evidence.get(v.handle)!;
        // Capture the first moving fix after a proven wait even when older
        // parked fixes are >10 s old. Actual departure below still needs the
        // unchanged, all-fresh moving context (3 samples / 2 s).
        const leavingStop = v.handle === plan.leaderHandle && !!evidence.waitingFix
          && fresh(evidence.waitingFix, this.#now()) && continuous(evidence.waitingFix, current);
        if (!motionContext && !stopEvidence && !leavingStop) {
          if (!r.departureCohort && v.phase === "atJoinWaiting") {
            v.phase = "toJoin"; v.arrivedAtMs = null;
            evidence.waitingFix = undefined; evidence.movingFrom = undefined;
          }
          continue;
        }
        if ((motionContext || stopEvidence) && plan.policy === "proceed" && (samples.some((s) => distance(s, plan.joinPoint!) <= 25)
          || samples.slice(1).some((s, i) => segmentProjection(samples[i], s, plan.joinPoint!).distance <= 25))) evidence.nearJoin = true;
        const atDestination = destinationOnly(plan) || v.phase === "toDestination" || v.branch === "trace";
        if (atDestination && (motionContext || stopEvidence) && samples.every((s) => distance(s, plan.destination) <= 25)) {
          v.phase = "completed"; v.arrivedAtMs ??= this.#now(); continue;
        }
        if (destinationOnly(plan) || plan.policy !== "wait" || r.departedAtMs !== null) continue;
        const near = distance(current, plan.joinPoint) <= 25;
        if (samples.every((s) => distance(s, plan.joinPoint!) <= 25) && stopEvidence) {
          v.phase = "atJoinWaiting"; v.arrivedAtMs ??= this.#now(); evidence.waitingFix = current; evidence.movingFrom = undefined;
          if (v.handle === plan.leaderHandle) r.phase = "waiting";
        }
        const moving = current.speed === undefined ? samples.length >= 2
          && distance(samples.at(-2)!, current) / ((current.at - samples.at(-2)!.at) / 1000) >= 2 : current.speed >= 2;
        if (v.handle === plan.leaderHandle && evidence.waitingFix && moving) {
          if (!evidence.movingFrom) {
            if (!leavingStop) continue;
            evidence.movingFrom = sampleRef(current);
            if (!r.departureCohort && this.#allReady(entry, true)) this.#prepare(entry, true);
          }
          const movement = this.#samples(entry, v.handle).filter((s) => s.stream === evidence.movingFrom!.stream && s.seq >= evidence.movingFrom!.seq);
          if (context(movement, this.#now()) && movement.every((s, i) => s.speed === undefined
            ? i === 0 || distance(movement[i - 1], s) / ((s.at - movement[i - 1].at) / 1000) >= 2 : s.speed >= 2)
            && distance(evidence.waitingFix, current) >= 30 && distance(current, plan.joinPoint) > 50) {
            if (!r.departureCohort) { r.phase = "leftEarly"; v.phase = "toJoin"; }
            else {
              r.departedAtMs = this.#now(); r.phase = "departed";
              // The cohort stays fixed at preparation; the trace starts at the
              // last actual waiting fix immediately before continuous movement.
              r.traceStartRef = { kind: "sample", ref: sampleRef(evidence.waitingFix) };
              v.phase = "toDestination"; v.branch = "destination";
              for (const follower of r.vehicles) if (r.enrollments.some((e) => e.handle === follower.handle)) {
                follower.phase = "tracePriming"; follower.branch = "trace";
              }
            }
          }
        }
        if ((!near || !stopEvidence) && !r.departureCohort && v.phase === "atJoinWaiting") { v.phase = "toJoin"; v.arrivedAtMs = null; }
      }
      this.#resolveOrder(entry);
      if (r.traceStartRef && !this.#traceValid(entry)) {
        r.phase = "traceUnavailable";
        for (const v of r.vehicles) if (v.branch === "trace" && v.phase !== "completed") v.condition = "traceUnavailable";
      }
      const active = r.vehicles.filter((v) => v.phase !== "invited");
      if (active.length && active.every((v) => v.phase === "completed")) r.phase = "completed";
    }
    for (const v of r.vehicles) {
      if (v.phase === "completed" || v.reportedStage === "toJoin" && (v.phase !== "toJoin" || v.passedAtMs !== null)
        || v.reportedStage === "toDestination" && !destinationOnly(plan) && v.branch !== "destination"
          && !(v.handle === plan.leaderHandle && r.departureAnnouncedAtMs !== null)) {
        v.reportedStage = null; v.etaSeconds = null; v.calculatedAtMs = null;
      }
    }
    if (JSON.stringify(r) !== before) this.#changed(entry);
  }
  #resolveOrder(entry: Entry): void {
    const r = entry.runtime;
    for (const v of r.vehicles) {
      const evidence = entry.evidence.get(v.handle);
      if (v.handle === entry.plan.leaderHandle || v.branch !== "pending" || evidence?.pendingPassClock === undefined) continue;
      // A short grace window uses server receipt/monotonic time, not clocks from two devices.
      if (r.leaderPassRef) { v.branch = "trace"; v.phase = "tracePriming"; }
      else if (this.#clock() - evidence.pendingPassClock >= 2000) {
        const leader = this.#locations.position(entry.plan.roomCode, entry.plan.leaderHandle);
        const leaderSamples = this.#window(this.#samples(entry, entry.plan.leaderHandle));
        const near = entry.evidence.get(entry.plan.leaderHandle)?.nearJoin || leaderSamples.some((s) => distance(s, entry.plan.joinPoint!) <= 25)
          || leaderSamples.slice(1).some((s, i) => segmentProjection(leaderSamples[i], s, entry.plan.joinPoint!).distance <= 25);
        if (fresh(leader, this.#now()) && this.#now() - leader.receivedAt <= 2000 && this.#now() - leader.at <= 2000
          && (context(leaderSamples, this.#now()) || stopped(leaderSamples, this.#now())) && !near) { v.branch = "destination"; v.phase = "toDestination"; }
      }
    }
  }
  pass(code: string, leader: string, requester: string, raw: unknown): PlanSnapshot {
    const input = parsePassEvidence(raw);
    const entry = this.#entry(code, leader, input.planId, input.revision);
    this.#relation(entry, requester, input.followRequestId);
    this.#usable(code, requester); this.#usable(code, leader); this.#refresh(entry);
    const v = entry.runtime.vehicles.find((v) => v.handle === requester)!;
    if (entry.plan.status !== "ready" || entry.runtime.phase === "idle") throw new RouteError("PLAN_NOT_READY");
    const retained = this.#samples(entry, requester);
    const indices = input.ownRefs.map((ref) => retained.findIndex((s) => sameRef(s, ref)));
    if (indices[0] < 0 || indices[1] <= indices[0] || indices[2] <= indices[1]) throw new RouteError("PASS_NOT_CONFIRMED");
    // Three evidence references may span more than three high-frequency fixes.
    // Reconstruct every intervening sample rather than permitting seq gaps.
    const points = retained.slice(indices[0], indices[2] + 1);
    if (!context(points, this.#now())) throw new RouteError("PASS_NOT_CONFIRMED");
    const current = this.#locations.position(code, requester)!;
    if (!sameRef(current, points.at(-1)!)) throw new RouteError("PASS_NOT_CONFIRMED");
    const isDestination = input.pointKind === "destination" || destinationOnly(entry.plan);
    if (input.pointKind === "destination" && !destinationOnly(entry.plan) && v.branch === "pending") throw new RouteError("PASS_NOT_CONFIRMED");
    if (!isDestination && entry.plan.policy !== "proceed") throw new RouteError("PASS_NOT_CONFIRMED");
    const target = isDestination ? entry.plan.destination : entry.plan.joinPoint!;
    // App evidence certifies approach-route order; the server independently
    // requires a continuous moving crossing, rejecting reversals and jumps.
    const forward = points.slice(2).every((c, i) => {
      const a = points[i], b = points[i + 1];
      return (b.lat - a.lat) * (c.lat - b.lat) + (b.lng - a.lng) * (c.lng - b.lng) * Math.cos(target.lat * Math.PI / 180) ** 2 >= 0;
    });
    const segments = points.slice(1).map((p, i) => segmentProjection(points[i], p, target));
    const crossing = segments.findIndex((p) => p.distance <= 25);
    if (crossing < 0 || !forward || distance(points[0], points.at(-1)!) < 10 || points.slice(1).some((s, i) => distance(points[i], s) < 1)
      || distance(points[0], target) <= 25 && distance(points.at(-1)!, target) <= 25) throw new RouteError("PASS_NOT_CONFIRMED");
    if (v.phase === "completed" || !isDestination && v.passedAtMs !== null) return this.#snapshot(entry);
    if (isDestination) { v.phase = "completed"; v.arrivedAtMs ??= this.#now(); }
    else {
      v.passedAtMs = this.#now();
      if (requester === leader) {
        const anchor: RouteAnchor = { kind: "segment", startRef: sampleRef(points[crossing]), endRef: sampleRef(points[crossing + 1]), fraction: segments[crossing].fraction };
        entry.runtime.leaderPassRef = anchor; entry.runtime.traceStartRef = structuredClone(anchor);
        entry.runtime.departedAtMs = this.#now(); entry.runtime.phase = "departed";
        v.phase = "toDestination"; v.branch = "destination";
      } else {
        const evidence = entry.evidence.get(requester)!;
        evidence.pendingPassAt = this.#now(); evidence.pendingPassClock = this.#clock();
        clearTimeout(entry.orderTimer);
        entry.orderTimer = setTimeout(() => this.#refresh(entry), 2000).unref();
      }
    }
    this.#resolveOrder(entry); this.#changed(entry); this.#refresh(entry);
    return this.#snapshot(entry);
  }
  guidanceStatus(code: string, leader: string, requester: string, raw: unknown): PlanSnapshot {
    const input = parseGuidanceStatus(raw);
    const entry = this.#entry(code, leader, input.planId, input.revision);
    this.#relation(entry, requester, input.followRequestId); this.#usable(code, requester); this.#usable(code, leader); this.#refresh(entry);
    this.#entry(code, leader, input.planId, input.revision);
    const v = entry.runtime.vehicles.find((v) => v.handle === requester)!;
    if (v.phase === "invited" || v.phase === "completed" || entry.runtime.phase === "idle") throw new RouteError("PLAN_NOT_READY");
    if (["onTrace", "rejoining"].includes(input.stage) && (v.branch !== "trace" || !this.#traceValid(entry))) throw new RouteError("TRACE_UNAVAILABLE");
    if (input.stage === "toJoin" && (v.phase !== "toJoin" || v.branch !== "pending" || v.passedAtMs !== null)) throw new RouteError("PLAN_NOT_READY");
    if (input.stage === "toDestination" && !destinationOnly(entry.plan) && v.branch !== "destination"
      && !(requester === leader && entry.runtime.departureAnnouncedAtMs !== null)) throw new RouteError("PLAN_NOT_READY");
    if (!fresh(this.#locations.recentSample(code, requester, input.originRef), this.#now())) throw new RouteError("REFERENCE_EXPIRED");
    if (input.calculatedAtMs !== undefined && (input.calculatedAtMs > this.#now() || this.#now() - input.calculatedAtMs >= 60_000)) throw new RouteError("INVALID_REQUEST");
    if (input.calculatedAtMs !== undefined && v.calculatedAtMs !== null && input.calculatedAtMs < v.calculatedAtMs) throw new RouteError("INVALID_REQUEST");
    const before = JSON.stringify(v);
    // Deliberately advisory: an app report never changes authoritative phase,
    // branch, arrival, departure or permissions.
    v.reportedStage = input.stage; v.etaSeconds = input.etaSeconds ?? null; v.calculatedAtMs = input.calculatedAtMs ?? null;
    if (JSON.stringify(v) !== before) this.#changed(entry);
    return this.#snapshot(entry);
  }
  routeContext(code: string, requester: string, request: PlanRouteRequest,
    { pinnedTrace = false }: { pinnedTrace?: boolean } = {}): { target: string; anchor: Point } {
    const entry = [...this.#entries.values()].find((e) => e.plan.roomCode === code && e.plan.planId === request.planId);
    if (!entry || entry.plan.revision !== request.planRevision) throw new RouteError("PLAN_CHANGED");
    this.#relation(entry, requester, request.followRequestId); this.#refresh(entry);
    this.#entry(code, entry.plan.leaderHandle, request.planId, request.planRevision);
    const { plan, runtime: r } = entry;
    const v = r.vehicles.find((v) => v.handle === requester)!;
    if (plan.status !== "ready" || r.phase === "idle" || v.phase === "completed") throw new RouteError("PLAN_NOT_READY");
    if (request.routeKind === "planJoin") {
      if (!plan.joinPoint || v.branch !== "pending" || v.passedAtMs !== null || v.phase !== "toJoin") throw new RouteError("PLAN_NOT_READY");
      return { target: plan.leaderHandle, anchor: { lat: plan.joinPoint.lat, lng: plan.joinPoint.lng } };
    }
    if (request.routeKind === "planDestination") {
      if (!destinationOnly(plan) && !(v.branch === "destination" || requester === plan.leaderHandle && r.departureAnnouncedAtMs !== null)) throw new RouteError("PLAN_NOT_READY");
      return { target: plan.leaderHandle, anchor: { lat: plan.destination.lat, lng: plan.destination.lng } };
    }
    if (v.branch !== "trace" || request.anchor.kind !== "segment") throw new RouteError("TRACE_UNAVAILABLE");
    // The route service alone supplies this proof after matching an unexpired
    // pinned input. Live plan/relation/vehicle checks above still apply; this
    // only avoids revalidating its immutable geometry against a newer ring.
    if (pinnedTrace) return { target: plan.leaderHandle, anchor: { lat: plan.joinPoint!.lat, lng: plan.joinPoint!.lng } };
    if (!this.#traceValid(entry)) throw new RouteError("TRACE_UNAVAILABLE");
    const trail = this.#locations.trail(code, plan.leaderHandle);
    const start = r.traceStartRef!;
    const startIndex = trail.findIndex((s) => sameRef(s, start.kind === "sample" ? start.ref : start.startRef));
    const index = trail.findIndex((s) => sameRef(s, request.anchor.kind === "segment" ? request.anchor.startRef : request.originRef));
    if (index < startIndex || index === startIndex && start.kind === "segment" && request.anchor.fraction < start.fraction) throw new RouteError("TRACE_UNAVAILABLE");
    // The route service performs the full r4 segment/continuity reconstruction.
    return { target: plan.leaderHandle, anchor: { lat: plan.joinPoint!.lat, lng: plan.joinPoint!.lng } };
  }
  validateRecommendation(code: string, leader: string, input: RecommendRequest): void {
    this.assertEditable(code, leader);
    const entry = this.#entries.get(key(code, leader));
    if (input.planId === null ? !!entry : !entry || entry.plan.planId !== input.planId || entry.plan.revision !== input.expectedRevision) throw new RouteError("PLAN_CHANGED");
    if (entry?.runtime.enrollments.length) throw new RouteError("PLAN_LOCKED");
    this.#checkSelection(code, leader, input.participantFollowRequestIds);
  }
  invalidateConsent(handle: string): void {
    for (const entry of [...this.#entries.values()]) {
      if (entry.plan.leaderHandle === handle) this.#clear(entry, "consentRevoked");
      else if (entry.runtime.enrollments.some((e) => e.handle === handle)) { this.#unenroll(entry, handle); this.#changed(entry); }
    }
  }
  sweep(code?: string): void {
    for (const entry of [...this.#entries.values()]) if (!code || entry.plan.roomCode === code) this.#refresh(entry);
    for (const [id, op] of this.#operations) if (this.#clock() >= op.until) this.#operations.delete(id);
  }
  close(): void {
    this.#closed = true;
    this.#locations.off("accepted", this.#accepted); this.#locations.off("invalidated", this.#invalidated);
    this.#locations.off("relations-changed", this.#relations);
    for (const entry of [...this.#entries.values()]) this.#clear(entry, "serverStopped");
    this.#operations.clear(); this.#participantLists.clear(); this.removeAllListeners();
  }
}
