import Foundation
import UserNotifications

// MARK: - Models

struct TerminalProcess {
    let pid: Int32
    let command: String
    let tty: String
    let state: String
    let cpuTime: String
}

struct Alert: Hashable {
    let pid: Int32
    let reason: AlertReason

    enum AlertReason: String, Hashable {
        case finished = "Command finished"
        case waitingForInput = "Waiting for input"
        case claudeCode = "Claude Code needs approval"
    }
}

// MARK: - Configuration

struct Config {
    var pollInterval: TimeInterval = 5
    var finishThreshold: TimeInterval = 30
    var watchFinished: Bool = true
    var watchInput: Bool = true
    var watchClaude: Bool = true
    var sound: Bool = true
    var verbose: Bool = false

    static func fromArgs(_ args: [String]) -> Config {
        var config = Config()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--interval", "-i":
                i += 1
                if i < args.count, let val = TimeInterval(args[i]) { config.pollInterval = val }
            case "--threshold", "-t":
                i += 1
                if i < args.count, let val = TimeInterval(args[i]) { config.finishThreshold = val }
            case "--no-finished":
                config.watchFinished = false
            case "--no-input":
                config.watchInput = false
            case "--no-claude":
                config.watchClaude = false
            case "--no-sound":
                config.sound = false
            case "--verbose", "-v":
                config.verbose = true
            case "--help", "-h":
                printUsage()
                exit(0)
            case "--version":
                print("nudge 0.1.0")
                exit(0)
            default:
                break
            }
            i += 1
        }
        return config
    }
}

func printUsage() {
    print("""
    nudge - Terminal activity monitor for macOS

    Watches your terminal sessions and sends native macOS notifications when:
      • A long-running command finishes
      • A process is waiting for input (sudo, password, y/n)
      • Claude Code or AI agents need approval

    USAGE:
      nudge [OPTIONS]

    OPTIONS:
      -i, --interval <secs>   Poll interval in seconds (default: 5)
      -t, --threshold <secs>  Min runtime to notify on finish (default: 30)
      --no-finished           Don't watch for finished commands
      --no-input              Don't watch for input-waiting processes
      --no-claude             Don't watch for Claude Code prompts
      --no-sound              Disable notification sound
      -v, --verbose           Print debug info
      -h, --help              Show this help
      --version               Show version

    EXAMPLES:
      nudge                   Start with defaults
      nudge -i 3 -t 10       Poll every 3s, notify for commands > 10s
      nudge --no-finished     Only watch for input prompts

    INSTALL:
      brew install nudge      (coming soon)
      # or build from source:
      swift build -c release
      cp .build/release/nudge /usr/local/bin/
    """)
}

// MARK: - Process Monitor

class ProcessMonitor {
    private var trackedProcesses: [Int32: (command: String, startTime: Date)] = [:]
    private var notifiedPids: Set<Int32> = []
    private var previousPids: Set<Int32> = []
    private let config: Config

    init(config: Config) {
        self.config = config
        // Snapshot current processes so we don't alert on pre-existing ones
        previousPids = Set(getTerminalProcesses().map { $0.pid })
        for proc in getTerminalProcesses() {
            trackedProcesses[proc.pid] = (proc.command, Date())
        }
    }

    func poll() -> [Alert] {
        var alerts: [Alert] = []
        let currentProcesses = getTerminalProcesses()
        let currentPids = Set(currentProcesses.map { $0.pid })

        // Check for finished processes
        if config.watchFinished {
            let finishedPids = previousPids.subtracting(currentPids)
            for pid in finishedPids {
                if let tracked = trackedProcesses[pid] {
                    let elapsed = Date().timeIntervalSince(tracked.startTime)
                    if elapsed >= config.finishThreshold && !notifiedPids.contains(pid) {
                        alerts.append(Alert(pid: pid, reason: .finished))
                        notifiedPids.insert(pid)
                    }
                }
                trackedProcesses.removeValue(forKey: pid)
            }
        }

        // Track new processes
        for proc in currentProcesses {
            if trackedProcesses[proc.pid] == nil {
                trackedProcesses[proc.pid] = (proc.command, Date())
            }
        }

        // Check for processes waiting for input
        if config.watchInput {
            for proc in currentProcesses {
                if isWaitingForInput(proc) && !notifiedPids.contains(proc.pid) {
                    alerts.append(Alert(pid: proc.pid, reason: .waitingForInput))
                    notifiedPids.insert(proc.pid)
                }
            }
        }

        // Check for Claude Code waiting
        if config.watchClaude {
            for proc in currentProcesses {
                if isClaudeWaiting(proc) && !notifiedPids.contains(proc.pid) {
                    alerts.append(Alert(pid: proc.pid, reason: .claudeCode))
                    notifiedPids.insert(proc.pid)
                }
            }
        }

        // Cleanup notified set for dead pids
        notifiedPids = notifiedPids.intersection(currentPids)
        previousPids = currentPids

        return alerts
    }

    private func getTerminalProcesses() -> [TerminalProcess] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,state,tty,time,comm"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var processes: [TerminalProcess] = []
        let lines = output.components(separatedBy: "\n").dropFirst() // skip header

        let ignoredCommands: Set<String> = [
            "zsh", "bash", "fish", "login", "sshd", "tmux", "screen",
            "nudge", "ps", "wc", "grep", "awk", "sed", "cat", "head", "tail"
        ]

        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }

            let pid = Int32(parts[0]) ?? 0
            let state = parts[1]
            let tty = parts[2]
            let time = parts[3]
            let comm = parts[4].components(separatedBy: "/").last ?? parts[4]

            guard tty != "??" else { continue }
            guard !ignoredCommands.contains(comm) else { continue }
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }

            processes.append(TerminalProcess(
                pid: pid,
                command: comm,
                tty: tty,
                state: state,
                cpuTime: time
            ))
        }
        return processes
    }

    private func isWaitingForInput(_ proc: TerminalProcess) -> Bool {
        // Check wchan (wait channel) for the process
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "wchan=", "-p", "\(proc.pid)"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let wchan = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let inputIndicators: Set<String> = ["read", "ttyin", "pause", "wait4", "sigsus"]
        let inputCommands: Set<String> = ["sudo", "ssh", "gpg", "pass", "openssl", "security"]

        if inputCommands.contains(proc.command) && proc.state.hasPrefix("S") {
            return true
        }

        for indicator in inputIndicators {
            if wchan.lowercased().contains(indicator) && inputCommands.contains(proc.command) {
                return true
            }
        }

        return false
    }

    private func isClaudeWaiting(_ proc: TerminalProcess) -> Bool {
        let claudeNames: Set<String> = ["claude", "claude-code", "node"]
        guard claudeNames.contains(proc.command) else { return false }

        // Check if Claude process has been idle (low CPU in S state)
        if proc.state.hasPrefix("S") {
            // Further verify by checking the process command line
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-o", "args=", "-p", "\(proc.pid)"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                return false
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let args = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return args.lowercased().contains("claude")
        }
        return false
    }
}

// MARK: - Notifier

class Notifier {
    private let sound: Bool

    init(sound: Bool) {
        self.sound = sound
    }

    func send(alert: Alert) {
        let title: String
        let body: String

        switch alert.reason {
        case .finished:
            title = "⚡ Command Finished"
            body = "Process \(alert.pid) has completed"
        case .waitingForInput:
            title = "✋ Input Needed"
            body = "Process \(alert.pid) is waiting for your input"
        case .claudeCode:
            title = "🤖 Claude Code"
            body = "An agent needs your approval (PID \(alert.pid))"
        }

        let soundFlag = sound ? " sound name \"Glass\"" : ""
        let script = "display notification \"\(body)\" with title \"\(title)\"\(soundFlag)"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            fputs("Warning: Failed to send notification\n", stderr)
        }
    }
}

// MARK: - Main

let config = Config.fromArgs(CommandLine.arguments)
let monitor = ProcessMonitor(config: config)
let notifier = Notifier(sound: config.sound)

print("""
🔔 nudge is running
   Polling every \(Int(config.pollInterval))s | Finish threshold: \(Int(config.finishThreshold))s
   Watching: \(config.watchFinished ? "✓" : "✗") finished  \(config.watchInput ? "✓" : "✗") input  \(config.watchClaude ? "✓" : "✗") claude
   Press Ctrl+C to stop
""")

signal(SIGINT) { _ in
    print("\n👋 nudge stopped")
    exit(0)
}

while true {
    let alerts = monitor.poll()
    for alert in alerts {
        if config.verbose {
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] \(alert.reason.rawValue) — PID \(alert.pid)")
        }
        notifier.send(alert: alert)
    }
    Thread.sleep(forTimeInterval: config.pollInterval)
}
