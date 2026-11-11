#!/bin/sh
# One-time: creates a self-signed code-signing certificate "TabletPen Dev". Free (no Apple
# Developer account). macOS ties the Accessibility permission to this certificate, so rebuilding
# the app does not reset the permission.
#
# The key lives in its own keychain (~/Library/Keychains/tabletpen-dev.keychain-db) with a fixed
# password, so signing never shows a keychain prompt and the login keychain is left alone. The key
# only signs this locally built app; it is not trusted by any other Mac.
set -e
KC="$HOME/Library/Keychains/tabletpen-dev.keychain-db"
PW=tabletpen
if [ -f "$KC" ] && security find-identity -p codesigning "$KC" | grep -q '"TabletPen Dev"'; then echo "identity already exists"; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/c.cnf" <<'C'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=TabletPen Dev
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
C
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/c.cnf" -keyout "$T/k.pem" -out "$T/c.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/id.p12" -passout pass:$PW -name "TabletPen Dev" 2>/dev/null
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"                       # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$T/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
# Add to the keychain search list so codesign can find the identity.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "created identity 'TabletPen Dev' in $KC"
