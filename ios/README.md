# Steer iOS

This folder has the iOS app. The bundle id is `app.steer.ios`. [APP.md](APP.md) has the full list of features and limits.

## Build and test

To run all local checks, use this command from the repository root:

```bash
./scripts/check.sh
```

The script uses the first iPhone Simulator that it finds. To use a different Simulator, set `STEER_SIMULATOR_ID`.

To build without signing:

```bash
cd ios
xcodegen generate
xcodebuild -project Steer.xcodeproj -scheme Steer \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

To run the unit tests, use a Simulator that does not have your saved hosts. Get its id from `xcrun simctl list devices available`.

```bash
xcodebuild -project Steer.xcodeproj -scheme Steer \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

The Keychain tests need this ad-hoc signing. Do not install an unsigned test build on a Simulator that has your saved hosts. If you do, Steer cannot read its Keychain items on that Simulator.

Other checks:

```bash
sh ../scripts/check-git.sh                  # remote Git commands
sh ../scripts/check-upload.sh               # atomic file upload
node --test ../companion/test/*.test.mjs    # companion
```

## End-to-end tests

```bash
../scripts/e2e.sh            # on a Simulator
../scripts/e2e.sh --device   # on a connected iPhone
```

The script starts temporary servers on your computer: OpenSSH, `mosh-server`, `etserver`, and a separate tmux. `LiveServerTests` test RSA, agent forwarding, and each transport. `SteerUITests` use the real app and then check that nothing is left running on the computer.

The script needs `brew install mosh et tmux`. `etserver` uses port 2022. The script does not change `~/.ssh`, your tmux sessions, or your Herdr sessions.

For `--device`, prepare the iPhone:

1. Connect the iPhone to the same Wi-Fi as the computer.
2. Unlock the iPhone and set Auto-Lock to Never.
3. Turn on Settings → Developer → Enable UI Automation.
4. Close iPhone Mirroring on the computer.

## Run on an iPhone or iPad

1. On the computer, turn on Remote Login.
2. Connect the phone and the computer through Tailscale or the same network.
3. Put your Apple Team ID in `Signing.local.xcconfig`, as shown below.
4. Run `xcodegen generate`, then open `Steer.xcodeproj`.
5. Select the iPhone or iPad, then press Run.
6. In Steer, add a host. Enter the address, user name, port, and a password or key.
7. To use a new key, tap **Generate Ed25519 Key** in the host editor.
8. Share the command that Steer gives you to the computer, then run it one time.

```xcconfig
// Signing.local.xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Git ignores `Signing.local.xcconfig`. `xcodegen generate` and `scripts/check.sh` make the project again, so a team that you select only in Xcode is lost. To change the team, edit this file. Simulator builds do not need the file.

Tailscale access and Face ID are manual checks on a real device. The tests do not contain credentials.
