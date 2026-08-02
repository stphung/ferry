// The app's single source of truth, fed exclusively by ferry's machine
// interfaces: status --porcelain, activity --porcelain, attic list
// --porcelain, doctor --porcelain.

import SwiftUI
import ServiceManagement

struct ActivityItem: Identifiable {
    let id = UUID()
    let epoch: Int
    let action: String
    let path: String

    var symbol: String {
        if action.hasPrefix("Deleted") { return "trash" }
        if action.hasPrefix("Moved") || action.hasPrefix("Renamed") { return "arrow.turn.down.right" }
        return "doc"
    }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct AtticEntry: Identifiable {
    let id = UUID()
    let date: String
    let bytes: String
}

struct DoctorRow: Identifiable {
    let id = UUID()
    let status: String   // ok | bad | info
    let slug: String
    let detail: String

    var symbol: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "bad": return "xmark.octagon.fill"
        default: return "info.circle"
        }
    }
    var color: Color {
        switch status {
        case "ok": return .green
        case "bad": return .red
        default: return .secondary
        }
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var state = "loading"
    @Published var title = "…"
    @Published var symbol = "arrow.left.arrow.right"
    @Published var porcelain = Porcelain()
    @Published var activity: [ActivityItem] = []
    @Published var attic: [AtticEntry] = []
    @Published var doctor: [DoctorRow] = []
    @Published var ferryBin: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var syncRunning = false

    // one action at a time; its live output feeds the output window
    @Published var actionTitle = ""
    @Published var actionOutput = ""
    @Published var actionRunning = false
    @Published var actionExit: Int32?

    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?

    func start() {
        refresh()
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
                }
                return
            }
            let status = FerryCLI.run(bin, ["status", "--porcelain"])
            let p = Porcelain.parse(status.out)
            let act = FerryCLI.run(bin, ["activity", "--porcelain", "-n", "30"])
            let items: [ActivityItem] = act.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3, let e = Int(f[0]) else { return nil }
                return ActivityItem(epoch: e, action: f[1], path: f[2])
            }
            await MainActor.run {
                self.ferryBin = bin
                self.porcelain = p
                self.activity = items
                self.apply(p, exit: status.status)
                self.rewatch(stateDir: p["state_dir"])
            }
        }
    }

    private func apply(_ p: Porcelain, exit: Int32) {
        guard exit == 0, !p["state"].isEmpty else {
            state = "error"; symbol = "questionmark.circle"; title = ""
            return
        }
        state = p["state"]
        let age = Fmt.age(p["age_seconds"])
        let counts = (p["copied"].isEmpty || p["deleted"].isEmpty)
            ? "" : "  \(p["copied"])↑ \(p["deleted"])↓"

        switch state {
        case "syncing":       symbol = "arrow.triangle.2.circlepath"; title = "syncing"
        case "blocked":       symbol = "exclamationmark.octagon.fill"; title = "blocked"
        case "failed":        symbol = "exclamationmark.triangle.fill"; title = "failed"
        case "stale":         symbol = "clock.badge.exclamationmark"; title = "\(age)\(counts)"
        case "unestablished": symbol = "circle.dashed"; title = "setup"
        case "never":         symbol = "play.circle"; title = "ready"
        case "ok":            symbol = "arrow.left.arrow.right"; title = "\(age)\(counts)"
        default:              symbol = "questionmark.circle"; title = state
        }
        syncRunning = (state == "syncing")
    }

    private func rewatch(stateDir: String) {
        guard !stateDir.isEmpty, watcher == nil else { return }
        let fd = open(stateDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: - actions

    /// Stream a ferry command into the output window state. One at a time.
    func runAction(_ title: String, _ args: [String]) {
        guard let bin = ferryBin, !actionRunning else { return }
        actionTitle = title
        actionOutput = ""
        actionExit = nil
        actionRunning = true
        FerryCLI.stream(bin, args) { [weak self] line in
            self?.actionOutput += line + "\n"
        } onExit: { [weak self] code in
            self?.actionRunning = false
            self?.actionExit = code
            self?.refresh()
        }
    }

    func syncNow() {
        guard let bin = ferryBin, !syncRunning else { return }
        syncRunning = true
        Task.detached(priority: .utility) {
            _ = FerryCLI.run(bin, ["sync"])   // ferry notifies on failure itself
            await MainActor.run { self.refresh() }
        }
    }

    func loadAttic() {
        guard let bin = ferryBin else { return }
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["attic", "list", "--porcelain"])
            let entries: [AtticEntry] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 2 else { return nil }
                return AtticEntry(date: f[0], bytes: f[1])
            }
            await MainActor.run { self.attic = entries }
        }
    }

    func loadDoctor() {
        guard let bin = ferryBin else { return }
        doctor = []
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["doctor", "--porcelain"])
            var rows: [DoctorRow] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3 else { return nil }
                return DoctorRow(status: f[0], slug: f[1], detail: f[2])
            }
            // An older ferry has no --porcelain here; a spinner that never
            // resolves would look like a hang. Say what is actually wrong.
            if rows.isEmpty {
                rows = [DoctorRow(status: "bad", slug: "version",
                                  detail: "ferry \(bin) is too old for this app — brew upgrade ferry")]
            }
            await MainActor.run { self.doctor = rows }
        }
    }

    /// Settings writes go through config-set so the CLI's validation holds —
    /// the UI cannot disarm a rail with a value ferry would reject.
    func configSet(_ key: String, _ value: String, then: (() -> Void)? = nil) {
        guard let bin = ferryBin else { return }
        Task.detached(priority: .utility) {
            _ = FerryCLI.run(bin, ["config-set", key, value])
            await MainActor.run { self.refresh(); then?() }
        }
    }

    func scheduleSet(enabled: Bool) {
        guard let bin = ferryBin else { return }
        Task.detached(priority: .utility) {
            _ = FerryCLI.run(bin, ["schedule", enabled ? "install" : "remove"])
            await MainActor.run { self.refresh() }
        }
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {}
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        let log = porcelain["log"]
        guard !log.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }
}
