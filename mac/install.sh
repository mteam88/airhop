#!/bin/zsh
# Build Airhop.app, ad-hoc sign it, install to ~/Applications and (re)load the LaunchAgent.
#   ./install.sh            build + install + load
#   ./install.sh --bundle   only build dist/Airhop.app
set -euo pipefail
cd "${0:A:h}"

LABEL=com.mteam.airhop
APP=dist/Airhop.app
AGENT_PLIST=~/Library/LaunchAgents/$LABEL.plist

swift build -c release
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp .build/release/airhop $APP/Contents/MacOS/airhop
cp Resources/Info.plist $APP/Contents/Info.plist
KC=~/.config/airhop/signing/airhop.keychain-db
if [[ -e $KC ]]; then
    security unlock-keychain -p airhop $KC
    IDENTITY=$(openssl x509 -in ${KC:h}/cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
    codesign --force --keychain $KC --sign $IDENTITY --identifier $LABEL $APP
else
    echo "warning: no signing identity (run signing-setup.sh); ad-hoc signing re-prompts for Bluetooth on every build"
    codesign --force --sign - --identifier $LABEL $APP
fi
echo "built $APP"
[[ "${1:-}" == "--bundle" ]] && exit 0

launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents ~/Library/Logs ~/.config/airhop
[[ -e ~/.config/airhop/mac.toml ]] || cp mac.toml.example ~/.config/airhop/mac.toml
rm -rf ~/Applications/Airhop.app
cp -R $APP ~/Applications/Airhop.app
sed "s|__HOME__|$HOME|g" Resources/$LABEL.plist > $AGENT_PLIST
launchctl bootstrap gui/$UID $AGENT_PLIST
echo "installed ~/Applications/Airhop.app and loaded $LABEL (log: ~/Library/Logs/airhop.log)"
echo "first run: approve the Bluetooth prompt for Airhop (System Settings > Privacy & Security > Bluetooth)"
