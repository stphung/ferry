// Real windows for everything that must survive losing focus: streamed action
// output, the doctor report, the attic browser, and the resync ritual.

import SwiftUI

// MARK: - streamed output (dry run, check, restore, resync)

struct OutputWindow: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.actionTitle).font(.headline)
                if model.actionRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let code = model.actionExit {
                    Label(code == 0 ? "succeeded" : "exit \(code)",
                          systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(code == 0 ? .green : .red)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.actionOutput.isEmpty ? "…" : model.actionOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("tail")
                }
                .onChange(of: model.actionOutput) { _ in
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
    }
}

// MARK: - doctor

struct DoctorWindow: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Doctor").font(.headline)
            if model.doctor.isEmpty {
                ProgressView("Checking…").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(model.doctor) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: row.symbol).foregroundStyle(row.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.slug).font(.caption).foregroundStyle(.secondary)
                            Text(row.detail).font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Spacer()
                Button("Run Again") { model.loadDoctor() }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 380)
    }
}

// MARK: - attic

struct AtticWindow: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRestore: AtticEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attic").font(.headline)
            Text("Files that a sync deleted or overwrote, kept \(model.porcelain["attic_keep_days"]) days. Restoring copies them back without overwriting anything that exists now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.attic.isEmpty {
                Text("Empty — nothing has been deleted by a sync.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(model.attic) { entry in
                    HStack {
                        Image(systemName: "archivebox")
                        Text(entry.date).font(.body.monospacedDigit())
                        Spacer()
                        Text(Fmt.bytes(entry.bytes)).foregroundStyle(.secondary)
                        Button("Restore…") { confirmRestore = entry }
                            .disabled(model.actionRunning)
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("Refresh") { model.loadAttic() }
                Spacer()
                Button("Prune Old Snapshots") {
                    model.runAction("Attic Prune", ["attic", "prune"])
                    openWindow(id: "output")
                }
                .disabled(model.attic.isEmpty || model.actionRunning)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
        .confirmationDialog(
            "Restore \(confirmRestore?.date ?? "") to \(model.porcelain["path1"])?",
            isPresented: Binding(get: { confirmRestore != nil },
                                 set: { if !$0 { confirmRestore = nil } })
        ) {
            Button("Restore") {
                if let e = confirmRestore {
                    model.runAction("Restore \(e.date)", ["attic", "restore", e.date])
                    openWindow(id: "output")
                }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Copies that day's files back to the NAS side. Existing files are never overwritten, so this cannot destroy anything.")
        }
    }
}

// MARK: - resync

struct ResyncWindow: View {
    @ObservedObject var model: StatusModel
    @State private var mode = "path1"
    @State private var typed = ""

    private let modes: [(String, String)] = [
        ("path1", "the NAS wins — its version overwrites OneDrive where they differ"),
        ("path2", "OneDrive wins — its version overwrites the NAS where they differ"),
        ("newer", "the newer file wins, decided per file"),
        ("older", "the older file wins, decided per file"),
        ("larger", "the larger file wins, decided per file"),
        ("smaller", "the smaller file wins, decided per file"),
    ]

    private var consequence: String {
        modes.first { $0.0 == mode }?.1 ?? ""
    }
    private var armed: Bool { typed == "resync" && !model.actionRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Re-establish the pair", systemImage: "arrow.triangle.2.circlepath.circle")
                .font(.headline)

            // The same ritual as the CLI. This is a decision about which side
            // is truth; it is deliberately not a one-click button.
            Text("A resync rebuilds ferry's saved listings from scratch. Where the two sides disagree, one of them wins — permanently. Any deletion made since the listings were lost will be undone, because ferry can no longer tell a deletion from a new file on the other side.")
                .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.porcelain["path1"]).font(.body.monospaced())
                    Text("↕").foregroundStyle(.secondary)
                    Text(model.porcelain["path2"]).font(.body.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Picker("Winner:", selection: $mode) {
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
                Button("Resync") {
                    model.runAction("Resync (--mode \(mode))",
                                    ["resync", "--yes", "--mode", mode])
                    typed = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!armed)
            }

            if model.actionRunning || model.actionExit != nil {
                OutputWindow(model: model)
                    .frame(minHeight: 200)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
    }
}
