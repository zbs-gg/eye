import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  MAX_PAYLOAD_BYTES,
  isActiveFocusedTabState,
  isLoopbackURL,
  payloadFits,
  shouldRequestExtraction,
  shouldResetTopDocument,
} from "../Extension/src/bridge-core.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("only the active tab in the focused browser window is eligible", () => {
  const tab = { id: 7, windowId: 3 };
  assert.equal(isActiveFocusedTabState(tab, { focused: true }, { id: 7, windowId: 3 }), true);
  assert.equal(isActiveFocusedTabState(tab, { focused: false }, { id: 7, windowId: 3 }), false);
  assert.equal(isActiveFocusedTabState(tab, { focused: true }, { id: 8, windowId: 3 }), false);
  assert.equal(isActiveFocusedTabState(tab, { focused: true }, { id: 7, windowId: 4 }), false);
});

test("DOM extraction requires enable, token, verified Eye, recording, and active focus", () => {
  const allowed = { enabled: true, token: "token", peerVerified: true, capturing: true, activeFocused: true };
  assert.equal(shouldRequestExtraction(allowed), true);
  for (const key of ["enabled", "token", "peerVerified", "capturing", "activeFocused"]) {
    assert.equal(shouldRequestExtraction({ ...allowed, [key]: key === "token" ? "" : false }), false);
  }
});

test("navigation and new top-level documents reset stale iframe snapshots", () => {
  assert.equal(shouldResetTopDocument("doc-a", "doc-a", "mutation"), false);
  assert.equal(shouldResetTopDocument("doc-a", "doc-a", "navigation"), true);
  assert.equal(shouldResetTopDocument("doc-a", "doc-b", "document-idle"), true);
});

test("payload byte limit is enforced, including multibyte text", () => {
  assert.equal(payloadFits("x".repeat(MAX_PAYLOAD_BYTES)), true);
  assert.equal(payloadFits("x".repeat(MAX_PAYLOAD_BYTES + 1)), false);
  assert.equal(payloadFits("я".repeat(MAX_PAYLOAD_BYTES / 2 + 1)), false);
});

test("runtime has only loopback fetch targets and minimal manifest permissions", async () => {
  const manifest = JSON.parse(await readFile(path.join(root, "Extension/manifest.json"), "utf8"));
  assert.deepEqual(manifest.permissions, ["storage"]);
  assert.equal(manifest.version, "0.6.0");
  assert.deepEqual(manifest.host_permissions.sort(), ["http://127.0.0.1/*", "http://localhost/*"]);
  assert.equal(isLoopbackURL("http://127.0.0.1:8731/health"), true);
  assert.equal(isLoopbackURL("http://localhost:8731/health"), true);
  assert.equal(isLoopbackURL("https://example.com/collect"), false);
  const worker = await readFile(path.join(root, "Extension/src/service-worker.js"), "utf8");
  const literalHosts = Array.from(
    worker.matchAll(/https?:\/\/([a-zA-Z0-9.-]+)/g),
    (match) => match[1],
  );
  assert.deepEqual(new Set(literalHosts), new Set(["127.0.0.1"]));
});
