(function installDOMExtractor(root, factory) {
  const api = factory();
  root.ZBSEyeDOMExtractor = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis === "object" ? globalThis : this, function makeDOMExtractor() {
  "use strict";

  const MAX_TEXT_CHARACTERS = 40_000;
  const BLOCKED_TAGS = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS",
  ]);
  const LINE_BREAK_TAGS = new Set([
    "ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "BR", "DD", "DIV", "DL",
    "DT", "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2",
    "H3", "H4", "H5", "H6", "HEADER", "HR", "LI", "MAIN", "NAV", "OL", "P",
    "PRE", "SECTION", "TABLE", "TBODY", "TD", "TFOOT", "TH", "THEAD", "TR", "UL",
  ]);

  function normalizeInline(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
  }

  function isHidden(element, view) {
    if (!element || element.nodeType !== 1) return false;
    if (element.hidden || element.getAttribute("aria-hidden") === "true") return true;
    if (element.closest?.("[hidden],[aria-hidden='true'],[inert]")) return true;
    if (!view || typeof view.getComputedStyle !== "function") return false;
    const style = view.getComputedStyle(element);
    return style.display === "none"
      || style.visibility === "hidden"
      || style.visibility === "collapse"
      || Number.parseFloat(style.opacity || "1") === 0;
  }

  function pushToken(tokens, value) {
    const normalized = normalizeInline(value);
    if (!normalized) return;
    if (tokens[tokens.length - 1] !== normalized) tokens.push(normalized);
  }

  function pushBreak(tokens) {
    if (tokens.length > 0 && tokens[tokens.length - 1] !== "\n") tokens.push("\n");
  }

  function visit(node, tokens, view, count) {
    if (!node || count.value >= MAX_TEXT_CHARACTERS) return;
    if (node.nodeType === 3) {
      const value = normalizeInline(node.nodeValue);
      count.value += value.length;
      pushToken(tokens, value);
      return;
    }
    if (node.nodeType !== 1 && node.nodeType !== 9 && node.nodeType !== 11) return;

    const element = node.nodeType === 1 ? node : null;
    if (element) {
      if (BLOCKED_TAGS.has(element.tagName) || isHidden(element, view)) return;
      if (element.matches("input, textarea, select, option")) return;
      pushToken(tokens, element.getAttribute("aria-label"));
      if (element.tagName === "IMG") pushToken(tokens, element.getAttribute("alt"));
    }

    for (const child of Array.from(node.childNodes || [])) visit(child, tokens, view, count);
    if (element?.shadowRoot?.mode === "open") visit(element.shadowRoot, tokens, view, count);
    if (element && LINE_BREAK_TAGS.has(element.tagName)) pushBreak(tokens);
  }

  function renderTokens(tokens) {
    const lines = [];
    let line = [];
    for (const token of tokens) {
      if (token === "\n") {
        const value = normalizeInline(line.join(" "));
        if (value && lines[lines.length - 1] !== value) lines.push(value);
        line = [];
      } else {
        line.push(token);
      }
    }
    const tail = normalizeInline(line.join(" "));
    if (tail && lines[lines.length - 1] !== tail) lines.push(tail);
    return lines.join("\n").slice(0, MAX_TEXT_CHARACTERS);
  }

  function extractRenderedDocument(documentNode) {
    if (!documentNode) return "";
    const tokens = [];
    visit(
      documentNode.body || documentNode.documentElement || documentNode,
      tokens,
      documentNode.defaultView || null,
      { value: 0 },
    );
    return renderTokens(tokens);
  }

  function hasLargeVisiblePixelSurface(documentNode) {
    if (!documentNode?.querySelectorAll) return false;
    const view = documentNode.defaultView || null;
    const surfaces = documentNode.querySelectorAll(
      "canvas, video, embed[type='application/pdf'], object[type='application/pdf'], img",
    );
    return Array.from(surfaces).some((element) => {
      if (isHidden(element, view)) return false;
      if (element.tagName === "EMBED" || element.tagName === "OBJECT") return true;
      const rect = element.getBoundingClientRect?.()
        || { width: element.width || 0, height: element.height || 0 };
      return rect.width * rect.height >= 40_000;
    });
  }

  function snapshot(documentNode) {
    const text = extractRenderedDocument(documentNode);
    return {
      text,
      pixelOnly: text.length < 40 && hasLargeVisiblePixelSurface(documentNode),
    };
  }

  return {
    MAX_TEXT_CHARACTERS,
    extractRenderedDocument,
    hasLargeVisiblePixelSurface,
    normalizeInline,
    snapshot,
  };
});
