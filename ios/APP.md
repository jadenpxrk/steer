# Steer features and limits

Steer is an iPhone and iPad terminal for a computer with an SSH server. The [companion](../companion/README.md) is optional. It adds agent conversations and approvals.

## Hosts and sign-in

- Each host has an address, a list of fallback addresses, a user name, a port, and an optional startup command. Steer tries the fallback addresses in order.
- Sign-in uses a password or an OpenSSH private key. Steer accepts Ed25519, ECDSA (P-256, P-384, P-521), and RSA keys. RSA keys must be 2048 bits or more.
- A key must not have a passphrase, because the Keychain protects it. To remove a passphrase, run `ssh-keygen -p -N "" -f <key>`.
- If a host has a key and a password, Steer tries the key first.
- Steer keeps passwords and keys in the iOS Keychain. You can lock them with Face ID or the device passcode.
- Steer can make an Ed25519 key on the device. It gives you a one-line command that adds the public key to `authorized_keys`.
- On the first connection, you approve the host key. After that, Steer refuses a different key.
- Jump hosts work like `ssh -J`. Each host keeps its own credentials and host key. Only one jump is possible, so a jump host cannot have its own jump host.
- When you delete a jump host, Steer asks you to confirm. It shows the hosts that will then connect directly.
- If Steer cannot connect, the error shows the last address and port that it tried. It tells you to check that the computer is on and on the network, for example on Tailscale.
- Agent forwarding works like `ssh -A`. While you are connected, programs on the host can sign with the key of that host.
- The `STEER_CLIENT env` setting is off by default. When it is on, new shells get `STEER_CLIENT=1`. Over SSH, Steer starts the shell as `STEER_CLIENT=1 exec $SHELL -l`, because sshd usually drops other variables.

## Terminal

- The terminal is SwiftTerm with `TERM=xterm-256color` and a login shell. It accepts the software keyboard, a hardware keyboard, and CJK input.
- Steer sends the startup command only after the shell starts.
- Steer keeps your recent terminals open while you use other screens. Each one keeps up to 2 MB of output.
- Steer can open your most recent terminal again when the app starts.
- When you tap a link, Steer asks before it opens it. You can open or copy the link. This works for OSC 8 links, plain URLs, and domain names.
- When a program on the host copies text with OSC 52, Steer puts the text on the phone clipboard.
- Zen mode hides the toolbar and the status bar. A small handle opens a ring of terminal actions.
- The Right Click toolbar key makes your next tap a right click. Use it in apps that read the mouse, such as tmux menus, vim, and htop.
- Deep links: `steer://open?host=<name or address>`. Add `&tmux=<session>`, `&zellij=<session>`, or `&pane=<herdr pane>&herdr-session=<name>` to open a session.

## Mosh and ET

- Each host has a connection type: Auto, SSH, Mosh, or ET. New hosts use Auto.
- Auto tries Mosh, then ET, then SSH. Mosh works only if `mosh-server` replies over UDP in 5 seconds.
- If Mosh and ET both fail, Steer uses SSH. It continues to use SSH until you close the session or change the connection settings.
- Steer has its own Mosh client (protocol 2). The terminal continues after sleep, network changes, and SSH drops.
- Steer has its own ET client (protocol 6, XSalsa20-Poly1305). It connects to `etserver` on TCP port 2022. After sleep or a network change, it connects again. Each side then sends the data that the other side did not get.
- SSH stays open below a Mosh or ET terminal. Steer uses it to start the server, list sessions, run tools, and forward ports. If SSH drops, Steer connects it again.
- Mosh needs `mosh-server` on the host. ET needs `etserver` running on the host. Neither works through a jump host. Jump hosts and agent forwarding work only with SSH.
- For Mosh, you can set a UDP port range and the path to `mosh-server`. For ET, you can set the TCP port.
- Steer starts a Mosh or ET server only for a terminal on the screen. The session lists on the home screen use only SSH.
- A tab that opens a tmux or Zellij session starts its server with the attach command. If the new server does not reply, the tab keeps its shell and shows Retry.
- With Mosh, Steer shows your typing underlined before the server echoes it. This starts when the round trip is more than 30 ms. It starts only after the server shows an earlier key from the same burst, so Steer never shows a hidden password. It does not work in full-screen apps.
- ET does not show typing before the echo.
- If the server sends nothing for 10 seconds, the tab shows "No contact", the last time that Steer got data, and a Reconnect button. Both transports continue to try in the background.
- When the app returns to the foreground or the network changes, Steer checks the connection. A good ET connection stays open. A dead ET connection connects again and sends the missed data. Mosh opens a new UDP socket.
- etserver 7.0 stops when it gets TERMINAL_CLOSE. So, when you close an ET session, Steer stops its `etterminal` over SSH. Steer finds the process by a tag that it sets. The shell and the programs in it get a normal hangup.
- If SSH is down when you close an ET session, the remote shell stays until it exits.

## Herdr, tmux, and Zellij

- Steer lists Herdr agents and sessions, and tmux sessions. If tmux is not installed, it lists Zellij sessions.
- Each list command runs on a separate SSH channel without a PTY. Steer adds `~/.local/bin`, Homebrew, and `/usr/local/bin` to `PATH`, because non-interactive SSH has a short `PATH`.
- To attach, Steer opens a new terminal that runs the attach command. Steer never types a command into a running agent.
- After a reconnect, Steer attaches to the same session again.
- To open the sidebar, use ⋯ → Sidebar, the toolbar key, or Command-Shift-J. On iPhone, the sidebar slides over the terminal. On iPad, it is a column.
- For Herdr, the sidebar shows workspaces with the Git branch, ahead and behind counts, and changes. Below each workspace are its tabs. A tab has the name of the tab or of its agent. An orange dot shows an agent that needs you.
- For tmux, the sidebar shows the windows of the session.
- The search box finds parts of names.
- ＋ makes a workspace, a tab, or a Git worktree.
- Long-press a workspace, tab, or agent to rename it, close it, or copy its id.
- Swipe with two fingers to go to the next or previous tab.

## Input

- The toolbar has keys that you can add, remove, and move. The arrow key opens a D-pad.
- The D-pad has arrows and two corner keys, Interrupt and Backspace by default. To change them, go to Gestures.
- You can make shortcuts from text or keys, for example `C-b, S-t`, `F12, h`, `S-Tab`, or `text:/clear`. Steer sends each step 50 ms after the one before it.
- Steer has shortcut packs for Ctrl keys, tmux, and agents.
- Pinch to change the text size. You can set actions for two-finger taps and swipes.
- You can set actions for the volume buttons, for example Escape, Enter, Ctrl, right click, or a shortcut. The system volume does not change, but at mute or full volume Steer changes it a little. The buttons do not work while the app is in the background or while you dictate.
- Hardware keyboard commands:

  | Keys | Action |
  |---|---|
  | Command-O | Sessions |
  | Command-N | New session |
  | Command-W | Close session |
  | Command-1 to 9 | Recent session |
  | Command-K | Shortcuts |
  | Command-Shift-J | Sidebar |
  | Command-Shift-C | Message bar |
  | Command-Shift-R | Remote Tools |
  | Command-Shift-Z | Zen mode |

- A setting hides the toolbar while a hardware keyboard is connected.
- Option can send Meta.

## Appearance

- Themes apply to the full app. You can import and export a theme as JSON.
- You can set the font, the text size, ligatures, the cursor style and blink, and the CJK fallback font. You can import font files that iOS accepts.
- Scrollback is from 1,000 to 100,000 lines.
- A setting keeps the screen on.
- The home screen is the same on iPhone and iPad. It has search, previews of your workspaces, and your hosts.
- The home search filters while you type. To close the keyboard, tap the keyboard button, press Search, or scroll.

## Message bar

- Tap the chat button or press Command-Shift-C. The bar opens below the terminal, and the terminal gets smaller so that you can see the last lines.
- Type a prompt, or tap the mic to dictate. Dictation uses Apple speech recognition on the device.
- While you dictate, the keyboard closes. Your words go into the field after Steer applies your word replacements.
- Steer sends nothing until you tap send.
- ＋ has Annotate Clipboard Image and Wrap as Code.
- In settings, you can choose the language, edit word replacements, and see the last 30 transcriptions.

## Remote tools

- Git review shows staged, unstaged, and untracked files with colored diffs. You can see diffs side by side.
- You can read source files and look at files in the last 100 commits. Steer shows UTF-8 files up to 512 KB. Staged files come from the index. Git review does not change files.
- The file browser can download, share, and upload files. Steer keeps a list of recent folders.
- You can annotate a clipboard image with a pen, a highlighter, and an eraser.
- Web preview opens a server on the host through an SSH tunnel.

## Security and alerts

- App lock asks for Face ID or the device passcode when the app returns from the background. A cover hides terminals and sheets while the app is locked or inactive.
- Steer shows a local alert when a connection drops or the terminal rings the bell.
- Steer also shows an alert when a Herdr agent needs you or is done.

## Companion

The companion is optional and you install it yourself. [companion/README.md](../companion/README.md) has the steps. With the companion, Steer can:

- Show Claude and Codex conversations with tool details, grouped by project. You can archive them.
- Show the last usage and context that each session reported. Codex quota windows show when the Codex log has them. Codex entries are history, not live status.
- Answer Claude permission requests and questions. Each answer goes to one request in one session. Steer refuses an answer to a request that expired. Steer never adds permanent permissions.
- Start a Claude conversation, send prompts to it, and stop it. If Steer sends the same prompt again, Claude gets it only one time. A session that runs in a terminal keeps using the terminal for prompts.
- Show Claude Conversations in the terminal's ⋯ menu.

## Limits

- Dictation runs only on the device.
- The companion cannot check Claude account quota, approve Codex tools, or send prompts to other agents. It sends prompts only to Claude conversations that it started.
- Steer has no remote push and no Live Activities. Alerts are local, and they stop when iOS suspends the app.
- Steer has no account, no analytics, and no in-app purchases.
- Steer cannot sign in with a hardware security key or with a key that has a passphrase.
- No end-to-end test covers Zellij attach.

## Run on an iPhone or iPad

[README.md](README.md#run-on-an-iphone-or-ipad) has the steps.

A Simulator can connect to `localhost` on the Mac, but usually it cannot connect to a Tailscale address. Use a real device to test Tailscale.
