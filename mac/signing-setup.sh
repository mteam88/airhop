#!/bin/zsh
# One-time: create a self-signed code-signing identity in its own keychain. Signing every build
# with the same identity keeps macOS's Bluetooth permission grant across rebuilds (ad-hoc
# signatures change per build, so TCC re-prompts and blocks IOBluetooth until answered).
set -euo pipefail
DIR=~/.config/airhop/signing
KC=$DIR/airhop.keychain-db
mkdir -p $DIR && chmod 700 $DIR && cd $DIR
[[ -e $KC ]] && { echo "already set up: $KC"; exit 0; }
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=airhop local signing" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out airhop.p12 -inkey key.pem -in cert.pem -passout pass:airhop
security create-keychain -p airhop $KC
security set-keychain-settings $KC
security unlock-keychain -p airhop $KC
security import airhop.p12 -k $KC -P airhop -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k airhop $KC >/dev/null
rm airhop.p12
echo "created $KC"
