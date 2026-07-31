# ZBS Eye Browser Bridge privacy

Last updated: July 31, 2026

ZBS Eye Browser Bridge is an optional, local-only extension for ZBS Eye on macOS. It helps ZBS Eye index
rendered web text that macOS Accessibility cannot reliably expose in Chromium browsers.

## What it handles

After you explicitly enable Browser Capture and add the write-only token, the extension may handle:

- visible rendered text from the active tab in the focused Chromium window;
- that page's URL and title;
- a random local browser-instance identifier used to reject stale or mismatched snapshots.

It excludes password fields, all `input`, `textarea`, `select`, and `option` values, hidden or inert elements,
scripts, styles, templates, SVG source, and background tabs. The write-only token cannot read ZBS Eye history.

## When it handles page text

Before extracting DOM text, the extension authenticates the process listening on ZBS Eye's fixed loopback
ports using an HMAC challenge derived from the write-only token. It also checks that ZBS Eye is currently
recording. If ZBS Eye is closed, paused, unauthenticated, or the tab is not active in the focused browser
window, the extension does not extract page text.

## Where data goes

Browser Bridge sends requests only to `127.0.0.1` or `localhost` on this Mac. It has no cloud endpoint,
analytics, advertising, telemetry, account, or remote code. ZBS Eye stores accepted text in the same local
database as other Timeline text. Data is not sold, shared with third parties, or used for advertising,
credit decisions, or unrelated purposes.

## Retention and deletion

Browser text follows the retention and deletion settings of the local ZBS Eye installation. You can disable
the extension at any time, remove it from the browser, pause ZBS Eye, or delete local history in ZBS Eye.
Removing the extension deletes its browser-local settings under the browser's normal extension-data rules;
it does not silently delete history already stored by ZBS Eye.

## Permissions

- **Storage:** keeps the explicit enable switch, write-only token, random instance ID, and local connection status.
- **Site access on HTTP/HTTPS pages:** runs the content script that waits for an authenticated capture request and
  then extracts eligible rendered text. Page data is never sent to a remote server.
- **Loopback host access:** checks ZBS Eye health and posts snapshots and heartbeats to the local app.

The extension does not request the `tabs`, `webNavigation`, browsing-history, downloads, cookies, clipboard,
geolocation, microphone, camera, or native-messaging permissions.

## Contact and source

The complete source is published in this repository. Privacy or security reports can be opened through the
repository's public issue tracker without including private page content or tokens.
