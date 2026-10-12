# Steer companion

The companion is an optional program for the computer that runs your agents. Steer works without it. With the companion, Steer can:

- Show Claude and Codex conversations, grouped by project. You can archive them.
- Answer Claude permission requests and questions.
- Start Claude conversations and send prompts to them.
- Show the usage and context that each session reported.

The companion needs Node 22 or newer. It has no npm dependencies.

## How it connects

The companion listens only on `127.0.0.1:43197`. Do not open this port to the network. Steer connects to it through the SSH connection that it already has.

The companion keeps a random access token in `~/.steer`. Only your user can read this folder. Steer reads the token over SSH and keeps it only in memory. The folder also has session data and the conversations that the companion started.

The companion reads other sessions from the folders of each agent. Steer has no push relay, so you answer approvals while the app is open.

## Set up

Keep this folder at a fixed path on the computer. From the Steer folder, run:

```sh
node companion/cli.mjs install
node companion/cli.mjs serve
```

`install` adds the Steer hooks to your Claude user settings. It keeps your other settings and hooks. After you install, restart Claude Code.

`serve` runs in the foreground. Keep it running in a terminal or a tmux session. You can also start it with launchd, systemd, or a different service manager. The companion does not install a service.

In Steer:

1. Edit the host and turn on **Use host companion**.
2. Connect to the host.
3. Open **Inbox → Agent conversations and approvals**, or **Claude Conversations** in the ⋯ menu of the terminal.
4. Select a session. Its session ID shows below its status.

## Conversations

To start a conversation, tap **New Claude conversation**. Enter a project folder and a prompt. The companion runs the `claude` CLI on the computer with the sign-in and permissions that it already has.

- You can send more prompts to the same session. You can stop it.
- Each conversation runs one turn at a time. The companion runs up to 8 turns at the same time.
- If the app sends the same prompt again, Claude gets it only one time.
- The companion never types a prompt into a different terminal.
- A session that runs in a terminal uses the terminal for new prompts.
- If you close the app, the turn continues. If you stop the companion, the turn stops.
- After the companion restarts, you can read the earlier conversations. To continue one, run `claude --resume SESSION_ID` in a terminal.

Claude hooks add a session when they run. For Codex, the companion reads up to 200 recent files in `$CODEX_HOME/sessions` every 30 seconds. The default folder is `~/.codex/sessions`. Codex sessions show as **History**. The companion does not approve Codex tools or show live Codex status.

A conversation view reads up to the last 8 MiB of a session and shows up to 400 messages. It cuts a message that is longer than 32,000 characters. The usage numbers come from the session logs. They are not live account data.

## Approvals and questions

**Allow once** and **Deny** answer one Claude `PermissionRequest`. They do not send keys to the terminal.

A request waits for the phone only if Steer asked the companion for updates in the last 15 seconds. If not, the hook returns immediately and Claude asks on the computer.

For `AskUserQuestion`, you can select an option or type an answer. A `PreToolUse` hook sends the answer, together with the original questions.

- The companion never adds permanent permission rules.
- A request expires after 5 minutes.
- If the request expires, the helper fails, the app disconnects, or the companion restarts, Claude asks on the computer.
- The companion refuses an answer that it already got or that is for a different session.
- Hooks cannot answer sandbox network prompts or MCP prompts that Claude keeps interactive.

## Remove

Run this from the same folder before you move or delete it:

```sh
node companion/cli.mjs uninstall
```

Then restart Claude, stop the companion, and turn off **Use host companion** in Steer.

## Settings

- `CLAUDE_CONFIG_DIR`: set it during `install` to use a different Claude settings folder. You can also give a settings file path as the second argument.
- `STEER_HOME`: changes the companion folder for tests. The app reads only `~/.steer/companion.json`.

## Tests

```sh
node --test companion/test/*.test.mjs
```

The tests use temporary folders and test keys. They do not change your Claude settings or agent logs. They test:

- HTTP authentication, the hook CLI, approvals, and questions
- expiry, disconnect, restart, and archives
- transcript parsing
- the return to Claude when the app is not open

The tests use a fake Claude process. They test prompts, resume, retries, failures, and stop without a call to a model. [ios/README.md](../ios/README.md) has the app tests.

References: [Claude hooks](https://code.claude.com/docs/en/hooks) and [Codex protocol types](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs).
