# nudge

A lightweight macOS & Linux terminal monitor that sends you native notifications when:

- **A long-running command finishes** — no more staring at terminals waiting for builds
- **A process needs input** — catch sudo prompts, SSH passphrases, y/n confirmations
- **Claude Code or AI agents need approval** — stay productive while agents work

## Install

### From source

```bash
git clone https://github.com/omar-dakalbab/nudge.git
cd nudge
swift build -c release
cp .build/release/nudge /usr/local/bin/
```

### Homebrew

```bash
brew tap omar-dakalbab/nudge
brew install nudge
```

## Usage

```bash
# Start with defaults (poll every 5s, notify for commands > 30s)
nudge

# Custom poll interval and threshold
nudge -i 3 -t 10

# Only watch for input prompts and Claude Code
nudge --no-finished

# Silent notifications (no sound)
nudge --no-sound

# Ignore specific commands
nudge --ignore python,ruby,cargo

# Run a custom command on each notification
nudge --on-notify 'say {command} finished'

# Run as a menu bar app (macOS only)
nudge --menu-bar

# Debug mode
nudge -v
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-i, --interval <secs>` | Poll interval | `5` |
| `-t, --threshold <secs>` | Min command runtime to trigger finish alert | `30` |
| `--no-finished` | Skip finished command alerts | off |
| `--no-input` | Skip input-waiting alerts | off |
| `--no-claude` | Skip Claude Code alerts | off |
| `--no-sound` | Disable notification sound | off |
| `--ignore <cmd1,cmd2,...>` | Additional commands to ignore | none |
| `--on-notify <cmd>` | Run shell command on notification | none |
| `--menu-bar` | Run as macOS menu bar app | off |
| `-v, --verbose` | Print events to stdout | off |

### `--on-notify` placeholders

| Placeholder | Value |
|-------------|-------|
| `{command}` | The command name (e.g. `swift`, `make`) |
| `{pid}` | Process ID |
| `{reason}` | Alert reason (`Command finished`, `Waiting for input`, `Claude Code needs approval`) |

## How it works

nudge polls your terminal sessions using `ps` and tracks process lifecycles:

1. **Finish detection** — Tracks PIDs across polls. When a process disappears after running longer than the threshold, you get notified.
2. **Input detection** — Checks process wait channels (`wchan`) and known input-requesting commands (sudo, ssh, gpg) to identify processes blocking on terminal input.
3. **Claude Code detection** — Tracks CPU time of Claude Code processes. When CPU time stops changing after being active, it means Claude finished working and is waiting for input.
4. **Session names** — Automatically detects tmux session and window names, appending them to notifications so you know which terminal needs attention.

### Platform support

- **macOS** — Notifications via native `osascript`. Menu bar mode via AppKit.
- **Linux** — Notifications via `notify-send` (requires libnotify/`notify-send` installed).

## Requirements

- macOS 13+ or Linux
- Swift 5.9+
- Linux: `notify-send` (usually part of `libnotify-bin`)

## Contributing

PRs welcome! Some ideas:

- [x] Menu bar app mode
- [x] Linux support (libnotify)
- [x] Custom notification actions (run a command on click)
- [x] iTerm2 / tmux session name in notifications
- [x] Configurable ignore list
- [x] Homebrew formula

## License

MIT
