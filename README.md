# airhop

Seamless AirPods handoff between a Mac and an **unrooted** Android phone. Press play on
either device and the AirPods follow; close the lid and they land on the phone.

AirPods only run Apple's switching protocol with devices whose Bluetooth Device ID says
"Apple", which Android can't fake without root. airhop replaces it with two small agents
that each decide for themselves:

- **Pixel** (`android/`): a foreground service. Forces A2DP/HFP connects through a
  [Shizuku](https://github.com/RikkaApps/Shizuku) user service, since the adb shell uid
  holds `BLUETOOTH_PRIVILEGED`.
- **Mac** (`mac/`): a LaunchAgent. Uses IOBluetooth to connect and release, and
  [`media-control`](https://github.com/ungive/media-control) to watch and drive Now Playing.

## How they know what's going on

- **The AirPods' own BLE proximity advertisement.** It carries in-ear state, a connection
  state (disconnected / idle / music / call) and, in its encrypted half, the last 3 bytes
  of the address currently holding them. The phone resolves it with the AirPods' IRK and
  decrypts it with their advertisement key. It fetches both once over AACP (L2CAP PSM
  0x1001, opcode 0x30). macOS hands the advertisement to CoreBluetooth already decrypted.
  It updates only about every 5s, so it's used for state, not for fast signalling.
- **Beacons.** Just before taking the AirPods, each side broadcasts a legacy BLE
  advertisement for 3s carrying one service UUID,
  `SHA256("airhop/v1/<mac|pixel>/<take|release>/<adv key hex>")[:16]`. The other side
  pauses and lets go. This usually takes under 200ms.

## Rules

| Event | Pixel | Mac |
|---|---|---|
| Local media starts / call starts, AirPods worn elsewhere | pause, beacon, connect, resume (~2s) | pause, beacon, connect, resume (~1.8s) |
| Other side's `take` beacon | pause, disconnect | pause, disconnect |
| AirPods worn and connected to nothing | connect (phone is home base) | — |
| Mac going to sleep | — | `release` beacon, disconnect |
| AirPods taken while playing | pause (Android's becoming-noisy also does) | pause on IOBluetooth disconnect |

## Setup

Requires macOS 14+, Android 14+ (tested on a Pixel), AirPods that send Apple's proximity
advertisement (tested with AirPods Pro 2, model `2720`), [just](https://github.com/casey/just),
Xcode command line tools, and Android Studio (the justfile uses its bundled JDK).

Pixel (USB debugging on):
```
adb install shizuku.apk && just android-shizuku   # then allow airhop in Shizuku's prompt
just android-install
```
Connect the AirPods to the phone once. The app adopts them and fetches their keys itself.
After a phone reboot, Shizuku must be restarted: open Shizuku and tap Start
(Wireless debugging), or run `just android-shizuku`. airhop posts a notification until
you do.

Mac:
```
brew install media-control
just mac-signing-setup   # once: stable signature so the Bluetooth permission survives rebuilds
just mac-install         # also copies mac.toml.example to ~/.config/airhop/mac.toml
```
Then fill in `~/.config/airhop/mac.toml`: the AirPods' Bluetooth address and the holder
suffixes for the Mac and the phone (`just mac-scan` prints the `holder=` value while each
device has the AirPods). For beacons, the Mac also needs the AirPods' advertisement key in
`~/.config/airhop/secrets.toml` as `enc_key = "<hex>"`. The phone stores it as the part after
the colon in `keys`, readable from the debug build with
`adb shell run-as dev.mteam.airhop cat shared_prefs/airhop.xml`. Without it the Mac still
works, just without the fast beacon path.

Debugging: `just mac-status`, `just mac-logs`, `just android-status`.

## Status

Early and personal: built for and tested on one Mac, one Pixel and one pair of AirPods. There are no automated tests. The Mac and Android builds both
compile from a clean checkout (`swift build`, `./gradlew assembleDebug`).
