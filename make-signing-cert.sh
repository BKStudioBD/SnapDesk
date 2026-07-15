#!/bin/bash
#
# Creates a self-signed "SnapDesk Dev" code-signing certificate in your login
# keychain. Run this ONCE. After that, ./build.sh signs with a STABLE identity,
# so macOS permissions (Screen Recording, Accessibility) keep working across
# rebuilds instead of resetting every time.
#
# This certificate is local and self-signed — it is NOT for distribution. It
# only makes the local build's signature stable. To remove it later:
#   security delete-certificate -c "SnapDesk Dev" ~/Library/Keychains/login.keychain-db
#
set -euo pipefail

NAME="SnapDesk Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✅ '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "▶ Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:snapdesk -name "$NAME" >/dev/null 2>&1

echo "▶ Importing into login keychain (codesign-accessible)…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P snapdesk -T /usr/bin/codesign -A

# Mark the cert TRUSTED for code signing. Without this it isn't a "valid"
# codesigning identity, macOS can't fully validate the app's designated
# requirement, and it falls back to keying TCC grants (Screen Recording,
# Accessibility) on the exact binary hash — which changes every rebuild, so
# permissions reset constantly. Trusting the cert makes the identity valid →
# the DR (identifier + this cert) is stable across rebuilds → grants persist.
echo "▶ Trusting the certificate for code signing (so permissions persist)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

echo "✅ '$NAME' created & trusted. Now run ./build.sh — it will sign with this identity."
echo "   (The first build may pop a one-time 'codesign wants to use a key' dialog —"
echo "    click Always Allow.)"
