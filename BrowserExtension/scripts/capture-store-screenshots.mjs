import { mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright-core";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const optionsURL = pathToFileURL(path.join(root, "Extension/src/options.html")).href;
const output = path.join(root, "store/screenshots");
await mkdir(output, { recursive: true });

const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.CHROME_PATH
    || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
});

async function capture(name, language, stored) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.addInitScript(({ language, stored }) => {
    globalThis.chrome = {
      i18n: { getUILanguage: () => language },
      storage: {
        local: {
          get: async () => stored,
          set: async (update) => Object.assign(stored, update),
        },
        onChanged: { addListener: () => {} },
      },
    };
  }, { language, stored });
  await page.goto(optionsURL, { waitUntil: "load" });
  await page.screenshot({ path: path.join(output, name) });
  await page.close();
}

await capture("01-connected-en-1280x800.png", "en-US", {
  captureEnabled: true,
  browserIngestToken: "write-only-token",
  bridgeStatus: "connected",
  bridgeError: "",
});
await capture("02-private-by-default-ru-1280x800.png", "ru-RU", {
  captureEnabled: false,
  browserIngestToken: "",
  bridgeStatus: "disabled",
  bridgeError: "",
});

await browser.close();
