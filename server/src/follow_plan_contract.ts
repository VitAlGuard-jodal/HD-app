import { finite, identifier, integer, keys, point, record, ref, RouteError } from "./route_contract.ts";
import type { Point, RouteAnchor, SampleRef } from "./route_contract.ts";

export interface PlanPoint extends Point { label: string; source: "map" | "address" | "recommendation" }
export interface FollowPlan {
  planId: string; leaderHandle: string; roomCode: string; revision: number;
  destination: PlanPoint; joinPoint: PlanPoint | null; policy: "wait" | "proceed";
  participantFollowRequestIds: string[]; waitingPlaceConfirmed: boolean;
  createdAtMs: number; updatedAtMs: number; status: "draft" | "ready";
}
export type VehiclePhase = "invited" | "toJoin" | "atJoinWaiting" | "tracePriming" | "onTrace" | "toDestination" | "completed";
export type ReportedStage = "toJoin" | "toDestination" | "onTrace" | "rejoining" | "calculating" | "rateWaiting" | "noRoute";
export interface PlanVehicle {
  handle: string; followRequestId: string | null; phase: VehiclePhase;
  branch: "pending" | "trace" | "destination";
  arrivedAtMs: number | null; passedAtMs: number | null;
  condition: "locationDelayed" | "poorAccuracy" | "consentRequired" | "traceUnavailable" | null;
  reportedStage: ReportedStage | null;
  etaSeconds: number | null; calculatedAtMs: number | null;
}
export interface DepartureCohort {
  followRequestIds: string[]; runtimeRevision: number; capturedAtMs: number; leaderWaitingRef: SampleRef;
}
export interface PlanRuntime {
  planId: string; revision: number; runtimeRevision: number;
  phase: "idle" | "approaching" | "waiting" | "departed" | "completed" | "leftEarly" | "suspended" | "traceUnavailable";
  enrollments: { handle: string; followRequestId: string }[]; vehicles: PlanVehicle[];
  leaderPassRef: RouteAnchor | null; traceStartRef: RouteAnchor | null;
  departureCohort: DepartureCohort | null; departureAnnouncedAtMs: number | null; departedAtMs: number | null;
}
export interface PlanSnapshot { plan: FollowPlan | null; runtime: PlanRuntime | null; serverNowMs: number }
export interface SavePlan {
  operationId: string; expectedPlanId: string | null; expectedRevision: number;
  destination: PlanPoint; joinPoint: PlanPoint | null; policy: "wait" | "proceed";
  participantFollowRequestIds: string[]; waitingPlaceConfirmed: boolean;
}
export interface RecommendRequest {
  requestId: string; draftGeneration: number; planId: string | null; expectedRevision: number;
  destination: PlanPoint; participantFollowRequestIds: string[];
}
export interface Participation {
  operationId: string; planId: string; planRevision: number; followRequestId: string; enabled: boolean;
}
export interface DepartRequest { operationId: string; planId: string; planRevision: number; expectedRuntimeRevision: number }
export interface DeletePlan { operationId: string; planId: string; expectedRevision: number }
export interface PassEvidence {
  planId: string; revision: number; followRequestId: string | null; requestId: string;
  ownRefs: SampleRef[]; pointKind: "joinPoint" | "destination";
}
export interface GuidanceStatus {
  planId: string; revision: number; followRequestId: string | null; originRef: SampleRef;
  stage: ReportedStage; etaSeconds?: number; calculatedAtMs?: number;
}
export function planPoint(value: unknown, destination = false): value is PlanPoint {
  return record(value) && keys(value, ["lat", "lng", "label", "source"]) && point(value)
    && typeof value.label === "string" && Array.from(value.label).length <= 200 && !/[\p{Cc}\p{Cf}]/u.test(value.label)
    && (value.source === "map" || value.source === "address" || !destination && value.source === "recommendation");
}
function ids(value: unknown): value is string[] {
  return Array.isArray(value) && value.length <= 100 && value.every(identifier) && new Set(value).size === value.length;
}
function invalid(): never { throw new RouteError("INVALID_REQUEST"); }
function cas(id: unknown, revision: unknown): boolean {
  return integer(revision) && (id === null ? revision === 0 : identifier(id) && revision >= 1);
}
export function parseSavePlan(value: unknown): SavePlan {
  if (!record(value) || !keys(value, ["operationId", "expectedPlanId", "expectedRevision", "destination", "joinPoint",
    "policy", "participantFollowRequestIds", "waitingPlaceConfirmed"]) || !identifier(value.operationId)
    || !cas(value.expectedPlanId, value.expectedRevision) || !planPoint(value.destination, true)
    || !(value.joinPoint === null || planPoint(value.joinPoint)) || !["wait", "proceed"].includes(value.policy as string)
    || !ids(value.participantFollowRequestIds) || typeof value.waitingPlaceConfirmed !== "boolean") invalid();
  return structuredClone(value) as unknown as SavePlan;
}
export function parseRecommend(value: unknown): RecommendRequest {
  if (!record(value) || !keys(value, ["requestId", "draftGeneration", "planId", "expectedRevision", "destination", "participantFollowRequestIds"])
    || !identifier(value.requestId) || !integer(value.draftGeneration) || !cas(value.planId, value.expectedRevision)
    || !planPoint(value.destination, true) || !ids(value.participantFollowRequestIds)) invalid();
  return structuredClone(value) as unknown as RecommendRequest;
}
export function parseParticipation(value: unknown): Participation {
  if (!record(value) || !keys(value, ["operationId", "planId", "planRevision", "followRequestId", "enabled"])
    || !identifier(value.operationId) || !identifier(value.planId) || !integer(value.planRevision) || value.planRevision < 1
    || !identifier(value.followRequestId) || typeof value.enabled !== "boolean") invalid();
  return structuredClone(value) as unknown as Participation;
}
export function parseDeletePlan(value: unknown): DeletePlan {
  if (!record(value) || !keys(value, ["operationId", "planId", "expectedRevision"]) || !identifier(value.operationId)
    || !identifier(value.planId) || !integer(value.expectedRevision) || value.expectedRevision < 1) invalid();
  return structuredClone(value) as unknown as DeletePlan;
}
export function parseDepart(value: unknown): DepartRequest {
  if (!record(value) || !keys(value, ["operationId", "planId", "planRevision", "expectedRuntimeRevision"])
    || !identifier(value.operationId) || !identifier(value.planId) || !integer(value.planRevision) || value.planRevision < 1
    || !integer(value.expectedRuntimeRevision)) invalid();
  return structuredClone(value) as unknown as DepartRequest;
}
export function parsePassEvidence(value: unknown): PassEvidence {
  if (!record(value) || !keys(value, ["planId", "revision", "followRequestId", "requestId", "ownRefs", "pointKind"])
    || !identifier(value.planId) || !integer(value.revision) || value.revision < 1 || !identifier(value.requestId)
    || !(value.followRequestId === null || identifier(value.followRequestId))
    || !Array.isArray(value.ownRefs) || value.ownRefs.length !== 3 || !value.ownRefs.every(ref)
    || !["joinPoint", "destination"].includes(value.pointKind as string)) invalid();
  return structuredClone(value) as unknown as PassEvidence;
}
export function parseGuidanceStatus(value: unknown): GuidanceStatus {
  if (!record(value) || !keys(value, ["planId", "revision", "followRequestId", "originRef", "stage",
    ...(Object.hasOwn(value, "etaSeconds") ? ["etaSeconds"] : []), ...(Object.hasOwn(value, "calculatedAtMs") ? ["calculatedAtMs"] : [])])
    || !identifier(value.planId) || !integer(value.revision) || value.revision < 1
    || !(value.followRequestId === null || identifier(value.followRequestId)) || !ref(value.originRef)
    || !["toJoin", "toDestination", "onTrace", "rejoining", "calculating", "rateWaiting", "noRoute"].includes(value.stage as string)
    || ((value.etaSeconds === undefined) !== (value.calculatedAtMs === undefined))
    || (value.etaSeconds !== undefined && (!finite(value.etaSeconds) || value.etaSeconds < 0 || value.etaSeconds > 604800
      || !integer(value.calculatedAtMs)))) invalid();
  return structuredClone(value) as unknown as GuidanceStatus;
}
