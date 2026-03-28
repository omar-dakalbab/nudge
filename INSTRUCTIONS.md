# nudge — Setup & Usage Instructions

Complete guide for installing, running, configuring, and developing nudge.

---

## Prerequisites

- **macOS 13 (Ventura)** or later
- **Xcode Command Line Tools** — install with:
  ```bash
  xcode-select --install
  ```
- **Swift 5.9+** — included with Xcode CLI tools. Verify with:
  ```bash
  swift --version
  ```

---

## Installation

### Option 1: Build from source (recommended)

```bash
# Clone the repo
git clone https://github.com/omar-dakalbab/nudge.git
cd nudge

# Build in release mode
swift build -c release

# Copy the binary to your PATH
sudo cp .build/release/nudge /usr/local/bin/nudge
```

### Option 2: Run without installing

```bash
cd nudge
swift build -c release
./.build/release/nudge
```

### Option 3: Run directly with Swift (slower startup)

```bash
cd nudge
swift run
```

### Verify installation

```bash
nudge --version
# Output: nudge 0.1.0
```

---

## Quick Start

```bash
# Start nudge with default settings
nudge
```

You'll see:

```
🔔 nudge is running
   Polling every 5s | Finish threshold: 30s
   Watching: ✓ finished  ✓ input  ✓ claude
   Press Ctrl+C to stop
```

That's it. Leave it running in a terminal tab and go about your work. You'll get native macOS notifications when something needs your attention.

---

## Configuration

All configuration is done via command-line flags. No config files needed.

### Flags

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--interval <seconds>` | `-i` | How often to check terminals | `5` |
| `--threshold <seconds>` | `-t` | Minimum command runtime before a "finished" alert fires | `30` |
| `--no-finished` | | Disable alerts for finished commands | enabled |
| `--no-input` | | Disable alerts for processes waiting for input | enabled |
| `--no-claude` | | Disable alerts for Claude Code / AI agents | enabled |
| `--no-sound` | | Send silent notifications (no sound) | sound on |
| `--verbose` | `-v` | Print each event to stdout with timestamps | off |
| `--help` | `-h` | Show help text | |
| `--version` | | Print version | |

### Examples

```bash
# Fast polling, short threshold (good for quick scripts)
nudge -i 2 -t 5

# Only care about input prompts (sudo, ssh, etc.)
nudge --no-finished --no-claude

# Only care about Claude Code agents
nudge --no-finished --no-input

# Silent mode with debug output
nudge --no-sound -v

# Watch everything, poll every 10 seconds
nudge -i 10
```

---

## What nudge detects

### 1. Finished commands

When a terminal process that ran longer than `--threshold` seconds disappears (exits), nudge sends a notification.

**Use case:** You kicked off a build, test suite, or deployment and switched to another app. nudge tells you when it's done.

**Ignored processes:** Shells (zsh, bash, fish), common utilities (grep, awk, cat), and nudge itself are excluded to avoid noise.

### 2. Processes waiting for input

nudge identifies processes that are blocked waiting for terminal input by checking:
- The process **wait channel** (`wchan`) for read/input indicators
- Known input-requesting commands: `sudo`, `ssh`, `gpg`, `pass`, `openssl`, `security`

**Use case:** You ran a script that unexpectedly hit a `sudo` prompt or SSH passphrase, and you're in another window.

### 3. Claude Code / AI agent prompts

nudge detects Claude Code processes in a sleeping state, which typically means they're waiting for your approval on a tool use.

**Use case:** You have Claude Code agents running in multiple terminals and want to know when any of them need you.

---

## Running in the background

### Option 1: Dedicated terminal tab

Just run `nudge` in its own tab. Simple and easy to stop with Ctrl+C.

### Option 2: Background process

```bash
# Start in background
nohup nudge > /tmp/nudge.log 2>&1 &

# Check if running
pgrep nudge

# Stop it
pkill nudge
```

### Option 3: launchd (auto-start on login)

Create `~/Library/LaunchAgents/com.nudge.monitor.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nudge.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/nudge</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/nudge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/nudge.err</string>
</dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.nudge.monitor.plist
```

To stop and remove:

```bash
launchctl unload ~/Library/LaunchAgents/com.nudge.monitor.plist
```

---

## Troubleshooting

### Notifications not showing up

1. **Check macOS notification settings:**
   System Settings → Notifications → Script Editor → make sure notifications are allowed.
   (nudge uses `osascript` which routes through Script Editor.)

2. **Check Do Not Disturb / Focus mode:**
   Notifications are suppressed when Focus is active.

3. **Test manually:**
   ```bash
   osascript -e 'display notification "test" with title "nudge test"'
   ```
   If this doesn't show a notification, the issue is with macOS settings, not nudge.

### Too many / too few notifications

- Getting spammed? Increase the threshold: `nudge -t 60`
- Missing alerts? Decrease the interval: `nudge -i 2`
- Don't care about finished commands? `nudge --no-finished`

### High CPU usage

nudge should use negligible CPU. If you see high usage:
- Increase the poll interval: `nudge -i 15`
- Check if something is rapidly spawning/killing processes in your terminals

---

## Development

### Build

```bash
swift build          # debug build
swift build -c release  # optimized build
```

### Run tests

```bash
swift test
```

### Project structure

```
nudge/
├── Package.swift          # Swift package manifest
├── Sources/
│   └── main.swift         # All source code
├── README.md              # Project overview
├── INSTRUCTIONS.md        # This file
├── LICENSE                # MIT license
└── .gitignore
```

### Adding new detectors

All detection logic is in `ProcessMonitor`. To add a new detector:

1. Add a case to `Alert.AlertReason`
2. Add a config flag in `Config` and parse it in `Config.fromArgs`
3. Add a detection method (e.g., `isMyThing(_:)`)
4. Call it in `poll()` and gate it behind the config flag
5. Add notification text in `Notifier.send(alert:)`

---

## Uninstall

```bash
# Remove the binary
sudo rm /usr/local/bin/nudge

# Remove launchd service (if installed)
launchctl unload ~/Library/LaunchAgents/com.nudge.monitor.plist
rm ~/Library/LaunchAgents/com.nudge.monitor.plist

# Remove the source
rm -rf ~/path/to/nudge
```
