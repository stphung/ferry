// Ferry.app — a thin menu bar shell over the ferry CLI.
//
// All logic, config and safety rails live in the bash script; this app renders
// `ferry status --porcelain` and shells out to `ferry` for actions. The
// porcelain contract is the API boundary: if this app dies, ferry loses
// nothing but the icon.
//
// Deliberately NOT here: a sync timer (launchd owns the schedule), any network
// call (headroom comes from the porcelain, recorded at last sync), and any
// one-click resync (that decision keeps its Terminal confirmation).

import SwiftUI
import ServiceManagement

// MARK: - Locating the CLI

enum FerryCLI {
    /// FERRY_BIN wins (tests, development), then the usual install locations,
    /// then PATH. Resolved once per status refresh so an install mid-session
    /// is picked up.
    static func find() -> String? {
        if let env = ProcessInfo.processInfo.environment["FERRY_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let home = NSHomeDirectory()
        for c in ["/opt/homebrew/bin/ferry", "/usr/local/bin/ferry", "\(home)/.local/bin/ferry"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        // last resort: whatever a login shell's PATH says
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v ferry"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Run `ferry <args>` and capture stdout. Never called on the main thread.
    static func run(_ bin: String, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// Run a ferry command in a fresh Terminal window, for anything that is
    /// interactive (resync) or worth watching (dry run, doctor). A .command
    /// file opened with Terminal needs no automation permissions.
    static func runInTerminal(_ bin: String, _ args: [String]) {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("ferry-\(args.first ?? "cmd").command")
        let quoted = ([bin] + args).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        let script = "#!/bin/bash\n\(quoted)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(
            [file],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }
}

// MARK: - Porcelain

/// One parsed `ferry status --porcelain` snapshot. Keys are the stable
/// contract; anything unknown is ignored so old apps survive new keys.
struct Porcelain {
    var fields: [String: String] = [:]
    subscript(_ k: String) -> String { fields[k] ?? "" }

    static func parse(_ s: String) -> Porcelain {
        var p = Porcelain()
        for line in s.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            p.fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return p
    }
}

// MARK: - Model

@MainActor
final class StatusModel: ObservableObject {
    @Published var state = "loading"
    @Published var title = "…"
    @Published var symbol = "arrow.left.arrow.right"
    @Published var detail: [String] = []
    @Published var logPath = ""
    @Published var ferryBin: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var syncRunning = false

    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    func start() {
        refresh()
        // Fallback cadence. The file watcher below makes updates instant when
        // state changes; this timer catches everything else (age ticking over,
        // a ferry upgrade appearing on PATH).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let bin = FerryCLI.find() else {
                await MainActor.run {
                    self.ferryBin = nil
                    self.state = "noferry"
                    self.symbol = "questionmark.circle"
                    self.title = ""
                    self.detail = ["ferry is not installed",
                                   "brew install stphung/tap/ferry"]
                }
                return
            }
            let r = FerryCLI.run(bin, ["status", "--porcelain"])
            let p = Porcelain.parse(r.out)
            await MainActor.run {
                self.ferryBin = bin
                self.apply(p, exit: r.status)
                self.rewatch(stateDir: p["state_dir"])
            }
        }
    }

    private func apply(_ p: Porcelain, exit: Int32) {
        guard exit == 0, !p["state"].isEmpty else {
            state = "error"
            symbol = "questionmark.circle"
            title = ""
            detail = ["ferry status failed — run ferry doctor"]
            return
        }
        state = p["state"]
        logPath = p["log"]

        let age = Self.humanAge(p["age_seconds"])
        let counts = (p["copied"].isEmpty || p["deleted"].isEmpty)
            ? "" : "  \(p["copied"])↑ \(p["deleted"])↓"

        // Colour does not survive in a MenuBarExtra label, so the symbol shape
        // carries the state. Text carries age and counts.
        switch state {
        case "syncing":
            symbol = "arrow.triangle.2.circlepath"; title = "syncing"
        case "blocked":
            symbol = "exclamationmark.octagon.fill"; title = "blocked"
        case "failed":
            symbol = "exclamationmark.triangle.fill"; title = "failed"
        case "stale":
            symbol = "clock.badge.exclamationmark"; title = "\(age)\(counts)"
        case "unestablished":
            symbol = "circle.dashed"; title = "setup"
        case "never":
            symbol = "play.circle"; title = "ready"
        case "ok":
            symbol = "arrow.left.arrow.right"; title = "\(age)\(counts)"
        default:
            symbol = "questionmark.circle"; title = state
        }
        syncRunning = (state == "syncing")

        var d: [String] = []
        switch state {
        case "blocked":
            d.append("BLOCKED — a run stopped and needs a decision.")
            d.append("Read the log, then Resync…")
        case "stale":
            d.append("No successful sync in \(age) — over twice the interval.")
        case "unestablished":
            d.append("Pair not established: ferry markers, then ferry resync.")
        case "never":
            d.append("Ready — never run yet.")
        default: break
        }
        d.append("\(p["path1"])  ↕  \(p["path2"])")
        if !p["when"].isEmpty {
            d.append("Last run \(p["when"]) — \(p["outcome"]), \(p["duration"])s")
            d.append("Moved \(p["copied"])↑ \(p["deleted"])↓, \(p["errors"]) errors")
        }
        if !p["free_bytes"].isEmpty {
            d.append("Cloud free \(Self.humanBytes(p["free_bytes"])) (as of last sync)")
        }
        d.append("Schedule \(p["schedule"]), every \(Self.humanAge(p["interval"]))")
        detail = d
    }

    /// Watch the state directory so a finishing sync updates the icon within
    /// milliseconds instead of at the next minute tick.
    private func rewatch(stateDir: String) {
        guard !stateDir.isEmpty else { return }
        if watcher != nil { return }   // already watching; dir never moves mid-run
        let fd = open(stateDir, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: actions

    func syncNow() {
        guard let bin = ferryBin else { return }
        syncRunning = true
        Task.detached(priority: .utility) {
            _ = FerryCLI.run(bin, ["sync"])   // ferry notifies on failure itself
            await MainActor.run { self.refresh() }
        }
    }

    func inTerminal(_ args: [String]) {
        guard let bin = ferryBin else { return }
        FerryCLI.runInTerminal(bin, args)
    }

    func openLog() {
        guard !logPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func openLogFolder() {
        let dir = "\(NSHomeDirectory())/.local/state/ferry/logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { /* surfaced by the checkbox not moving */ }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: formatting

    static func humanAge(_ s: String) -> String {
        guard let v = Int(s), v >= 0 else { return "—" }
        if v < 60 { return "\(v)s" }
        if v < 3600 { return "\(v / 60)m" }
        if v < 86400 { return "\(v / 3600)h" }
        return "\(v / 86400)d"
    }

    static func humanBytes(_ s: String) -> String {
        guard var v = Double(s) else { return "—" }
        for unit in ["B", "KB", "MB", "GB"] {
            if v < 1024 { return String(format: "%.1f %@", v, unit) }
            v /= 1024
        }
        return String(format: "%.1f TB", v)
    }
}

// MARK: - App

@main
struct FerryApp: App {
    @StateObject private var model = StatusModel()

    init() {
        // `ferry app install|remove` drive login registration by running this
        // binary with a flag; SMAppService can only be called from the app.
        let args = CommandLine.arguments
        if args.contains("--register-login") {
            try? SMAppService.mainApp.register()
        }
        if args.contains("--unregister-login") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        if args.contains("--login-status") {
            print(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // state carried by symbol shape; text carries age/counts.
            // start() hangs off the LABEL, not the menu content: the label
            // renders immediately, the menu only on first click — hooking the
            // menu left the model dead until someone opened it.
            HStack {
                Image(systemName: model.symbol)
                if !model.title.isEmpty { Text(model.title) }
            }
            .onAppear { model.start() }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            ForEach(model.detail, id: \.self) { line in
                Text(line)
            }
            Divider()
            if model.ferryBin != nil {
                Button(model.syncRunning ? "Syncing…" : "Sync Now") { model.syncNow() }
                    .disabled(model.syncRunning)
                Button("Dry Run (Terminal)") { model.inTerminal(["sync", "--dry-run"]) }
                Button("Check Both Sides (Terminal)") { model.inTerminal(["check"]) }
                Button("Doctor (Terminal)") { model.inTerminal(["doctor"]) }
                Divider()
                Button("Open Latest Log") { model.openLog() }
                    .disabled(model.logPath.isEmpty)
                Button("Open Log Folder") { model.openLogFolder() }
                Divider()
                // resync decides which side is truth; it keeps its Terminal
                // confirmation and is never one click.
                Button("Resync… (Terminal)") { model.inTerminal(["resync"]) }
                Divider()
            }
            Toggle("Start at Login", isOn: Binding(
                get: { model.loginEnabled },
                set: { _ in model.toggleLogin() }
            ))
            Button("Refresh") { model.refresh() }
            Divider()
            Button("Quit Ferry") { NSApp.terminate(nil) }
        }
    }
}
