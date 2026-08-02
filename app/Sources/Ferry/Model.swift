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

    /// rclone's log phrasing, translated for humans.
    var friendlyAction: String {
        if action.hasPrefix("Deleted") { return "Deleted" }
        if action.hasPrefix("Moved") { return "Moved" }
        if action.hasPrefix("Renamed") { return "Renamed" }
        if action == "Copied (new)" { return "Added" }
        if action.hasPrefix("Copied (replaced") { return "Updated" }
        if action.hasPrefix("Copied") { return "Copied" }
        if action.hasPrefix("Updated modification") { return "Touched" }
        return action
    }
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
    @Published var atticLoaded = false
    @Published var doctor: [DoctorRow] = []
    @Published var doctorLoading = false
    @Published var blockedDetail = ""
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
        guard let bin = ferryBin ?? FerryCLI.find() else { atticLoaded = true; return }
        atticLoaded = false
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["attic", "list", "--porcelain"])
            let entries: [AtticEntry] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 2 else { return nil }
                return AtticEntry(date: f[0], bytes: f[1])
            }
            await MainActor.run { self.attic = entries; self.atticLoaded = true }
        }
    }

    func loadDoctor() {
        guard let bin = ferryBin ?? FerryCLI.find() else { return }
        doctor = []
        doctorLoading = true
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["doctor", "--porcelain"])
            var rows: [DoctorRow] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3 else { return nil }
                return DoctorRow(status: f[0], slug: f[1], detail: f[2])
            }
            // An older ferry has no --porcelain here; a spinner that never
            // resolves would look like a hang. Say what is actually wrong.
            let final = rows.isEmpty
                ? [DoctorRow(status: "bad", slug: "version",
                             detail: "ferry \(bin) is too old for this app — brew upgrade ferry")]
                : rows
            await MainActor.run { self.doctor = final; self.doctorLoading = false }
        }
    }

    func loadBlockedDetail() {
        guard let bin = ferryBin ?? FerryCLI.find() else { return }
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["blocked-detail"])
            await MainActor.run { self.blockedDetail = r.out }
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

    // MARK: - onboarding primitives (all through ferry; rclone only for the
    // browser sign-in that produces the token)

    struct Remote: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let type: String
    }

    @Published var remotes: [Remote] = []

    func loadRemotes() {
        guard let bin = ferryBin ?? FerryCLI.find() else { return }
        Task.detached(priority: .utility) {
            let r = FerryCLI.run(bin, ["remotes", "--porcelain"])
            let list: [Remote] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 2 else { return nil }
                return Remote(name: f[0], type: f[1])
            }
            await MainActor.run { self.remotes = list; self.ferryBin = bin }
        }
    }

    func createSMB(name: String, host: String, user: String, password: String) async -> String? {
        guard let bin = ferryBin else { return "ferry not found" }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.runWithInput(bin, ["remote-create-smb", name, host, user],
                                  stdin: password + "\n")
        }.value
        if r.status != 0 { return r.err.isEmpty ? "could not create the remote" : r.err }
        loadRemotes()
        return nil
    }

    /// Browser sign-in. Streams `rclone authorize onedrive`, which opens the
    /// default browser; the token JSON appears in its output when the user
    /// finishes. Returns the token, or an error message.
    func authorizeOneDrive() async -> (token: String?, error: String?) {
        guard let rclone = FerryCLI.findRclone() else { return (nil, "rclone not found") }
        return await withCheckedContinuation { cont in
            var all = ""
            FerryCLI.stream(rclone, ["authorize", "onedrive"]) { line in
                all += line + "\n"
            } onExit: { code in
                // token is the last {...} JSON object in the output
                if code == 0,
                   let start = all.range(of: "{", options: .backwards),
                   let end = all.range(of: "}", options: .backwards),
                   start.lowerBound < end.upperBound {
                    cont.resume(returning: (String(all[start.lowerBound..<end.upperBound]), nil))
                } else {
                    cont.resume(returning: (nil, "sign-in did not complete (exit \(code))"))
                }
            }
        }
    }

    struct Drive: Identifiable, Hashable {
        var id: String { driveID }
        let driveID: String
        let label: String
    }

    /// exit 2 from the primitive means "here are the drives, pick one".
    /// done=true means the remote exists; otherwise pick from drives or show error.
    func createOneDrive(name: String, token: String, drive: String?) async
        -> (done: Bool, drives: [Drive], error: String?) {
        guard let bin = ferryBin else { return (false, [], "ferry not found") }
        var args = ["remote-create-onedrive", name]
        if let d = drive { args += ["--drive", d] }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.runWithInput(bin, args, stdin: token)
        }.value
        if r.status == 0 { loadRemotes(); return (true, [], nil) }
        if r.status == 2 {
            let drives: [Drive] = r.out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard f.count == 2 else { return nil }
                return Drive(driveID: f[0], label: f[1])
            }
            return (false, drives, nil)
        }
        return (false, [], r.err.isEmpty ? "could not create the remote" : r.err)
    }

    func browse(_ path: String) async -> [String] {
        guard let bin = ferryBin else { return [] }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.run(bin, ["browse", path])
        }.value
        return r.out.split(separator: "\n").map(String.init)
    }

    func peek(_ path: String) async -> String {
        guard let bin = ferryBin else { return "?" }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.run(bin, ["peek", path])
        }.value
        return r.status == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : "?"
    }

    /// Non-secret settings of a remote (host, user, type…).
    func remoteInfo(_ name: String) async -> [String: String] {
        guard let bin = ferryBin ?? FerryCLI.find() else { return [:] }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.run(bin, ["remote-show", name, "--porcelain"])
        }.value
        var info: [String: String] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if f.count == 2 { info[f[0]] = f[1] }
        }
        return info
    }

    /// Is it reachable right now? (ok, detail) — detail is entry count or
    /// rclone's own error.
    func testRemote(_ name: String) async -> (ok: Bool, detail: String) {
        guard let bin = ferryBin ?? FerryCLI.find() else { return (false, "ferry not found") }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.run(bin, ["remote-test", name, "--porcelain"])
        }.value
        let f = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", maxSplits: 1).map(String.init)
        if f.count == 2 { return (f[0] == "ok", f[1]) }
        return (r.status == 0, r.status == 0 ? "reachable" : "unreachable")
    }

    func deleteRemote(_ name: String) async -> String? {
        guard let bin = ferryBin ?? FerryCLI.find() else { return "ferry not found" }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.runWithInput(bin, ["remote-delete", name], stdin: "")
        }.value
        if r.status != 0 { return r.err.isEmpty ? "could not delete" : r.err }
        loadRemotes()
        return nil
    }

    func updateSMB(name: String, host: String, user: String, password: String) async -> String? {
        guard let bin = ferryBin ?? FerryCLI.find() else { return "ferry not found" }
        var args = ["remote-update-smb", name, "--host", host, "--user", user]
        if !password.isEmpty { args.append("--password-stdin") }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.runWithInput(bin, args, stdin: password.isEmpty ? "" : password + "\n")
        }.value
        if r.status != 0 { return r.err.isEmpty ? "could not update" : r.err }
        loadRemotes()
        return nil
    }

    func mkdir(_ path: String) async -> Bool {
        guard let bin = ferryBin else { return false }
        let r = await Task.detached(priority: .utility) {
            FerryCLI.run(bin, ["mkdir", path])
        }.value
        return r.status == 0
    }
}

