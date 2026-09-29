# --- mac (airhop agent) ---

# one-time: stable signing identity so the Bluetooth permission survives rebuilds
mac-signing-setup:
    mac/signing-setup.sh

# build dist/Airhop.app (ad-hoc signed) without installing
mac-bundle:
    mac/install.sh --bundle

# build, install to ~/Applications and load the LaunchAgent
mac-install:
    mac/install.sh

# stop and remove the LaunchAgent (app stays in ~/Applications)
mac-uninstall:
    -launchctl bootout gui/$(id -u)/com.mteam.airhop
    rm -f ~/Library/LaunchAgents/com.mteam.airhop.plist

# run the agent in the foreground; pass --dry-run to only log actions
mac-run *args:
    cd mac && swift build && .build/debug/airhop run {{args}}

# show the running agent's state and recent events
mac-status:
    ~/Applications/Airhop.app/Contents/MacOS/airhop status

mac-enable:
    ~/Applications/Airhop.app/Contents/MacOS/airhop enable

mac-disable:
    ~/Applications/Airhop.app/Contents/MacOS/airhop disable

# print our AirPods' decoded BLE adverts
mac-scan seconds="15":
    cd mac && swift build && .build/debug/airhop scan {{seconds}}

mac-logs:
    tail -f ~/Library/Logs/airhop.log

# --- android (airhop app) ---

export JAVA_HOME := "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
apk := "android/app/build/outputs/apk/debug/app-debug.apk"

android-build:
    cd android && ./gradlew -q assembleDebug

# build, install over adb, grant permissions, exempt from doze, (re)start the service
android-install: android-build
    adb install -r {{apk}}
    for p in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE POST_NOTIFICATIONS READ_PHONE_STATE; do adb shell pm grant dev.mteam.airhop android.permission.$p; done
    adb shell dumpsys deviceidle whitelist +dev.mteam.airhop >/dev/null
    adb shell am start-foreground-service -n dev.mteam.airhop/.HopService >/dev/null

# service state + recent decisions
android-status:
    adb shell dumpsys activity service dev.mteam.airhop/.HopService

# start the Shizuku server over USB adb (needed after every phone reboot, or use Shizuku's Wireless debugging start)
android-shizuku:
    adb shell "$(adb shell pm path moe.shizuku.privileged.api | sed 's/package://; s/base.apk//' | tr -d '\r')lib/arm64/libshizuku.so"
