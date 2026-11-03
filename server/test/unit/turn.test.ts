import assert from "node:assert/strict";
import { test } from "node:test";
import { issueIceServers } from "../../src/turn.ts";

const uris = "turn:relay.example:3478?transport=udp, turn:relay.example:3478?transport=tcp, stun:relay.example:3478";

test("TURN REST username과 HMAC-SHA1 자격은 고정 벡터와 일치한다", () => {
  assert.deepEqual(issueIceServers("alice", {
    TURN_SECRET: "fixed-turn-secret", TURN_URIS: uris, TURN_TTL_SECONDS: "3600",
  }, 1_700_000_000), {
    iceServers: [
      { urls: ["stun:relay.example:3478"] },
      {
        urls: ["turn:relay.example:3478?transport=udp", "turn:relay.example:3478?transport=tcp"],
        username: "1700003600:alice", credential: "8iVscvaqL+s2I2iXJgrjqndBVnI=",
      },
    ],
    ttlSeconds: 3600,
  });
});

test("secret 없거나 비어 있으면 STUN만 반환하고 자격은 포함하지 않는다", () => {
  for (const secret of [undefined, ""]) {
    assert.deepEqual(issueIceServers("alice", {
      TURN_SECRET: secret, TURN_URIS: uris, TURN_TTL_SECONDS: "60",
    }, 100), { iceServers: [{ urls: ["stun:relay.example:3478"] }], ttlSeconds: 60 });
  }
  assert.deepEqual(issueIceServers("alice", { TURN_URIS: "turn:relay.example:3478" }).iceServers, []);
});

test("만료 Unix 초는 now 내림 + ttl이고 realm은 username에 붙이지 않는다", () => {
  const result = issueIceServers("bob_123", {
    TURN_SECRET: "secret", TURN_REALM: "relay.example", TURN_URIS: uris, TURN_TTL_SECONDS: "125",
  }, 1_700_000_000.9);
  assert.equal(result.ttlSeconds, 125);
  assert.equal(result.iceServers[1].username, "1700000125:bob_123");
});

test("잘못된 TTL은 기본값을 쓰고 URI는 공백·중복을 정리한다", () => {
  for (const ttl of [undefined, "", "0", "-1", "1.5", "Infinity", "invalid"]) {
    assert.equal(issueIceServers("alice", { TURN_TTL_SECONDS: ttl }).ttlSeconds, 3600);
  }
  assert.deepEqual(issueIceServers("alice", {
    TURN_REALM: "relay.example", TURN_URIS: " stun:relay.example:3478, ,stun:relay.example:3478,https://invalid",
  }).iceServers, [{ urls: ["stun:relay.example:3478"] }]);
  assert.deepEqual(issueIceServers("alice", { TURN_REALM: "relay.example" }).iceServers,
    [{ urls: ["stun:relay.example:3478"] }]);
});
