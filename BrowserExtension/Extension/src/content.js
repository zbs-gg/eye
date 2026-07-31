(() => {
  "use strict";

  const extractor = globalThis.ZBSEyeDOMExtractor;
  if (!extractor) return;

  let dirtyTimer = null;
  let pendingReason = "document-idle";
  let lastFrameHash = "";

  async function sha256(value) {
    const bytes = new TextEncoder().encode(value);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  function announceDirty(reason) {
    pendingReason = reason;
    clearTimeout(dirtyTimer);
    dirtyTimer = setTimeout(() => {
      chrome.runtime.sendMessage({
        type: "zbs-eye-dirty",
        reason: pendingReason,
        topFrame: window.top === window,
      }).catch(() => {});
    }, 250);
  }

  async function capture(request) {
    if (document.visibilityState === "hidden") return;
    const extracted = extractor.snapshot(document);
    const frameHash = await sha256(`${location.href}\n${document.title}\n${extracted.text}\n${extracted.pixelOnly}`);
    if (frameHash === lastFrameHash && request.reason !== "activation") return;
    lastFrameHash = frameHash;
    await chrome.runtime.sendMessage({
      type: "zbs-eye-frame",
      requestId: request.requestId,
      reason: request.reason,
      url: location.href,
      title: document.title || "",
      text: extracted.text,
      pixelOnly: extracted.pixelOnly,
      frameHash,
    }).catch(() => {});
  }

  const observer = new MutationObserver(() => announceDirty("mutation"));
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["aria-label", "aria-hidden", "class", "hidden", "style", "inert"],
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "zbs-eye-capture-now") capture(message);
  });
  addEventListener("hashchange", () => announceDirty("navigation"));
  addEventListener("popstate", () => announceDirty("navigation"));
  addEventListener("pageshow", () => announceDirty("navigation"));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") announceDirty("activation");
  });

  if (window.top === window) {
    setInterval(() => {
      if (document.visibilityState === "visible") {
        chrome.runtime.sendMessage({ type: "zbs-eye-probe" }).catch(() => {});
      }
    }, 4_000);
  }
  announceDirty("document-idle");
})();
