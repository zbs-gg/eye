import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test, { after, before } from "node:test";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtures = path.join(root, "fixtures");
const extensionSource = path.join(root, "Extension/src");
let browser;
let server;
let baseURL;

before(async () => {
  server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, "http://fixture").pathname);
      const file = path.resolve(fixtures, pathname === "/" ? "article.html" : `.${pathname}`);
      if (!file.startsWith(`${fixtures}${path.sep}`)) throw new Error("unsafe path");
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response.end(await readFile(file));
    } catch {
      response.statusCode = 404;
      response.end("not found");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseURL = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROME_PATH
      || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  });
});

after(async () => {
  await browser?.close();
  await new Promise((resolve) => server?.close(resolve));
});

async function snapshot(name) {
  const page = await browser.newPage();
  await page.goto(`${baseURL}/${name}`, { waitUntil: "load" });
  await page.addScriptTag({ path: path.join(extensionSource, "dom-extractor.js") });
  const result = await page.evaluate(() => globalThis.ZBSEyeDOMExtractor.snapshot(document));
  await page.close();
  return result;
}

test("article includes rendered semantics but not scripts, styles, or hidden text", async () => {
  const result = await snapshot("article.html");
  assert.match(result.text, /Fixture article/);
  assert.match(result.text, /Rendered text must be indexed/);
  assert.doesNotMatch(result.text, /fixtureSecret|script text|hidden text|style text/);
});

test("SPA mutation and history navigation expose the new rendered route", async () => {
  const result = await snapshot("react-spa.html");
  assert.match(result.text, /SPA route two/);
  assert.match(result.text, /Mutation rendered/);
  assert.doesNotMatch(result.text, /SPA route one/);
});

test("all-frame fixture exposes parent and child rendered text", async () => {
  const page = await browser.newPage();
  await page.goto(`${baseURL}/iframe.html`, { waitUntil: "load" });
  const texts = [];
  for (const frame of page.frames()) {
    await frame.addScriptTag({ path: path.join(extensionSource, "dom-extractor.js") });
    texts.push(await frame.evaluate(() => globalThis.ZBSEyeDOMExtractor.extractRenderedDocument(document)));
  }
  assert.match(texts.join("\n"), /Parent frame/);
  assert.match(texts.join("\n"), /Text rendered inside the child frame/);
  await page.close();
});

test("open shadow DOM is indexed", async () => {
  const result = await snapshot("open-shadow.html");
  assert.match(result.text, /Shadow heading/);
  assert.match(result.text, /Shadow body text/);
});

test("form values and passwords never leave the page while labels remain", async () => {
  const result = await snapshot("password-form.html");
  assert.match(result.text, /Email address/);
  assert.match(result.text, /Password/);
  assert.match(result.text, /Notes/);
  assert.doesNotMatch(
    result.text,
    /private@example\.com|never-index-this-secret|private textarea|private selected|visually hidden/,
  );
});

test("canvas, PDF, and video pages request throttled OCR fallback", async () => {
  for (const fixture of ["canvas-only.html", "pdf-only.html", "video-only.html"]) {
    const result = await snapshot(fixture);
    assert.equal(result.pixelOnly, true, fixture);
  }
});

test("content script never extracts before an authorized capture-now request", async () => {
  const page = await browser.newPage();
  await page.goto(`${baseURL}/article.html`, { waitUntil: "load" });
  await page.addScriptTag({ path: path.join(extensionSource, "dom-extractor.js") });
  await page.evaluate(() => {
    globalThis.__extractCount = 0;
    const original = globalThis.ZBSEyeDOMExtractor.snapshot;
    globalThis.ZBSEyeDOMExtractor.snapshot = (...args) => {
      globalThis.__extractCount += 1;
      return original(...args);
    };
    globalThis.chrome = {
      runtime: {
        sendMessage: () => Promise.resolve(),
        onMessage: { addListener: (listener) => { globalThis.__captureListener = listener; } },
      },
    };
  });
  await page.addScriptTag({ path: path.join(extensionSource, "content.js") });
  await page.waitForTimeout(400);
  assert.equal(await page.evaluate(() => globalThis.__extractCount), 0);
  await page.evaluate(() => globalThis.__captureListener({
    type: "zbs-eye-capture-now", requestId: "test-request", reason: "activation",
  }));
  await page.waitForFunction(() => globalThis.__extractCount === 1);
  await page.close();
});
