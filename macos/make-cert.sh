#!/bin/bash
# Creates a local code-signing certificate, "sniplite Local Signing", in your login keychain.
# Run it once. build.sh then signs with it, so every build keeps the same identity and macOS
# keeps the Screen Recording / Accessibility permissions across rebuilds (an ad hoc signature
# changes with every build, and macOS then treats each build as a new app).
# The certificate is only good for signing on this Mac; remove it in Keychain Access any time.
set -euo pipefail
NAME="sniplite Local Signing"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" is already there."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=sniplite
LEGACY=$(openssl version | grep -q "^OpenSSL 3" && echo -legacy || true)
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout pass:$PASS
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P $PASS -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build.sh; macOS asks for the permissions one last time."
