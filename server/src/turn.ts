import { createHmac } from "node:crypto";

export interface TurnEnvironment {
  TURN_SECRET?: string;
  TURN_REALM?: string;
  TURN_URIS?: string;
  TURN_TTL_SECONDS?: string;
}

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

// now is Unix seconds so expiry and the coturn REST username share one clock.
export function issueIceServers(
  handle: string,
  env: TurnEnvironment = process.env,
  now = Math.floor(Date.now() / 1000),
): { iceServers: IceServer[]; ttlSeconds: number } {
  const configuredTtl = Number(env.TURN_TTL_SECONDS);
  const ttlSeconds = Number.isSafeInteger(configuredTtl) && configuredTtl > 0
    ? configuredTtl : 3600;
  const uris = [...new Set((env.TURN_URIS ?? `stun:${env.TURN_REALM || "stun.l.google.com"}:${env.TURN_REALM ? 3478 : 19302}`)
    .split(",").map((uri) => uri.trim()).filter(Boolean))];
  const stun = uris.filter((uri) => /^stuns?:/i.test(uri));
  const turn = uris.filter((uri) => /^turns?:/i.test(uri));
  const iceServers: IceServer[] = [];
  if (stun.length) iceServers.push({ urls: stun });
  if (env.TURN_SECRET && turn.length) {
    const username = `${Math.floor(now) + ttlSeconds}:${handle}`;
    const credential = createHmac("sha1", env.TURN_SECRET).update(username).digest("base64");
    iceServers.push({ urls: turn, username, credential });
  }
  return { iceServers, ttlSeconds };
}
