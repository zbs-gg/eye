import {
  boundedFrames,
  isActiveFocusedTabState,
  payloadFits,
  shouldRequestExtraction,
  shouldResetTopDocument,
} from "./bridge-core.js";

const PORTS = [8731, 8732, 11435, 8088];
const FRAME_FRESHNESS_MS = 30_000;
const REQUEST_FRESHNESS_MS = 5_000;
const frameState = new Map();
const publishTimers = new Map();
const lastSentHash = new Map();
const extractionRequests = new Map();
let cachedEyePort = null;

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

async function hmac(token, value) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(signature));
}

function makeChallenge() {
  return bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
}

async function bridgeSettings() {
  const stored = await chrome.storage.local.get([
    "captureEnabled", "browserIngestToken", "browserInstanceId",
  ]);
  let browserInstanceId = stored.browserInstanceId;
  if (!browserInstanceId) {
    browserInstanceId = crypto.randomUUID();
    await chrome.storage.local.set({ browserInstanceId });
  }
  return {
    enabled: stored.captureEnabled === true,
    token: String(stored.browserIngestToken || "").trim(),
    browserInstanceId,
  };
}

async function setStatus(bridgeStatus, bridgeError = "") {
  const update = { bridgeStatus, bridgeError };
  if (bridgeStatus === "connected") update.bridgeLastConnectedAt = Date.now();
  await chrome.storage.local.set(update);
}

async function verifiedEye(token) {
  const ports = cachedEyePort
    ? [cachedEyePort, ...PORTS.filter((port) => port !== cachedEyePort)]
    : PORTS;
  for (const port of ports) {
    const challenge = makeChallenge();
    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/health?scope=browser&challenge=${challenge}`,
        { cache: "no-store", signal: AbortSignal.timeout(1_500) },
      );
      if (!response.ok) continue;
      const health = await response.json();
      const expected = await hmac(token, `zbseye-local-peer-v1\n${port}\n${challenge}`);
      if (health.proof === expected) {
        cachedEyePort = port;
        return { port, capturing: health.capturing === true };
      }
    } catch {
      // A closed local app or unused port is normal.
    }
  }
  cachedEyePort = null;
  return null;
}

async function isActiveFocusedTab(tab) {
  if (!Number.isInteger(tab?.id) || !Number.isInteger(tab?.windowId)) return false;
  const browserWindow = await chrome.windows.get(tab.windowId);
  const [activeTab] = await chrome.tabs.query({ active: true, windowId: tab.windowId });
  return isActiveFocusedTabState(tab, browserWindow, activeTab);
}

function clearTabState(tabId) {
  frameState.delete(tabId);
  lastSentHash.delete(tabId);
  clearTimeout(publishTimers.get(tabId));
  publishTimers.delete(tabId);
  for (const [requestId, request] of extractionRequests) {
    if (request.tabId === tabId) extractionRequests.delete(requestId);
  }
}

function clearAllState() {
  for (const tabId of frameState.keys()) clearTabState(tabId);
  frameState.clear();
  lastSentHash.clear();
  extractionRequests.clear();
}

function stateFor(tabId) {
  let state = frameState.get(tabId);
  if (!state) {
    state = { topDocumentId: null, frames: new Map() };
    frameState.set(tabId, state);
  }
  return state;
}

function prepareTopDocument(tabId, sender, reason) {
  const state = stateFor(tabId);
  const documentId = sender.documentId || `top-${tabId}`;
  if (shouldResetTopDocument(state.topDocumentId, documentId, reason)) {
    state.topDocumentId = documentId;
    state.frames.clear();
    lastSentHash.delete(tabId);
  }
}

function cacheFrame(tabId, sender, message) {
  const state = stateFor(tabId);
  const frameId = Number.isInteger(sender.frameId) ? sender.frameId : 0;
  const documentId = sender.documentId || `frame-${frameId}`;
  if (frameId === 0) prepareTopDocument(tabId, sender, message.reason);
  for (const [key, frame] of state.frames) {
    if (frame.frameId === frameId && frame.documentId !== documentId) state.frames.delete(key);
  }
  state.frames.set(documentId, {
    frameId,
    parentFrameId: null,
    documentId,
    url: String(message.url || ""),
    title: String(message.title || "").slice(0, 2_048),
    text: String(message.text || "").slice(0, 40_000),
    pixelOnly: Boolean(message.pixelOnly),
    receivedAt: Date.now(),
  });
  for (const [key, frame] of state.frames) {
    if (Date.now() - frame.receivedAt > FRAME_FRESHNESS_MS) state.frames.delete(key);
  }
}

async function requestCapture(tabId, reason = "activation", frameId = null) {
  if (!Number.isInteger(tabId)) return;
  const settings = await bridgeSettings();
  if (!settings.enabled) {
    clearTabState(tabId);
    await setStatus("disabled");
    return;
  }
  if (!settings.token) {
    clearTabState(tabId);
    await setStatus("token-required");
    return;
  }

  const tab = await chrome.tabs.get(tabId).catch(() => null);
  const activeFocused = tab ? await isActiveFocusedTab(tab).catch(() => false) : false;
  const eye = activeFocused ? await verifiedEye(settings.token) : null;
  const allowed = shouldRequestExtraction({
    enabled: settings.enabled,
    token: settings.token,
    peerVerified: Boolean(eye),
    capturing: eye?.capturing === true,
    activeFocused,
  });
  if (!allowed) {
    clearTabState(tabId);
    if (!activeFocused) return;
    await setStatus(eye ? "paused" : "disconnected");
    return;
  }

  const now = Date.now();
  for (const [requestId, request] of extractionRequests) {
    if (request.expiresAt < now) extractionRequests.delete(requestId);
  }
  const requestId = crypto.randomUUID();
  extractionRequests.set(requestId, { tabId, expiresAt: Date.now() + REQUEST_FRESHNESS_MS });
  setTimeout(() => extractionRequests.delete(requestId), REQUEST_FRESHNESS_MS + 100);
  const message = { type: "zbs-eye-capture-now", requestId, reason };
  if (Number.isInteger(frameId)) {
    await chrome.tabs.sendMessage(tabId, message, { frameId }).catch(() => {});
  } else {
    await chrome.tabs.sendMessage(tabId, message).catch(() => {});
  }
}

async function sendSnapshot(tabId) {
  const settings = await bridgeSettings();
  if (!settings.enabled || !settings.token) return;
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab || !await isActiveFocusedTab(tab).catch(() => false)) return;
  const state = frameState.get(tabId);
  if (!state?.frames.size) return;
  const top = Array.from(state.frames.values()).find((frame) => frame.frameId === 0);
  if (!top || !/^https?:/.test(top.url)) return;

  const eye = await verifiedEye(settings.token);
  if (!eye?.capturing) {
    clearTabState(tabId);
    await setStatus(eye ? "paused" : "disconnected");
    return;
  }

  const frames = boundedFrames(state.frames);
  const combinedText = frames.map((frame) => frame.text).join("\n");
  const pixelOnly = combinedText.trim().length < 40
    && Array.from(state.frames.values()).some((frame) => frame.pixelOnly);
  const contentHash = await sha256(`${top.url}\n${top.title}\n${combinedText}\n${pixelOnly}`);
  if (lastSentHash.get(tabId) === contentHash) return;

  const payload = {
    schemaVersion: 1,
    capturedAtMs: Date.now(),
    browserInstanceId: settings.browserInstanceId,
    tabId,
    windowId: tab.windowId,
    documentId: top.documentId,
    url: top.url,
    title: top.title,
    contentHash,
    active: true,
    windowFocused: true,
    pixelOnly,
    frames,
  };
  const body = JSON.stringify(payload);
  if (!payloadFits(body)) {
    await setStatus("payload-rejected", "Rendered page exceeded the local 256 KB safety limit.");
    return;
  }

  try {
    const response = await fetch(`http://127.0.0.1:${eye.port}/v1/browser/snapshot`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${settings.token}`,
        "Content-Type": "application/json",
      },
      body,
    });
    if (!response.ok) throw new Error(`Eye rejected snapshot (${response.status})`);
    const result = await response.json();
    if (["accepted", "duplicate"].includes(result.status)) {
      lastSentHash.set(tabId, contentHash);
      await setStatus("connected");
    } else if (result.status === "paused") {
      clearTabState(tabId);
      await setStatus("paused");
    }
  } catch (error) {
    cachedEyePort = null;
    await setStatus("disconnected", String(error?.message || error));
  }
}

async function sendHeartbeat(tabId) {
  const settings = await bridgeSettings();
  if (!settings.enabled || !settings.token) return;
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab || !await isActiveFocusedTab(tab).catch(() => false)) return;
  const state = frameState.get(tabId);
  const top = state
    ? Array.from(state.frames.values()).find((frame) => frame.frameId === 0)
    : null;
  const contentHash = lastSentHash.get(tabId);
  if (!top || !contentHash) {
    await requestCapture(tabId, "heartbeat");
    return;
  }

  const eye = await verifiedEye(settings.token);
  if (!eye?.capturing) {
    clearTabState(tabId);
    await setStatus(eye ? "paused" : "disconnected");
    return;
  }
  const body = JSON.stringify({
    schemaVersion: 1,
    capturedAtMs: Date.now(),
    browserInstanceId: settings.browserInstanceId,
    tabId,
    windowId: tab.windowId,
    documentId: top.documentId,
    url: top.url,
    title: top.title,
    contentHash,
    active: true,
    windowFocused: true,
  });
  try {
    const response = await fetch(`http://127.0.0.1:${eye.port}/v1/browser/heartbeat`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${settings.token}`,
        "Content-Type": "application/json",
      },
      body,
    });
    if (!response.ok) throw new Error(`Eye rejected heartbeat (${response.status})`);
    const result = await response.json();
    if (result.status === "missing") {
      clearTabState(tabId);
      await requestCapture(tabId, "heartbeat");
    } else if (result.status === "paused") {
      clearTabState(tabId);
      await setStatus("paused");
    } else {
      await setStatus("connected");
    }
  } catch {
    cachedEyePort = null;
    await setStatus("disconnected");
  }
}

function schedulePublish(tabId) {
  clearTimeout(publishTimers.get(tabId));
  publishTimers.set(tabId, setTimeout(() => {
    publishTimers.delete(tabId);
    sendSnapshot(tabId).catch(() => {});
  }, 300));
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const tabId = sender.tab?.id;
  if (!Number.isInteger(tabId)) return;
  if (message?.type === "zbs-eye-dirty") {
    if (message.topFrame) prepareTopDocument(tabId, sender, message.reason);
    requestCapture(tabId, message.reason || "mutation", sender.frameId).catch(() => {});
    return;
  }
  if (message?.type === "zbs-eye-probe") {
    sendHeartbeat(tabId).catch(() => {});
    return;
  }
  if (message?.type !== "zbs-eye-frame") return;

  const request = extractionRequests.get(message.requestId);
  if (!request || request.tabId !== tabId || request.expiresAt < Date.now()) return;
  isActiveFocusedTab(sender.tab).then((allowed) => {
    if (!allowed) return;
    cacheFrame(tabId, sender, message);
    schedulePublish(tabId);
  }).catch(() => {});
});

chrome.tabs.onActivated.addListener(({ tabId }) => requestCapture(tabId, "activation"));
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") clearTabState(tabId);
});
chrome.tabs.onRemoved.addListener(clearTabState);
chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  await requestCapture(tab?.id, "activation");
});
chrome.storage.onChanged.addListener(async (changes, areaName) => {
  if (areaName !== "local") return;
  if (changes.captureEnabled && changes.captureEnabled.newValue !== true) {
    clearAllState();
    await setStatus("disabled");
    return;
  }
  if (changes.captureEnabled?.newValue === true || changes.browserIngestToken) {
    clearAllState();
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    await requestCapture(tab?.id, "activation");
  }
});
chrome.runtime.onInstalled.addListener(async () => {
  const stored = await chrome.storage.local.get(["captureEnabled"]);
  if (stored.captureEnabled !== true) {
    await chrome.storage.local.set({ captureEnabled: false, bridgeStatus: "disabled" });
  }
});
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
