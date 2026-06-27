#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity named "OCR Studio Local"
# in the login keychain. This gives the app a consistent code-signing identity
# across rebuilds, so the macOS scanner (TCC) permission grant persists instead
# of re-prompting every time you rebuild with ad-hoc signing.
#
# This is OPTIONAL — the app builds and runs fine with ad-hoc signing.
#
# Note: macOS may prompt for your login keychain password during import/trust.
# If this script can't create a usable identity in your environment, create one
# via Keychain Access → Certificate Assistant → "Create a Certificate…"
#   Name: OCR Studio Local   Identity Type: Self Signed Root
#   Certificate Type: Code Signing
set -euo pipefail

NAME="OCR Studio Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists. Nothing to do."
  exit 0
fi

echo "==> Generating self-signed code-signing certificate…"
cat > "$TMP/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = OCR Studio Local
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass: >/dev/null 2>&1 || \
openssl pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass: >/dev/null 2>&1

echo "==> Importing into login keychain (you may be prompted for your password)…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> Trusting the certificate for code signing…"
security add-trusted-cert -d -r trustAsRoot -p codeSign \
  -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "==> Success. \"$NAME\" is now available for code signing."
else
  echo "!! Could not register a usable code-signing identity automatically."
  echo "   Create one via Keychain Access (see the comment block in this script)."
  exit 1
fi
