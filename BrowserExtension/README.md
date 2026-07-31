# ZBS Eye Browser Bridge

The runtime in [`Extension/`](./Extension) is both the bundled fallback inside ZBS Eye.app and the exact
source of the Chrome Web Store ZIP. Do not maintain a second copy.

The extension starts disabled. After explicit enablement, its content scripts announce only that a document
changed. They do not extract text until the service worker authenticates the local ZBS Eye process with an
HMAC challenge and confirms that recording is active. Only the active tab in the focused Chromium window is
accepted.

```bash
cd BrowserExtension
npm ci
npm test
cd ..
scripts/package-browser-extension.sh
```

For an unpacked install, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and
select `BrowserExtension/Extension`.

The write-only token is separate from the read-capable REST/MCP token. Browser Bridge can post snapshots and
heartbeats to loopback, but cannot read Search, Timeline, screenshots, calls, or audio.
