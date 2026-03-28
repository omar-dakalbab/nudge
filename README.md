# nudge

A lightweight macOS terminal monitor that sends you native notifications when:

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

### Homebrew (coming soon)

```bash
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
| `-v, --verbose` | Print events to stdout | off |

## How it works

nudge polls your terminal sessions using `ps` and tracks process lifecycles:

1. **Finish detection** — Tracks PIDs across polls. When a process disappears after running longer than the threshold, you get notified.
2. **Input detection** — Checks process wait channels (`wchan`) and known input-requesting commands (sudo, ssh, gpg) to identify processes blocking on terminal input.
3. **Claude Code detection** — Identifies Claude Code processes in a sleeping state, indicating they're waiting for user approval.

Notifications are sent via native macOS `osascript` — no dependencies, no daemon, no background service to manage.

## Requirements

- macOS 13+
- Swift 5.9+

## Contributing

PRs welcome! Some ideas:

- [ ] Menu bar app mode
- [ ] Linux support (libnotify)
- [ ] Custom notification actions (run a command on click)
- [ ] iTerm2 / tmux session name in notifications
- [ ] Configurable ignore list
- [ ] Homebrew formula

## License

MIT
