# Steer

Steer is an iPhone and iPad app to control coding agents on your computer. It connects over SSH and lists your Herdr, tmux, and Zellij sessions. Tap a session to attach to it.

Steer is free and has the MIT license. It has no account, no analytics, and no in-app purchases.

## Features

- Session list: Herdr agents, tmux sessions, and Zellij sessions, each with a live preview.
- Terminal: SwiftTerm, hardware keyboard, a toolbar that you can change, a D-pad, and gestures.
- Transports: SSH, Mosh, and Eternal Terminal (ET). Auto mode tries Mosh, then ET, then SSH.
- Sidebar: Herdr workspaces with their Git state and tabs. On iPad, the sidebar can stay open.
- Message bar: type or dictate a prompt, then send it. Dictation runs on the device.
- Alerts: a local alert when an agent needs you or is done.
- Remote tools: Git diffs, a file browser, file upload and download, and a web preview.
- Companion (optional): Claude and Codex conversations, Claude approvals, and usage.

[ios/APP.md](ios/APP.md) has the full list of features and limits.

## How it works

```
iPhone / iPad                                   Your computer
┌──────────────────────────┐                   ┌──────────────────────────────┐
│ Steer                    │  SSH (TCP 22)     │ sshd                         │
│  ├ SSH session ──────────┼──────────────────▶│  ├ shell, tmux, zellij       │
│  │   exec channels       │                   │  ├ herdr CLI                 │
│  │   port forwards       │                   │  └ companion (127.0.0.1)     │
│  ├ Mosh client ──────────┼── UDP ───────────▶│ mosh-server                  │
│  └ ET client ────────────┼── TCP 2022 ──────▶│ etserver / etterminal        │
└──────────────────────────┘                   └──────────────────────────────┘
```

### SSH

Each host starts with an SSH connection. Steer uses a copy of Apple's swift-nio-ssh with two additions: RSA keys and agent forwarding. [PATCHES.md](ios/Vendor/swift-nio-ssh/PATCHES.md) lists the changes.

On the first connection, you approve the host key. After that, Steer refuses a different key. Passwords and private keys stay in the iOS Keychain. You can lock them with Face ID.

The terminal is one channel on the SSH connection. Session lists, Git commands, and file transfers each use a separate exec channel without a PTY. These commands do not type into a running agent.

### Mosh and ET

For Mosh or ET, Steer uses SSH to start the server. Then the terminal moves to the new transport. Steer has its own Swift client for each protocol.

- Mosh: SSH starts `mosh-server`, which gives a UDP port and a key. Steer sends UDP packets encrypted with AES-OCB. The session continues after sleep and network changes. On a slow link, Steer shows your typing before the server echoes it.
- ET: SSH starts `etterminal`, which gives a session id and a passkey. Steer connects to `etserver` over TCP and encrypts with XSalsa20-Poly1305. After a reconnect, each side sends the data that the other side did not get.

Steer starts a Mosh or ET server only for a terminal on the screen. The session lists on the home screen use only SSH. When you close a tab, Steer stops the server that it started.

The SSH connection stays open below a Mosh or ET terminal. If SSH drops, Steer connects it again and the terminal continues.

### Sessions

Steer runs `herdr session list`, `herdr agent list`, and `tmux ls`. If tmux is not installed, Steer runs `zellij list-sessions`. Non-interactive SSH has a short `PATH`, so Steer adds Homebrew, `~/.local/bin`, and `/usr/local/bin`.

To attach, Steer opens a new terminal that runs the attach command, for example `tmux attach -t <name>`. For a Herdr agent, Steer streams the pane through `herdr`. After a reconnect, Steer attaches to the same session again.

### Alerts

While a host is connected, Steer runs `herdr agent list` every 3 seconds. When an agent asks for permission or is done, Steer shows a local alert. Steer has no push server, so alerts stop when iOS suspends the app.

### Companion

The companion is an optional Node 22 program on your computer. It has no dependencies. Claude Code hooks send permission requests and questions to it, and you answer them on the phone.

The companion listens only on `127.0.0.1:43197`. Steer connects to it through an SSH port forward, so the port is not open to the network. To set it up, read [companion/README.md](companion/README.md).

## Requirements

- A computer with an SSH server. On a Mac, turn on System Settings → General → Sharing → Remote Login.
- A network path from the phone to the computer, for example Tailscale or the same Wi-Fi.
- Optional: `mosh`, `et`, `herdr`, `tmux`, or `zellij` on the computer.
- To build: Xcode 26 or newer, and XcodeGen (`brew install xcodegen`).
- iOS 17 or newer. On-device dictation needs iOS 26.

## Build and run

```sh
cd ios
xcodegen generate
open Steer.xcodeproj
```

To run on a device, put your Apple Team ID in `ios/Signing.local.xcconfig`. Git ignores this file.

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Select your iPhone or iPad in Xcode, then press Run. In Steer, add a host with the address, user name, and a password or key. Steer can also make an Ed25519 key for you. It gives you a command to add the key on your computer.

[ios/README.md](ios/README.md) has more build and test steps.

## Tests

```sh
./scripts/check.sh          # Git and upload checks, companion tests, build, unit tests
./scripts/e2e.sh            # end-to-end tests on a Simulator
./scripts/e2e.sh --device   # end-to-end tests on a connected iPhone
```

`e2e.sh` starts temporary servers on your computer: OpenSSH on port 2299, `etserver` on port 2022, and a separate tmux. The tests use the real app with these servers. After the tests, the script makes sure that no `mosh-server`, `etterminal`, or tmux client is left on the computer.

The script does not change `~/.ssh` or your own tmux sessions. It needs `brew install mosh et tmux`. For `--device`, the iPhone must be on the same Wi-Fi as the computer.

## Repository layout

```
ios/Steer/Models      hosts, preferences, session targets, key bindings
ios/Steer/Services    SSH, Mosh, ET, discovery, Herdr, dictation, Keychain
ios/Steer/Views       SwiftUI screens
ios/SteerTests        unit and live-server tests
ios/SteerUITests      end-to-end tests
ios/Vendor            swift-nio-ssh with local patches
companion             the optional companion (Node)
scripts               test and check scripts
```

## License

MIT. See [LICENSE](LICENSE). The fonts and logos have their own licenses: [ios/Steer/Fonts/NOTICE.txt](ios/Steer/Fonts/NOTICE.txt) and [ios/Steer/MultiplexerLogoNotices.txt](ios/Steer/MultiplexerLogoNotices.txt).
