// Settings write through `ferry config-set`, so the CLI's validation is the
// only validation — this window cannot disarm a rail with a value ferry
// would reject.

import SwiftUI

struct SettingsWindow: View {
    @ObservedObject var model: StatusModel

    @State private var intervalHours = 4
    @State private var maxDelete = 5
    @State private var atticKeepDays = 90
    @State private var logKeep = 30
    @State private var notify = true
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Pair") {
                    VStack(alignment: .trailing) {
                        Text(model.porcelain["path1"]).font(.caption.monospaced())
                        Text(model.porcelain["path2"]).font(.caption.monospaced())
                    }
                }
                LabeledContent("Attic") {
                    Text(model.porcelain["attic"]).font(.caption.monospaced())
                }
                Text("Paths are set with `ferry setup` — changing them mid-pair forces a resync, so they are deliberately not editable here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Schedule") {
                Toggle("Sync on a schedule (launchd)",
                       isOn: Binding(
                           get: { model.porcelain["schedule"] == "loaded" },
                           set: { model.scheduleSet(enabled: $0) }))
                Stepper("Every \(intervalHours) hours", value: $intervalHours, in: 1...24)
                    .onChange(of: intervalHours) { h in
                        guard loaded else { return }
                        model.configSet("INTERVAL", String(h * 3600)) {
                            // the launchd plist bakes the interval in
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
                Stepper("Abort if more than \(maxDelete)% would be deleted",
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

            Section {
                LabeledContent("Config file") {
                    Text(model.porcelain["config_file"]).font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("ferry CLI") {
                    Text(model.ferryBin ?? "not found").font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
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
        // guard against the initial programmatic sets firing config writes
        DispatchQueue.main.async { loaded = true }
    }
}
