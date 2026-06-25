#!/bin/bash
set -euo pipefail

# Creates a stable, self-signed code-signing identity in a dedicated keychain so that
# rebuilds keep the same signature — macOS then remembers Input Monitoring / Accessibility
# grants across rebuilds. Fully local; nothing is added to the system trust store.

IDENTITY="Murmur Self-Signed"
KEYCHAIN="murmur-signing.keychain"
KEYCHAIN_DB="$HOME/Library/Keychains/${KEYCHAIN}-db"
PW="murmur-local"
OPENSSL="/usr/bin/openssl"   # LibreSSL — produces keychain-importable PKCS#12

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "signing identity '$IDENTITY' already present"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.conf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PW" -name "$IDENTITY" 2>/dev/null

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$PW" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PW" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null

OIFS="$IFS"; IFS=$'\n'
existing=($(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'))
IFS="$OIFS"
security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN_DB"

echo "created signing identity '$IDENTITY' in $KEYCHAIN"
