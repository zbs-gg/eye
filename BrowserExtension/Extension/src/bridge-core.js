export const MAX_TEXT_CHARACTERS = 40_000;
export const MAX_PAYLOAD_BYTES = 256 * 1024;
export const MAX_FRAMES = 32;

export function isActiveFocusedTabState(tab, browserWindow, activeTab) {
  return Boolean(
    Number.isInteger(tab?.id)
      && Number.isInteger(tab?.windowId)
      && browserWindow?.focused
      && activeTab?.id === tab.id
      && activeTab?.windowId === tab.windowId,
  );
}

export function shouldRequestExtraction({ enabled, token, peerVerified, capturing, activeFocused }) {
  return Boolean(enabled && token && peerVerified && capturing && activeFocused);
}

export function shouldResetTopDocument(currentDocumentId, nextDocumentId, reason) {
  return currentDocumentId !== nextDocumentId || reason === "navigation";
}

export function boundedFrames(cachedFrames) {
  let remaining = MAX_TEXT_CHARACTERS;
  return Array.from(cachedFrames.values())
    .sort((a, b) => a.frameId - b.frameId)
    .slice(0, MAX_FRAMES)
    .map((frame) => {
      const text = String(frame.text || "").slice(0, remaining);
      remaining -= text.length;
      return {
        frameId: frame.frameId,
        parentFrameId: frame.parentFrameId ?? null,
        documentId: frame.documentId,
        url: frame.url,
        text,
      };
    });
}

export function encodedByteCount(value) {
  return new TextEncoder().encode(value).length;
}

export function payloadFits(body) {
  return encodedByteCount(body) <= MAX_PAYLOAD_BYTES;
}

export function isLoopbackURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:"
      && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
  } catch {
    return false;
  }
}
