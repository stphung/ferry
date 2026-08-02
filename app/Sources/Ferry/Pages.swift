// The panel's pages. Every button carries a text label — icon-only controls
// were tried in the popover era and were not understandable.

import SwiftUI

/// Last two path segments — readable at a glance; full value on hover.
func shortPath(_ p: String) -> String {
    let parts = p.split(separator: "/")
    if parts.count <= 2 { return p }
    return "…/" + parts.suffix(2).joined(separator: "/")
}

// MARK: - Status

struct StatusPage: View {
    @ObservedObject var model: StatusModel
    @State private var showResync = false

    enum PairSheet: String, Identifiable {
        case nas, cloud, attic
        var id: String { rawValue }
    }
    @State private var pairSheet: PairSheet?

    private var stateLine: (text: String, color: Color) {
        switch model.state {
        case "ok":            return ("Up to date", .green)
        case "syncing":       return ("Syncing now…", .blue)
        case "blocked":       return ("Blocked — needs a decision", .red)
        case "failed":        return ("Last sync failed", .red)
        case "stale":         return ("No sync in \(Fmt.age(model.porcelain["age_seconds"])) — schedule may be stopped", .orange)
        case "unestablished": return ("Pair not established", .orange)
        case "never":         return ("Ready — never synced yet", .orange)
        default:              return (model.state, .secondary)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // headline — healthy is calm; anything needing attention sits
                // in a tinted card so severity registers at a glance
                HStack(spacing: 12) {
                    Image(systemName: model.symbol)
                        .font(.system(size: 34))
                        .foregroundStyle(stateLine.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stateLine.text).font(.title2.bold())
                        if model.state == "ok" || model.state == "stale" {
                            Text("Last sync \(Fmt.age(model.porcelain["age_seconds"])) ago — \(model.porcelain["copied"])↑ \(model.porcelain["deleted"])↓, \(model.porcelain["duration"])s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(model.state == "ok" || model.state == "syncing" ? 0 : 12)
                .background(
                    (model.state == "ok" || model.state == "syncing")
                        ? AnyView(EmptyView())
                        : AnyView(RoundedRectangle(cornerRadius: 8)
                            .fill(stateLine.color.opacity(0.09))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(stateLine.color.opacity(0.35))))
                )

                // the pair IS the configuration — shown and changed here
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("NAS").frame(width: 70, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(shortPath(model.porcelain["path1"])).font(.body.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .help(model.porcelain["path1"])
                            Spacer()
                            Button { pairSheet = .nas } label: {
                                Label("Change…", systemImage: "pencil")
                            }.controlSize(.small)
                        }
                        HStack {
                            Text("Cloud").frame(width: 70, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(shortPath(model.porcelain["path2"])).font(.body.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .help(model.porcelain["path2"])
                            Spacer()
                            Button { pairSheet = .cloud } label: {
                                Label("Change…", systemImage: "pencil")
                            }.controlSize(.small)
                        }
                        HStack {
                            Text("Attic").frame(width: 70, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(shortPath(model.porcelain["attic"])).font(.body.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .help(model.porcelain["attic"])
                            Spacer()
                            Button { pairSheet = .attic } label: {
                                Label("Change…", systemImage: "pencil")
                            }.controlSize(.small)
                        }
                        Divider()
                        HStack {
                            Text("Schedule").frame(width: 70, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(model.porcelain["schedule"] == "loaded"
                                 ? "every \(Fmt.age(model.porcelain["interval"]))"
                                 : "off — enable in Settings")
                            Spacer()
                            if !model.porcelain["free_bytes"].isEmpty {
                                Text("\(Fmt.bytes(model.porcelain["free_bytes"])) free in cloud")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }

                // guidance when a state needs it
                if model.state == "blocked" {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            if !model.porcelain["blocked_reason"].isEmpty {
                                Label(model.porcelain["blocked_reason"]
                                        .replacingOccurrences(of: "ferry: ", with: ""),
                                      systemImage: "exclamationmark.octagon.fill")
                                    .foregroundStyle(.red)
                            }
                            Text("Ferry will not retry until you decide which side is truth.")
                                .font(.callout)
                            // "what happened", inline — no leaving the page
                            DisclosureGroup("What happened") {
                                ScrollView {
                                    Text(model.blockedDetail.isEmpty ? "Loading…" : model.blockedDetail)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 160)
                                .onAppear { model.loadBlockedDetail() }
                            }
                            .font(.callout)
                        }
                        .padding(6)
                    }
                }
                if model.state == "unestablished" {
                    GroupBox {
                        Label("The pair is configured but not established. Resync once to create the baseline listings.",
                              systemImage: "info.circle")
                            .padding(6)
                    }
                }

                // actions — labelled, always. When blocked, exactly two
                // actions lead (understand, then decide); routine actions
                // otherwise cluster left with Resync weighted apart.
                if model.state == "blocked" {
                    HStack(spacing: 10) {
                        Button {
                            model.openLog()
                        } label: { Label("Open Log — see what happened", systemImage: "doc.text") }
                        .controlSize(.large)

                        Button {
                            showResync = true
                        } label: { Label("Resync — decide which side is truth", systemImage: "arrow.triangle.2.circlepath.circle") }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Spacer()
                    }
                } else {
                    HStack(spacing: 10) {
                        Button {
                            model.syncNow()
                        } label: {
                            Label(model.syncRunning ? "Syncing…" : "Sync Now",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.syncRunning || model.state == "unestablished")

                        Button {
                            model.runAction("Dry Run", ["sync", "--dry-run", "--verbose"])
                        } label: { Label("Dry Run", systemImage: "eye") }
                        .disabled(model.actionRunning)

                        Button {
                            model.runAction("Check Both Sides", ["check"])
                        } label: { Label("Check", systemImage: "checkmark.seal") }
                        .disabled(model.actionRunning)

                        Divider().frame(height: 20)

                        Button {
                            showResync = true
                        } label: { Label("Resync…", systemImage: "arrow.triangle.2.circlepath.circle") }
                        .tint(.orange)

                        Spacer(minLength: 10)
                        Divider().frame(height: 20)

                        Button {
                            model.openLog()
                        } label: { Label("Open Log", systemImage: "doc.text") }
                        .disabled(model.porcelain["log"].isEmpty)
                    }
                    .controlSize(.large)
                }

                // live output of the running/last action, in the same panel
                if model.actionRunning || !model.actionOutput.isEmpty {
                    ActionOutput(model: model)
                }

                // recent activity preview — fills the page and answers the
                // next question ("what did it move?") without a page switch
                if !model.activity.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recent activity")
                                .font(.headline)
                                .padding(.bottom, 2)
                            ForEach(model.activity.prefix(10)) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.symbol)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    Text(item.friendlyAction)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(Fmt.ago(item.epoch) + " ago")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showResync) { ResyncSheet(model: model) }
        .sheet(item: $pairSheet) { which in
            switch which {
            case .nas:   PairEditorSheet(model: model, kind: .nas)   { pairSheet = nil }
            case .cloud: PairEditorSheet(model: model, kind: .cloud) { pairSheet = nil }
            case .attic: AtticEditorSheet(model: model)              { pairSheet = nil }
            }
        }
    }
}

// MARK: - streamed output block (inline, not a separate window)

struct ActionOutput: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.actionTitle).font(.headline)
                    if model.actionRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    if let code = model.actionExit {
                        Label(code == 0 ? "Succeeded" : "Failed (exit \(code))",
                              systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(code == 0 ? .green : .red)
                    }
                    if model.actionRunning {
                        Button {
                            model.cancelAction()
                        } label: { Label("Stop", systemImage: "stop.fill") }
                        .tint(.red)
                    }
                    if !model.actionLogPath.isEmpty {
                        Button {
                            model.openActionLog()
                        } label: { Label("Open Full Output", systemImage: "doc.text.magnifyingglass") }
                    }
                    Button {
                        model.actionOutput = ""; model.actionExit = nil; model.actionTitle = ""
                    } label: { Label("Clear", systemImage: "xmark") }
                    .disabled(model.actionRunning)
                }
                if model.actionTruncated {
                    Text("Showing the last 500 lines — Open Full Output has the complete transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.actionOutput.isEmpty ? "…" : model.actionOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("tail")
                    }
                    .frame(height: 180)
                    .onChange(of: model.actionOutput) { _ in
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Activity

struct ActivityPage: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableCompat(
                    title: "No file activity yet",
                    detail: "Files copied, moved or deleted by a sync will appear here.")
            } else {
                List(model.activity) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                            if !item.folder.isEmpty {
                                Text(item.folder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Text(item.friendlyAction).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.ago(item.epoch) + " ago")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button { model.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Attic

struct AtticPage: View {
    @ObservedObject var model: StatusModel
    @State private var confirmRestore: AtticEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files a sync deleted or overwrote, kept \(model.porcelain["attic_keep_days"]) days. Restoring copies them back to the NAS without overwriting anything that exists now — it cannot destroy data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if !model.atticLoaded {
                ProgressView("Reading the attic…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.attic.isEmpty {
                ContentUnavailableCompat(
                    title: "Attic is empty",
                    detail: "Nothing has been deleted or overwritten by a sync.")
            } else {
                List(model.attic) { entry in
                    HStack {
                        Image(systemName: "archivebox")
                        Text(entry.date).font(.body.monospacedDigit())
                        Spacer()
                        Text(Fmt.bytes(entry.bytes)).foregroundStyle(.secondary)
                        Button {
                            confirmRestore = entry
                        } label: { Label("Restore…", systemImage: "arrow.uturn.backward") }
                        .disabled(model.actionRunning)
                    }
                    .padding(.vertical, 2)
                }
            }
            if model.actionRunning || !model.actionOutput.isEmpty {
                ActionOutput(model: model).padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("Attic")
        .toolbar {
            Button { model.loadAttic() } label: {
                Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            Button {
                model.runAction("Attic Prune", ["attic", "prune"])
            } label: {
                Label("Prune Old", systemImage: "trash").labelStyle(.titleAndIcon)
            }
            .disabled(model.attic.isEmpty || model.actionRunning)
        }
        .onAppear { model.loadAttic() }
        .confirmationDialog(
            "Restore \(confirmRestore?.date ?? "") to the NAS?",
            isPresented: Binding(get: { confirmRestore != nil },
                                 set: { if !$0 { confirmRestore = nil } })
        ) {
            Button("Restore") {
                if let e = confirmRestore {
                    model.runAction("Restore \(e.date)", ["attic", "restore", e.date])
                }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Copies that day's files back. Existing files are never overwritten.")
        }
    }
}

// MARK: - Doctor

struct DoctorPage: View {
    @ObservedObject var model: StatusModel

    /// The checks doctor always runs, shown as pending until results land.
    static let pendingChecks: [(String, String)] = [
        ("rclone", "Is rclone installed and new enough?"),
        ("config", "Does the configuration load?"),
        ("remotes", "Are both remotes configured?"),
        ("reachability", "Can both sides be reached?"),
        ("markers", "Are the safety markers in place?"),
        ("attic", "Is the attic outside the synced tree?"),
        ("headroom", "How much cloud space is free?"),
        ("pair", "Is the pair established?"),
    ]

    var body: some View {
        Group {
            if model.doctorLoading || model.doctor.isEmpty {
                // the checklist is legible from the first frame: known checks
                // render as pending and flip when the results land
                List(DoctorPage.pendingChecks, id: \.0) { check in
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView().controlSize(.small).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.0).font(.caption).foregroundStyle(.secondary)
                            Text(check.1).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                List(model.doctor) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.symbol).foregroundStyle(row.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.slug).font(.caption).foregroundStyle(.secondary)
                            Text(row.detail).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Doctor")
        .toolbar {
            Button { model.loadDoctor() } label: {
                Label("Run Again", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
        }
        .onAppear { model.loadDoctor() }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var model: StatusModel

    @State private var intervalHours = 4
    @State private var maxDelete = 5
    @State private var atticKeepDays = 90
    @State private var logKeep = 30
    @State private var notify = true
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Pair") {
                LabeledContent("NAS") {
                    Text(model.porcelain["path1"]).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).help(model.porcelain["path1"])
                }
                LabeledContent("Cloud") {
                    Text(model.porcelain["path2"]).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).help(model.porcelain["path2"])
                }
                LabeledContent("Attic") {
                    Text(model.porcelain["attic"]).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).help(model.porcelain["attic"])
                }
                Text("Change the pair from the Status page — each side has a Change… button there. A changed side un-establishes the pair and Status walks you into the resync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Schedule") {
                Toggle("Sync on a schedule", isOn: Binding(
                    get: { model.porcelain["schedule"] == "loaded" },
                    set: { model.scheduleSet(enabled: $0) }))
                Stepper("Every \(intervalHours) hours", value: $intervalHours, in: 1...24)
                    .disabled(model.porcelain["schedule"] != "loaded")
                    .opacity(model.porcelain["schedule"] == "loaded" ? 1 : 0.45)
                    .onChange(of: intervalHours) { h in
                        guard loaded else { return }
                        model.configSet("INTERVAL", String(h * 3600)) {
                            if self.model.porcelain["schedule"] == "loaded" {
                                self.model.scheduleSet(enabled: true)
                            }
                        }
                    }
                Toggle("Notify when a sync fails", isOn: $notify)
                    .onChange(of: notify) { v in
                        guard loaded else { return }
                        model.configSet("NOTIFY", v ? "1" : "0")
                    }
                Toggle("Start Ferry at login", isOn: Binding(
                    get: { model.loginEnabled },
                    set: { _ in model.toggleLogin() }))
            }
            Section("Safety") {
                Stepper("Abort if more than \(maxDelete)% of files would be deleted",
                        value: $maxDelete, in: 1...50)
                    .onChange(of: maxDelete) { v in
                        guard loaded else { return }
                        model.configSet("MAX_DELETE", String(v))
                    }
                Stepper("Keep deleted files \(atticKeepDays) days",
                        value: $atticKeepDays, in: 7...365, step: 7)
                    .onChange(of: atticKeepDays) { v in
                        guard loaded else { return }
                        model.configSet("ATTIC_KEEP_DAYS", String(v))
                    }
                Stepper("Keep \(logKeep) run logs", value: $logKeep, in: 5...200, step: 5)
                    .onChange(of: logKeep) { v in
                        guard loaded else { return }
                        model.configSet("LOG_KEEP", String(v))
                    }
            }
            Section("Paths") {
                LabeledContent("Config") {
                    Text(model.porcelain["config_file"]).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("ferry CLI") {
                    Text(model.ferryBin ?? "not found").font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear(perform: load)
        .onChange(of: model.porcelain.fields) { _ in load() }
    }

    private func load() {
        let p = model.porcelain
        if let v = Int(p["interval"]), v >= 3600 { intervalHours = v / 3600 }
        if let v = Int(p["max_delete"]) { maxDelete = v }
        if let v = Int(p["attic_keep_days"]) { atticKeepDays = v }
        if let v = Int(p["log_keep"]) { logKeep = v }
        notify = p["notify"] != "0"
        DispatchQueue.main.async { loaded = true }
    }
}

// MARK: - Resync sheet (same ritual as the CLI)

struct ResyncSheet: View {
    @ObservedObject var model: StatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "path1"
    @State private var typed = ""

    private let modes: [(String, String)] = [
        ("path1", "the NAS wins — its version overwrites the cloud where they differ"),
        ("path2", "the cloud wins — its version overwrites the NAS where they differ"),
        ("newer", "the newer file wins, decided per file"),
        ("older", "the older file wins, decided per file"),
        ("larger", "the larger file wins, decided per file"),
        ("smaller", "the smaller file wins, decided per file"),
    ]
    private var consequence: String { modes.first { $0.0 == mode }?.1 ?? "" }
    private var armed: Bool { typed == "resync" && !model.actionRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Re-establish the pair", systemImage: "arrow.triangle.2.circlepath.circle")
                .font(.headline)
            Text("A resync rebuilds ferry's saved listings. Where the two sides disagree, one wins — permanently. Deletions made since the listings were lost will be undone.")
                .font(.callout)
            Label("Anything a later sync replaces or deletes is kept in the Attic for \(model.porcelain["attic_keep_days"]) days — decisions here are recoverable, not destructive.",
                  systemImage: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Winner", selection: $mode) {
                ForEach(modes, id: \.0) { m in Text(m.0).tag(m.0) }
            }
            .pickerStyle(.segmented)
            Text(consequence)
                .font(.callout)
                .foregroundStyle(mode == "path1" || mode == "path2" ? .orange : .secondary)
            HStack {
                TextField("type resync to enable the button", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button {
                    model.runAction("Resync (--mode \(mode))",
                                    ["resync", "--yes", "--mode", mode])
                    typed = ""
                    dismiss()
                } label: { Label("Resync", systemImage: "arrow.triangle.2.circlepath") }
                .keyboardShortcut(.defaultAction)
                .disabled(!armed)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - small shared bits

/// ContentUnavailableView is macOS 14+; this is the 13-compatible equivalent.
struct ContentUnavailableCompat: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title3.bold()).foregroundStyle(.secondary)
            Text(detail).font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
