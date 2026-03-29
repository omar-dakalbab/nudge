import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(AppKit)
import AppKit
#endif

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
    let command: String
    let tty: String
    let reason: AlertReason
    var aiSummary: String? = nil

    enum AlertReason: String, Hashable {
        case finished = "Command finished"
        case waitingForInput = "Waiting for input"
        case claudeCode = "Claude Code needs approval"
    }

    // Hashable conformance ignoring aiSummary
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(reason)
    }

    static func == (lhs: Alert, rhs: Alert) -> Bool {
        lhs.pid == rhs.pid && lhs.reason == rhs.reason
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
    var smartNotify: Bool = true
    var menuBar: Bool = false
    var onNotify: String? = nil
    var extraIgnored: [String] = []

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
            case "--no-ai":
                config.smartNotify = false
            case "--verbose", "-v":
                config.verbose = true
            case "--menu-bar":
                config.menuBar = true
            case "--on-notify":
                i += 1
                if i < args.count { config.onNotify = args[i] }
            case "--ignore":
                i += 1
                if i < args.count {
                    config.extraIgnored = args[i].components(separatedBy: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
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
    nudge - Terminal activity monitor for macOS & Linux

    Watches your terminal sessions and sends native notifications when:
      • A long-running command finishes
      • A process is waiting for input (sudo, password, y/n)
      • Claude Code or AI agents need approval

    USAGE:
      nudge [OPTIONS]

    OPTIONS:
      -i, --interval <secs>      Poll interval in seconds (default: 5)
      -t, --threshold <secs>     Min runtime to notify on finish (default: 30)
      --no-finished              Don't watch for finished commands
      --no-input                 Don't watch for input-waiting processes
      --no-claude                Don't watch for Claude Code prompts
      --no-sound                 Disable notification sound
      --no-ai                    Disable AI-powered smart notifications
      --ignore <cmd1,cmd2,...>   Additional commands to ignore
      --on-notify <cmd>          Run shell command on notification
                                 Placeholders: {command} {pid} {reason}
      --menu-bar                 Run as macOS menu bar app (macOS only)
      -v, --verbose              Print debug info
      -h, --help                 Show this help
      --version                  Show version

    EXAMPLES:
      nudge                              Start with defaults
      nudge -i 3 -t 10                  Poll every 3s, notify for commands > 10s
      nudge --no-finished                Only watch for input prompts
      nudge --ignore python,ruby         Also ignore python and ruby processes
      nudge --on-notify 'say {command}'  Speak the command name on notification
      nudge --menu-bar                   Run in the macOS menu bar

    INSTALL:
      brew install nudge      (coming soon)
      # or build from source:
      swift build -c release
      cp .build/release/nudge /usr/local/bin/
    """)
}

// MARK: - Session Name Detection (tmux / iTerm2)

func sessionName(forTty tty: String) -> String? {
    // Try tmux: list all panes with their ttys and session:window names
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_name}"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return nil
    }

    guard task.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }

    // tty from ps is like "ttys003", tmux reports "/dev/ttys003"
    let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

    for line in output.components(separatedBy: "\n") {
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { continue }
        if parts[0] == fullTty {
            return parts.dropFirst().joined(separator: " ")
        }
    }

    return nil
}

// MARK: - Process Monitor

class ProcessMonitor {
    private var trackedProcesses: [Int32: (command: String, tty: String, startTime: Date)] = [:]
    private var notifiedPids: Set<Int32> = []
    private var previousPids: Set<Int32> = []
    private var claudeLastState: [Int32: String] = [:]  // track last known state per Claude PID
    private let config: Config

    init(config: Config) {
        self.config = config
        previousPids = Set(getTerminalProcesses().map { $0.pid })
        for proc in getTerminalProcesses() {
            trackedProcesses[proc.pid] = (proc.command, proc.tty, Date())
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
                        var alert = Alert(pid: pid, command: tracked.command, tty: tracked.tty, reason: .finished)
                        if config.smartNotify {
                            alert.aiSummary = captureRecentOutput(tty: tracked.tty)
                        }
                        alerts.append(alert)
                        notifiedPids.insert(pid)
                    }
                }
                trackedProcesses.removeValue(forKey: pid)
            }
        }

        // Track new processes
        for proc in currentProcesses {
            if trackedProcesses[proc.pid] == nil {
                trackedProcesses[proc.pid] = (proc.command, proc.tty, Date())
            }
        }

        // Check for processes waiting for input
        if config.watchInput {
            for proc in currentProcesses {
                if isWaitingForInput(proc) && !notifiedPids.contains(proc.pid) {
                    alerts.append(Alert(pid: proc.pid, command: proc.command, tty: proc.tty, reason: .waitingForInput))
                    notifiedPids.insert(proc.pid)
                }
            }
        }

        // Check Claude Code sessions by reading conversation state
        if config.watchClaude {
            let claudeStates = getClaudeSessionStates()
            var activeClaudePids: Set<Int32> = []
            for (pid, state) in claudeStates {
                activeClaudePids.insert(pid)
                let prevState = claudeLastState[pid]
                claudeLastState[pid] = state

                // Only notify on transition TO a waiting state
                if prevState != nil && prevState != state {
                    if state == "tool_use" {
                        alerts.append(Alert(pid: pid, command: "claude", tty: "", reason: .claudeCode))
                    }
                }
            }
            for pid in Array(claudeLastState.keys) where !activeClaudePids.contains(pid) {
                claudeLastState.removeValue(forKey: pid)
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
        let lines = output.components(separatedBy: "\n").dropFirst()

        var ignoredCommands: Set<String> = [
            "zsh", "bash", "fish", "login", "sshd", "tmux", "screen",
            "nudge", "ps", "wc", "grep", "awk", "sed", "cat", "head", "tail"
        ]
        ignoredCommands.formUnion(config.extraIgnored)

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

    /// Captures recent terminal output from a tty.
    /// Tries tmux capture-pane first, falls back to reading system log.
    private func captureRecentOutput(tty: String) -> String? {
        // Try tmux capture-pane if the tty belongs to a tmux session
        let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        // First find which tmux pane owns this tty
        let findPane = Process()
        let findPipe = Pipe()
        findPane.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        findPane.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]
        findPane.standardOutput = findPipe
        findPane.standardError = FileHandle.nullDevice

        if let _ = try? findPane.run() {
            findPane.waitUntilExit()
            if findPane.terminationStatus == 0,
               let output = String(data: findPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                for line in output.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: " ")
                    guard parts.count >= 2, parts[0] == fullTty else { continue }
                    let paneId = parts[1]

                    // Capture last 20 lines from this pane
                    let capture = Process()
                    let capturePipe = Pipe()
                    capture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    capture.arguments = ["tmux", "capture-pane", "-t", paneId, "-p", "-S", "-20"]
                    capture.standardOutput = capturePipe
                    capture.standardError = FileHandle.nullDevice

                    if let _ = try? capture.run() {
                        capture.waitUntilExit()
                        if capture.terminationStatus == 0,
                           let captured = String(data: capturePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                           !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return captured
                        }
                    }
                }
            }
        }

        // Fallback: try reading the last few entries from the unified system log for this tty
        let logTask = Process()
        let logPipe = Pipe()
        logTask.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        logTask.arguments = ["show", "--last", "30s", "--predicate",
                             "process == \"kernel\" AND eventMessage CONTAINS \"\(tty)\"",
                             "--style", "compact"]
        logTask.standardOutput = logPipe
        logTask.standardError = FileHandle.nullDevice

        if let _ = try? logTask.run() {
            logTask.waitUntilExit()
            if let output = String(data: logPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return output
            }
        }

        return nil
    }

    /// Reads ~/.claude/sessions/ to find active Claude sessions, then checks
    /// each session's JSONL conversation log to determine if Claude is waiting
    /// for tool approval (stop_reason: "tool_use") or finished (stop_reason: "end_turn").
    /// Returns a dictionary of [PID: lastStopReason].
    private func getClaudeSessionStates() -> [Int32: String] {
        var states: [Int32: String] = [:]
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = homeDir.appendingPathComponent(".claude/sessions")
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let sessionFiles = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return states }

        for sessionFile in sessionFiles {
            guard sessionFile.pathExtension == "json" else { continue }

            guard let sessionData = try? Data(contentsOf: sessionFile),
                  let session = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
                  let pid = session["pid"] as? Int,
                  let sessionId = session["sessionId"] as? String else { continue }

            // Check if this PID is still running
            guard kill(Int32(pid), 0) == 0 else { continue }

            // Find the JSONL file for this session across all project dirs
            guard let projectDirs = try? FileManager.default.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil
            ) else { continue }

            for projectDir in projectDirs {
                let jsonlFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
                guard FileManager.default.fileExists(atPath: jsonlFile.path) else { continue }

                // Read the last line of the JSONL to get the most recent message
                if let lastLine = lastLineOf(file: jsonlFile),
                   let lineData = lastLine.data(using: .utf8),
                   let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let type = entry["type"] as? String, type == "assistant",
                   let message = entry["message"] as? [String: Any],
                   let stopReason = message["stop_reason"] as? String {
                    states[Int32(pid)] = stopReason
                }
                break
            }
        }
        return states
    }

    /// Efficiently reads the last line of a file without loading the entire file.
    private func lastLineOf(file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let chunkSize: UInt64 = 4096
        var offset = fileSize
        var trailingData = Data()

        while offset > 0 {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            handle.seek(toFileOffset: offset)
            let chunk = handle.readData(ofLength: Int(readSize))
            trailingData = chunk + trailingData

            if let str = String(data: trailingData, encoding: .utf8) {
                let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.count >= 1 {
                    return lines.last
                }
            }
        }

        if let str = String(data: trailingData, encoding: .utf8) {
            return str.components(separatedBy: "\n").filter { !$0.isEmpty }.last
        }
        return nil
    }
}

// MARK: - AI Output Analyzer

#if canImport(NaturalLanguage)
class OutputAnalyzer {

    enum ResultType: String {
        case success = "success"
        case failure = "failure"
        case warning = "warning"
        case neutral = "info"
    }

    struct Analysis {
        let type: ResultType
        let summary: String
    }

    // Error/failure patterns commonly seen in terminal output
    private let failurePatterns: [(pattern: String, extract: Bool)] = [
        ("error:", true),
        ("Error:", true),
        ("ERROR:", true),
        ("fatal:", true),
        ("FATAL:", true),
        ("failed", false),
        ("FAILED", false),
        ("Cannot find", true),
        ("No such file", true),
        ("No such module", true),
        ("not found", true),
        ("Permission denied", true),
        ("segmentation fault", false),
        ("panic:", true),
        ("exception:", true),
        ("Traceback", false),
        ("BUILD FAILED", false),
        ("FAILURE:", true),
        ("compilation error", false),
        ("syntax error", true),
        ("undefined reference", true),
        ("cannot open", true),
    ]

    private let successPatterns: [String] = [
        "Build complete",
        "BUILD SUCCEEDED",
        "BUILD SUCCESSFUL",
        "Tests passed",
        "All tests passed",
        "0 failures",
        "0 errors",
        "Successfully",
        "Done in",
        "Finished in",
        "completed successfully",
        "deployed",
        "installed",
        "up to date",
    ]

    private let warningPatterns: [String] = [
        "warning:",
        "Warning:",
        "WARNING:",
        "deprecated",
        "DEPRECATED",
    ]

    /// Analyzes terminal output text and produces a short, smart summary.
    func analyze(output: String, command: String) -> Analysis {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 1. Check for failure patterns — extract the key error line
        for line in lines.reversed() {
            for (pattern, extract) in failurePatterns {
                if line.localizedCaseInsensitiveContains(pattern) {
                    let summary = extract ? extractMessage(from: line, marker: pattern) : line
                    return Analysis(type: .failure, summary: truncate("\(command) failed: \(summary)"))
                }
            }
        }

        // 2. Check for success patterns
        for line in lines.reversed() {
            for pattern in successPatterns {
                if line.localizedCaseInsensitiveContains(pattern) {
                    return Analysis(type: .success, summary: truncate("\(command) succeeded: \(line)"))
                }
            }
        }

        // 3. Check for warnings
        for line in lines.reversed() {
            for pattern in warningPatterns {
                if line.localizedCaseInsensitiveContains(pattern) {
                    let msg = extractMessage(from: line, marker: pattern)
                    return Analysis(type: .warning, summary: truncate("\(command) warning: \(msg)"))
                }
            }
        }

        // 4. Use NaturalLanguage sentiment as a fallback
        let lastLines = lines.suffix(5).joined(separator: " ")
        let sentiment = analyzeSentiment(lastLines)

        if sentiment < -0.3 {
            let lastMeaningful = lines.last ?? "finished with issues"
            return Analysis(type: .failure, summary: truncate("\(command): \(lastMeaningful)"))
        } else if sentiment > 0.3 {
            return Analysis(type: .success, summary: truncate("\(command) completed successfully"))
        }

        return Analysis(type: .neutral, summary: truncate("\(command) has completed"))
    }

    /// Uses Apple's NLTagger to get sentiment score (-1.0 to 1.0).
    private func analyzeSentiment(_ text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        return Double(tag?.rawValue ?? "0") ?? 0.0
    }

    /// Extracts the meaningful part of an error line after a marker.
    private func extractMessage(from line: String, marker: String) -> String {
        if let range = line.range(of: marker, options: .caseInsensitive) {
            let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return String(after) }
        }
        return line
    }

    private func truncate(_ text: String, maxLength: Int = 120) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
}
#endif

// MARK: - Notifier

class Notifier {
    private let sound: Bool
    private let onNotify: String?
    private let smartNotify: Bool
    #if canImport(NaturalLanguage)
    private let analyzer = OutputAnalyzer()
    #endif

    init(sound: Bool, onNotify: String? = nil, smartNotify: Bool = true) {
        self.sound = sound
        self.onNotify = onNotify
        self.smartNotify = smartNotify
    }

    func send(alert: Alert) {
        var title: String
        var body: String

        switch alert.reason {
        case .finished:
            #if canImport(NaturalLanguage)
            if smartNotify, let aiSummary = alert.aiSummary {
                // Use AI-analyzed output
                let analysis = analyzer.analyze(output: aiSummary, command: alert.command)
                switch analysis.type {
                case .success:
                    title = "✅ \(alert.command)"
                case .failure:
                    title = "❌ \(alert.command)"
                case .warning:
                    title = "⚠️ \(alert.command)"
                case .neutral:
                    title = "⚡ \(alert.command)"
                }
                body = analysis.summary
            } else {
                title = "⚡ Command Finished"
                body = "\(alert.command) has completed"
            }
            #else
            title = "⚡ Command Finished"
            body = "\(alert.command) has completed"
            #endif
        case .waitingForInput:
            title = "✋ Input Needed"
            body = "\(alert.command) is waiting for your input"
        case .claudeCode:
            title = "🤖 Claude Code"
            body = "Claude Code needs your approval"
        }

        // Append tmux/iTerm2 session name if available
        if let session = sessionName(forTty: alert.tty) {
            body += " [\(session)]"
        }

        sendSystemNotification(title: title, body: body)
        runOnNotify(alert: alert)
    }

    private func sendSystemNotification(title: String, body: String) {
        #if os(macOS)
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
        #elseif os(Linux)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/notify-send")
        var args = [title, body]
        if !sound {
            args.append(contentsOf: ["-h", "string:suppress-sound:true"])
        }
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            fputs("Warning: Failed to send notification (is notify-send installed?)\n", stderr)
        }
        #endif
    }

    private func runOnNotify(alert: Alert) {
        guard let onNotify = onNotify else { return }

        let expanded = onNotify
            .replacingOccurrences(of: "{command}", with: alert.command)
            .replacingOccurrences(of: "{pid}", with: "\(alert.pid)")
            .replacingOccurrences(of: "{reason}", with: alert.reason.rawValue)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", expanded]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            fputs("Warning: Failed to run on-notify command\n", stderr)
        }
    }
}

// MARK: - Menu Bar App (macOS only)

#if canImport(AppKit)
class NudgeMenuBarApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer!
    let monitor: ProcessMonitor
    let notifier: Notifier
    let config: Config
    private let alertCountItem = NSMenuItem(title: "Alerts sent: 0", action: nil, keyEquivalent: "")
    private var alertCount = 0

    init(config: Config, monitor: ProcessMonitor, notifier: Notifier) {
        self.config = config
        self.monitor = monitor
        self.notifier = notifier
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔔"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "nudge running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Polling every \(Int(config.pollInterval))s", action: nil, keyEquivalent: ""))
        menu.addItem(alertCountItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            self?.pollAndNotify()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func pollAndNotify() {
        let alerts = monitor.poll()
        for alert in alerts {
            if config.verbose {
                let ts = ISO8601DateFormatter().string(from: Date())
                print("[\(ts)] \(alert.reason.rawValue) — PID \(alert.pid)")
            }
            notifier.send(alert: alert)
            alertCount += 1
        }
        alertCountItem.title = "Alerts sent: \(alertCount)"
    }
}
#endif

// MARK: - Main

let config = Config.fromArgs(CommandLine.arguments)
let monitor = ProcessMonitor(config: config)
let notifier = Notifier(sound: config.sound, onNotify: config.onNotify, smartNotify: config.smartNotify)

if config.menuBar {
    #if canImport(AppKit)
    let app = NSApplication.shared
    let delegate = NudgeMenuBarApp(config: config, monitor: monitor, notifier: notifier)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    #else
    fputs("Error: --menu-bar requires macOS\n", stderr)
    exit(1)
    #endif
} else {
    print("""
    🔔 nudge is running
       Polling every \(Int(config.pollInterval))s | Finish threshold: \(Int(config.finishThreshold))s
       Watching: \(config.watchFinished ? "✓" : "✗") finished  \(config.watchInput ? "✓" : "✗") input  \(config.watchClaude ? "✓" : "✗") claude  \(config.smartNotify ? "✓" : "✗") AI
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
}
