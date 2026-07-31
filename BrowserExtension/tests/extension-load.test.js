import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionPath = path.join(root, "Extension");

const chromiumPath = process.env.PLAYWRIGHT_CHROMIUM_PATH;

test("the unpacked MV3 runtime loads and remains disabled by default", {
  skip: !chromiumPath,
}, async () => {
  const profile = await mkdtemp(path.join(os.tmpdir(), "zbseye-browser-extension-"));
  let context;
  try {
    context = await chromium.launchPersistentContext(profile, {
      headless: false,
      executablePath: chromiumPath,
      args: [
        `--disable-extensions-except=${extensionPath}`,
        `--load-extension=${extensionPath}`,
      ],
    });
    let [worker] = context.serviceWorkers();
    worker ||= await context.waitForEvent("serviceworker", { timeout: 10_000 });
    assert.match(worker.url(), /^chrome-extension:\/\/.+\/src\/service-worker\.js$/);
    const extensionID = new URL(worker.url()).hostname;
    const page = await context.newPage();
    await page.goto(`chrome-extension://${extensionID}/src/options.html`, { waitUntil: "load" });
    const state = await page.evaluate(async () => ({
      manifest: chrome.runtime.getManifest(),
      stored: await chrome.storage.local.get(["captureEnabled", "bridgeStatus"]),
    }));
    assert.equal(state.manifest.version, "0.6.0");
    assert.deepEqual(state.manifest.permissions, ["storage"]);
    assert.equal(state.stored.captureEnabled, false);
    assert.equal(state.stored.bridgeStatus, "disabled");
    await page.close();
  } finally {
    await context?.close();
    await rm(profile, { recursive: true, force: true });
  }
});
