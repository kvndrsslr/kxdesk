#!/usr/bin/env bash
#
# Sign `kxdesk.app` with a stable local identity, so that the Accessibility grant
# the event tap needs survives a rebuild.
#
# macOS keys that grant to the *code identity* it was given for. An ad-hoc
# signature - what the linker leaves, and what `codesign -s -` writes - has no
# identity beyond the binary's cdhash, so every build is a different application:
# the entry stays in the Accessibility list, switched on, and matches nothing, and
# the daemon reports the tap was refused. A self-signed certificate gives every
# build the same identity - the bundle identifier plus that certificate - and the
# grant then holds across `zig build`, `brew upgrade` and the Cellar path changing
# under it.
#
# The certificate is created on first use and reused after that; no trust setting
# and no keychain password are needed, because nothing outside codesign ever
# verifies it. If there is no keychain to put it in, the bundle is signed ad-hoc
# instead and the build still succeeds - the grant then has to be given again
# after each deploy, which is the behaviour this script exists to avoid.
set -euo pipefail

bundle=${1:?usage: sign.sh <name.app>}
certificate=kxdesk-cert

# Both the identifier and the inner binary come from the bundle itself, so the
# daemon's and the grabber's bundles are signed by the same script with their own
# identities - which is the whole point of the bundle.
plist="$bundle/Contents/Info.plist"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
inner="$bundle/Contents/MacOS/$executable"

if ! security find-certificate -c "$certificate" >/dev/null 2>&1; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    # The codeSigning extended key usage is what makes the identity usable for
    # signing at all; without it `security find-identity -p codesigning` filters
    # the certificate out and codesign refuses it.
    cat > "$work/openssl.cnf" <<EOF
[req]
distinguished_name = distinguished
prompt = no
x509_extensions = extensions

[distinguished]
CN = $certificate
O = kxdesk
C = US

[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

    password=kxdesk-cert-import
    openssl genrsa -out "$work/key.pem" 2048 2>/dev/null
    openssl req -new -x509 -key "$work/key.pem" -out "$work/cert.pem" \
        -days 3650 -config "$work/openssl.cnf" 2>/dev/null
    # 3DES and SHA-1 for both ciphers: they are what the system's LibreSSL and an
    # OpenSSL 3 both write, and what `security import` reads. The password is a
    # throwaway, not protection - openssl 3 refuses an empty one.
    openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -out "$work/cert.p12" -inkey "$work/key.pem" -in "$work/cert.pem" \
        -passout "pass:$password" 2>/dev/null

    if ! security import "$work/cert.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" -P "$password" \
        -T /usr/bin/codesign >/dev/null 2>&1; then
        echo "sign: no signing identity to create; signing ad hoc" >&2
        certificate=-
    fi
fi

# The inner binary first and the bundle second: signing the bundle seals every
# file it contains, and a Mach-O inside that does not verify fails the seal.
codesign --force --sign "$certificate" --identifier "$identifier" "$inner"
codesign --force --sign "$certificate" --identifier "$identifier" "$bundle"
codesign --verify --strict "$bundle"
