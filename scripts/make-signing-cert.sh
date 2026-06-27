#!/bin/bash
# Creates a self-signed code-signing certificate "ZBS Eye Dev" in the login keychain (WITHOUT a paid
# Apple Developer account). A stable signing identity = TCC permissions (Screen Recording,
# Accessibility, Microphone) and Keychain ACL survive rebuilds — the main dev pain goes away.
#
# Run ONCE. Trust is placed into the USER trust domain (no sudo) — macOS
# will show a GUI dialog "changes are being made to your trust settings", confirm with Touch ID/password.
#
# NB: the first build with the new signature will ONCE reset already-granted TCC permissions (re-grant in System
# Settings: turn ZBSEye off and back on in Screen Recording, then Microphone).
set -euo pipefail

NAME="ZBS Eye Dev"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Already have a working code-signing identity? — don't recreate it (a new keypair = TCC
# breaks again). Reuse the stable identity.
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✅ Certificate \"${NAME}\" already exists and is trusted — reusing:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

# Leftover from a previous partial run (cert without trust / without private key) — remove from the
# login keychain, otherwise a repeat import gives a second cert → codesign: ambiguous identity.
echo "→ Cleaning up previous certificate copies from the login keychain (if any)…"
while security delete-certificate -c "$NAME" "$LOGIN_KC" >/dev/null 2>&1; do :; done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extensions config: codeSigning EKU is mandatory, otherwise codesign won't accept the identity.
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

# EXPLICITLY the system /usr/bin/openssl (LibreSSL): Homebrew OpenSSL 3.x encrypts the p12 with algorithms
# that macOS `security import` doesn't understand → "MAC verification failed (wrong password?)".
OPENSSL=/usr/bin/openssl

"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:zbseye -name "$NAME"

# Import the key+cert into the login keychain. -T codesign/security — add them to the key's ACL.
security import "$TMP/cert.p12" -k "$LOGIN_KC" -P zbseye \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust in the USER trust domain (no -d/sudo): a GUI dialog appears, confirm with Touch ID.
echo "→ Trusting the certificate (a system dialog will appear — confirm with Touch ID)…"
security add-trusted-cert -r trustRoot -k "$LOGIN_KC" "$TMP/cert.pem"

# Partition-list, so codesign doesn't ask on every build. Without a terminal the keychain password
# can't be asked → best-effort; on failure the first signing shows a GUI "Always Allow" (click once).
echo "→ Partition-list for the key (may not pass without a password — then \"Always Allow\" on the first build)…"
security set-key-partition-list -S apple-tool:,apple: -s -D "$NAME" "$LOGIN_KC" >/dev/null 2>&1 \
  && echo "   partition-list set" \
  || echo "   skipped — confirm \"Always Allow\" in the dialog on the first build"

echo ""
echo "✅ Done:"
security find-identity -v -p codesigning | grep "$NAME"
echo ""
echo "Next: bash scripts/build-release.sh → install into /Applications/ZBS Eye.app"
echo "⚠️  The first build with this signature will reset TCC permissions once — re-grant Screen Recording"
echo "   (toggle off/on in System Settings) and Microphone."
