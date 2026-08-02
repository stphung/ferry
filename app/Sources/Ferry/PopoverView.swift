// The Dropbox-style popover: status header, quick actions, activity feed.
// Anything that must survive losing focus (resync, settings, action output,
// attic) opens a real window instead — popovers dismiss when focus shifts.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actions
            Divider()
            feed
            Divider()
            footer
        }
        .frame(width: 360)
    }

    // MARK: header

    private var stateLine: (text: String, color: Color) {
        switch model.state {
        case "ok":            return ("Up to date — last sync \(Fmt.age(model.porcelain["age_seconds"])) ago", .green)
        case "syncing":       return ("Syncing now…", .blue)
        case "blocked":       return ("Blocked — needs a decision", .red)
        case "failed":        return ("Last sync failed", .red)
        case "stale":         return ("No sync in \(Fmt.age(model.porcelain["age_seconds"])) — schedule may be stopped", .orange)
        case "unestablished": return ("Not set up — establish the pair", .orange)
        case "never":         return ("Ready — never synced yet", .orange)
        case "noferry":       return ("ferry CLI not found", .red)
        default:              return (model.state, .secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.symbol)
                    .font(.title2)
                    .foregroundStyle(stateLine.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLine.text)
                        .font(.headline)
                        .foregroundStyle(stateLine.color)
                    Text("\(model.porcelain["path1"])  ↕  \(model.porcelain["path2"])")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                if !model.porcelain["free_bytes"].isEmpty {
                    Label("\(Fmt.bytes(model.porcelain["free_bytes"])) free in cloud",
                          systemImage: "externaldrive")
                }
                Label(model.porcelain["schedule"] == "loaded"
                      ? "every \(Fmt.age(model.porcelain["interval"]))"
                      : "schedule off",
                      systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.syncNow()
            } label: {
                Label(model.syncRunning ? "Syncing…" : "Sync Now",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.syncRunning || model.ferryBin == nil
                      || model.state == "unestablished" || model.state == "blocked")

            Button {
                model.runAction("Dry Run", ["sync", "--dry-run", "--verbose"])
                show("output")
            } label: { Label("Dry Run", systemImage: "eye") }
            .disabled(model.actionRunning || model.ferryBin == nil)

            Button {
                model.loadDoctor()
                show("doctor")
            } label: { Label("Doctor", systemImage: "stethoscope") }
            .disabled(model.ferryBin == nil)
        }
        .controlSize(.large)
        .padding(10)
    }

    // MARK: feed

    private var feed: some View {
        Group {
            if model.activity.isEmpty {
                Text("No file activity yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.activity) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.callout).lineLimit(1)
                                    Text(item.folder)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(Fmt.ago(item.epoch))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.loadAttic(); show("attic") } label: {
                Image(systemName: "archivebox")
            }.help("Attic — recover deleted files")

            Button { show("resync") } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
            }.help("Resync — re-establish the pair")

            Button { model.runAction("Check", ["check"]); show("output") } label: {
                Image(systemName: "checkmark.seal")
            }.help("Check both sides agree (read-only)")
            .disabled(model.actionRunning)

            Button { model.openLog() } label: {
                Image(systemName: "doc.text")
            }.help("Open the latest log")
            .disabled(model.porcelain["log"].isEmpty)

            Spacer()

            Button { show("settings") } label: {
                Image(systemName: "gearshape")
            }.help("Settings")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }.help("Quit Ferry")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(10)
    }

    private func show(_ id: String) {
        openWindow(id: id)
        // an LSUIElement app's windows open behind the frontmost app unless
        // it activates itself
        NSApp.activate(ignoringOtherApps: true)
    }
}
