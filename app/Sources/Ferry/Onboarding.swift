// First-run onboarding. Nothing is hardcoded: remotes are discovered or
// created, folders are browsed, and every write goes through ferry's
// validated primitives. The wizard IS `ferry setup`, with a face.

import SwiftUI

enum WizardStep: Int, CaseIterable {
    case welcome, nas, nasFolder, cloud, cloudFolder, options, markers, resync, done

    var title: String {
        switch self {
        case .welcome:     return "Welcome"
        case .nas:         return "NAS"
        case .nasFolder:   return "NAS Folder"
        case .cloud:       return "Cloud"
        case .cloudFolder: return "Cloud Folder"
        case .options:     return "Options"
        case .markers:     return "Safety Markers"
        case .resync:      return "First Sync"
        case .done:        return "Done"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: StatusModel

    @State private var step: WizardStep = {
        if let s = ProcessInfo.processInfo.environment["FERRY_UI_STEP"],
           let n = Int(s), let ws = WizardStep(rawValue: n) { return ws }
        return .welcome
    }()

    // choices made along the way
    @State private var nasRemote = ""
    @State private var nasFolder = ""
    @State private var cloudRemote = ""
    @State private var cloudFolder = ""
    @State private var attic = ""
    @State private var intervalHours = 4
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // progress
            HStack {
                ForEach(WizardStep.allCases.dropLast(), id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    if s != .resync {
                        Rectangle()
                            .fill(s.rawValue < step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(height: 2)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)

            Text("Step \(step.rawValue + 1) of \(WizardStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text(step.title).font(.title.bold()).padding(.top, 2)

            Group {
                switch step {
                case .welcome:     welcome
                case .nas:         RemotePicker(model: model, kind: .nas, chosen: $nasRemote, onNext: { advance() })
                case .nasFolder:   FolderPicker(model: model, remote: nasRemote, folder: $nasFolder,
                                                hint: "The folder on your NAS that will mirror the cloud.",
                                                onNext: { advance() })
                case .cloud:       RemotePicker(model: model, kind: .cloud, chosen: $cloudRemote, onNext: { advance() })
                case .cloudFolder: FolderPicker(model: model, remote: cloudRemote, folder: $cloudFolder,
                                                hint: "The cloud folder to mirror — leave empty for the whole drive.",
                                                allowEmpty: true, onNext: { advance() })
                case .options:     options
                case .markers:     MarkersStep(model: model,
                                               path1: "\(nasRemote):\(nasFolder)",
                                               path2: cloudPath,
                                               onNext: { advance() })
                case .resync:      ResyncStep(model: model, onNext: { advance() })
                case .done:        doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            if let e = error {
                Text(e).foregroundStyle(.red).font(.callout).padding(.bottom, 8)
            }
        }
    }

    private var cloudPath: String {
        cloudFolder.isEmpty ? "\(cloudRemote):" : "\(cloudRemote):\(cloudFolder)"
    }

    private func advance() {
        error = nil
        if step == .options {
            // write the whole configuration through validated primitives
            Task {
                let pairs = [
                    ("PATH1", "\(nasRemote):\(nasFolder)"),
                    ("PATH2", cloudPath),
                    ("ATTIC", attic.isEmpty ? "\(nasRemote):ferry-attic" : attic),
                    ("INTERVAL", String(intervalHours * 3600)),
                ]
                for (k, v) in pairs {
                    guard let bin = model.ferryBin else { error = "ferry not found"; return }
                    let r = await Task.detached { FerryCLI.run(bin, ["config-set", k, v]) }.value
                    if r.status != 0 {
                        error = "could not set \(k) — check the value"
                        return
                    }
                }
                model.refresh()
                step = .markers
            }
            return
        }
        if let next = WizardStep(rawValue: step.rawValue + 1) { step = next }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Ferry keeps a folder on your NAS and a cloud drive as a two-way mirror, with the safety rails that stop either side from destroying the other.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Setup takes about two minutes: pick or connect the two sides, choose the folders, and run the first sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button { advance() } label: {
                Label("Get Started", systemImage: "arrow.right").frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .onAppear { model.loadRemotes() }
    }

    private var options: some View {
        Form {
            Section("Deleted files") {
                TextField("Attic location", text: $attic,
                          prompt: Text("\(nasRemote):ferry-attic"))
                Text("Where files deleted by a sync are kept (90 days by default). Must be outside the mirrored folder — ferry enforces that.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Schedule") {
                Stepper("Sync every \(intervalHours) hours", value: $intervalHours, in: 1...24)
            }
            Section {
                Button { advance() } label: {
                    Label("Apply Configuration", systemImage: "checkmark").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Ferry is running").font(.title2.bold())
            Text("The pair is established and will sync every \(intervalHours) hours. The menu bar icon shows the state at a glance; click it any time to open this panel.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                Task {
                    if let bin = model.ferryBin {
                        _ = await Task.detached { FerryCLI.run(bin, ["schedule", "install"]) }.value
                    }
                    model.refresh()
                }
            } label: {
                Label("Enable the Schedule & Finish", systemImage: "clock").frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - remote picker (see, test, edit, delete — not just choose)

struct RemotePicker: View {
    enum Kind { case nas, cloud }

    @ObservedObject var model: StatusModel
    let kind: Kind
    @Binding var chosen: String
    let onNext: () -> Void

    @State private var creating = false
    @State private var editing = false
    // form fields (create and edit share them)
    @State private var formName = ""
    @State private var formHost = ""
    @State private var formUser = NSUserName()
    @State private var formPass = ""
    // details + connection test of the selected remote
    @State private var info: [String: String] = [:]
    @State private var testing = false
    @State private var testResult: (ok: Bool, detail: String)?
    @State private var confirmDelete = false
    // OneDrive flow
    @State private var odName = "onedrive"
    @State private var odBusy = false
    @State private var odDrives: [StatusModel.Drive] = []
    @State private var odToken = ""
    @State private var error: String?

    private var blurb: String {
        kind == .nas
            ? "Where your files live. Pick a NAS connection, or add one over SMB. Selecting one tests it immediately."
            : "The cloud side of the mirror. Pick an existing cloud connection, or sign in to OneDrive."
    }

    private var eligible: [StatusModel.Remote] {
        let nasTypes = ["smb", "sftp", "nfs", "local", "webdav", "ftp"]
        return model.remotes.filter {
            kind == .nas ? nasTypes.contains($0.type) : !nasTypes.contains($0.type)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(blurb).foregroundStyle(.secondary)

            if !eligible.isEmpty {
                List(eligible, selection: Binding(
                    get: { chosen.isEmpty ? nil : chosen },
                    set: { select($0) })
                ) { r in
                    HStack {
                        Image(systemName: r.type == "smb"
                              ? "externaldrive.connected.to.line.below" : "cloud")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name)
                            if chosen == r.name, let host = info["host"] {
                                Text("\(host)\(info["user"].map { " · \($0)" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(r.type).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if chosen == r.name {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else if let t = testResult {
                                Label(t.ok ? "Connected" : "Unreachable",
                                      systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(t.ok ? .green : .red)
                                    .font(.callout)
                            }
                        }
                    }
                    .tag(r.name)
                }
                .frame(minHeight: 120, maxHeight: 200)

                // what the selection means, and what you can do with it
                if !chosen.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            runTest()
                        } label: { Label("Test Connection", systemImage: "bolt") }
                        .disabled(testing)

                        if kind == .nas && info["type"] == "smb" {
                            Button {
                                formName = chosen
                                formHost = info["host"] ?? ""
                                formUser = info["user"] ?? ""
                                formPass = ""
                                editing = true
                                creating = true
                            } label: { Label("Edit…", systemImage: "pencil") }
                        }

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: { Label("Delete…", systemImage: "trash") }

                        Spacer()
                    }
                    if let t = testResult, !t.ok {
                        Text(t.detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            } else {
                Text(kind == .nas
                     ? "No NAS connections yet — add one below."
                     : "No cloud connections yet — sign in below.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            DisclosureGroup(
                kind == .nas
                    ? (editing ? "Edit \(formName)" : "New SMB connection…")
                    : "Sign in to OneDrive…",
                isExpanded: $creating
            ) {
                if kind == .nas { smbForm } else { onedriveFlow }
            }
            .onChange(of: creating) { open in
                if !open { editing = false }
            }

            if let e = error { Text(e).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                Button {
                    onNext()
                } label: { Label("Continue", systemImage: "arrow.right") }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty || testing || !(testResult?.ok ?? false))
            }
        }
        .frame(maxWidth: 560)
        .onAppear {
            model.loadRemotes()
            // FERRY_UI_REMOTE: screenshot scaffolding — preselects a row so the
            // management UI is capturable without a click. Never set normally.
            if chosen.isEmpty,
               let pre = ProcessInfo.processInfo.environment["FERRY_UI_REMOTE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { select(pre) }
            } else if !chosen.isEmpty {
                select(chosen)
            }
        }
        .confirmationDialog("Delete the connection “\(chosen)”?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let name = chosen
                Task {
                    if let e = await model.deleteRemote(name) {
                        error = e
                    } else {
                        chosen = ""
                        info = [:]; testResult = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from this Mac's connection list. Files on the NAS itself are untouched. Ferry refuses to delete a connection the sync pair is using.")
        }
    }

    private func select(_ name: String?) {
        chosen = name ?? ""
        info = [:]; testResult = nil; error = nil
        guard let name, !name.isEmpty else { return }
        Task {
            info = await model.remoteInfo(name)
        }
        runTest()
    }

    private func runTest() {
        guard !chosen.isEmpty else { return }
        testing = true; testResult = nil
        let name = chosen
        Task {
            let r = await model.testRemote(name)
            if chosen == name {           // ignore a stale result after reselect
                testResult = r
                testing = false
            }
        }
    }

    private var smbForm: some View {
        Form {
            TextField("Name", text: $formName)
                .disabled(editing)        // renaming is a delete + create
            TextField("Host or IP", text: $formHost, prompt: Text("192.168.1.10"))
            TextField("Username", text: $formUser)
            SecureField("Password", text: $formPass,
                        prompt: editing ? Text("leave blank to keep current") : nil)
            Button {
                error = nil
                Task {
                    let e: String?
                    if editing {
                        e = await model.updateSMB(name: formName, host: formHost,
                                                  user: formUser, password: formPass)
                    } else {
                        e = await model.createSMB(name: formName, host: formHost,
                                                  user: formUser, password: formPass)
                    }
                    if let e { error = e } else {
                        creating = false
                        select(formName)   // show it selected, tested
                    }
                }
            } label: {
                Label(editing ? "Save Changes" : "Create Connection",
                      systemImage: editing ? "checkmark" : "plus")
            }
            .disabled(formName.isEmpty || formHost.isEmpty)
        }
        .padding(.top, 6)
        .onAppear { if !editing { formName = "nas"; formHost = ""; formPass = "" } }
    }

    private var onedriveFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $odName)
                .frame(maxWidth: 240)
            if odDrives.isEmpty {
                Button {
                    error = nil; odBusy = true
                    Task {
                        let auth = await model.authorizeOneDrive()
                        guard let token = auth.token else {
                            error = auth.error; odBusy = false; return
                        }
                        odToken = token
                        let r = await model.createOneDrive(name: odName, token: token, drive: nil)
                        odBusy = false
                        if r.done { chosen = odName; creating = false }
                        else if let e = r.error { error = e }
                        else { odDrives = r.drives }
                    }
                } label: {
                    Label(odBusy ? "Waiting for the browser…" : "Sign in with your browser",
                          systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(odBusy || odName.isEmpty)
                if odBusy {
                    Text("A browser window opens; sign in and approve. Ferry only ever receives the sync token — never your password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Choose which drive:").font(.callout)
                ForEach(odDrives) { d in
                    Button {
                        odBusy = true
                        Task {
                            let r = await model.createOneDrive(name: odName, token: odToken,
                                                               drive: d.driveID)
                            odBusy = false
                            if r.done { chosen = odName; creating = false; odDrives = [] }
                            else { error = r.error ?? "could not set the drive" }
                        }
                    } label: {
                        Label(d.label, systemImage: "internaldrive")
                    }
                    .disabled(odBusy)
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - folder picker (browse, descend, create)

struct FolderPicker: View {
    @ObservedObject var model: StatusModel
    let remote: String
    @Binding var folder: String
    let hint: String
    var allowEmpty = false
    let onNext: () -> Void

    @State private var here = ""          // current browse path within the remote
    @State private var dirs: [String] = []
    @State private var newName = ""
    @State private var busy = false
    @State private var error: String?

    private var current: String { here.isEmpty ? "\(remote):" : "\(remote):\(here)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hint).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button { navigate(up: true) } label: { Label("Up", systemImage: "chevron.up") }
                    .disabled(here.isEmpty || busy)
                Text(current).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            List(dirs, id: \.self) { d in
                Button {
                    here = here.isEmpty ? d : "\(here)/\(d)"
                    load()
                } label: {
                    Label(d, systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 140, maxHeight: 200)

            HStack {
                TextField("New folder name", text: $newName)
                    .frame(maxWidth: 220)
                Button {
                    let path = here.isEmpty ? "\(remote):\(newName)" : "\(remote):\(here)/\(newName)"
                    busy = true
                    Task {
                        if await model.mkdir(path) {
                            here = here.isEmpty ? newName : "\(here)/\(newName)"
                            newName = ""
                            load()
                        } else {
                            error = "could not create the folder"
                            busy = false
                        }
                    }
                } label: { Label("Create & Enter", systemImage: "folder.badge.plus") }
                .disabled(newName.isEmpty || busy)
            }

            if let e = error { Text(e).foregroundStyle(.red).font(.callout) }

            HStack {
                Text(allowEmpty && here.isEmpty
                     ? "Using the whole drive."
                     : "Using: \(current)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    folder = here
                    onNext()
                } label: { Label("Use This Folder", systemImage: "checkmark") }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!allowEmpty && here.isEmpty)
            }
        }
        .frame(maxWidth: 560)
        .onAppear(perform: load)
    }

    private func navigate(up: Bool) {
        guard up, !here.isEmpty else { return }
        here = here.contains("/") ? String(here[..<here.range(of: "/", options: .backwards)!.lowerBound]) : ""
        load()
    }

    private func load() {
        busy = true; error = nil
        Task {
            dirs = await model.browse(current)
            busy = false
        }
    }
}

// MARK: - markers step (see both sides before trusting them)

struct MarkersStep: View {
    @ObservedObject var model: StatusModel
    let path1: String
    let path2: String
    let onNext: () -> Void

    @State private var count1 = "…"
    @State private var count2 = "…"
    @State private var placed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ferry places a small marker file on each side. If a side ever mounts empty or unreachable, the missing marker stops a sync from reading it as “everything was deleted”.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(path1) { Text("\(count1) top-level entries") }
                    LabeledContent(path2) { Text("\(count2) top-level entries") }
                }
                .padding(6)
            }
            Text("Check these counts look like the two sides you expect — a folder that should have your files but shows 0 entries is the thing to stop for.")
                .font(.callout)

            if model.actionRunning || !model.actionOutput.isEmpty {
                ActionOutput(model: model)
            }

            HStack {
                Spacer()
                if !placed {
                    Button {
                        model.runAction("Place Markers", ["markers", "--yes"])
                        placed = true
                    } label: { Label("Counts Look Right — Place Markers", systemImage: "checkmark.shield") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(count1 == "…" || model.actionRunning)
                } else {
                    Button {
                        onNext()
                    } label: { Label("Continue", systemImage: "arrow.right") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.actionRunning || (model.actionExit ?? 1) != 0)
                }
            }
        }
        .frame(maxWidth: 560)
        .onAppear {
            Task {
                count1 = await model.peek(path1)
                count2 = await model.peek(path2)
            }
        }
    }
}

// MARK: - first resync

struct ResyncStep: View {
    @ObservedObject var model: StatusModel
    let onNext: () -> Void
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The first sync builds the baseline: both sides are combined (nothing is deleted from either), and ferry records the listings that let every later run tell a deletion from a new file.")
                .foregroundStyle(.secondary)
            Text("With a large drive this can take a while — it is safe to leave running.")
                .font(.callout).foregroundStyle(.secondary)

            if model.actionRunning || !model.actionOutput.isEmpty {
                ActionOutput(model: model)
            }

            HStack {
                Spacer()
                if !started {
                    Button {
                        model.runAction("Establish the Pair", ["resync", "--yes"])
                        started = true
                    } label: { Label("Start First Sync", systemImage: "play.fill") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.actionRunning)
                } else {
                    Button {
                        onNext()
                    } label: { Label("Continue", systemImage: "arrow.right") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.actionRunning || (model.actionExit ?? 1) != 0)
                }
            }
        }
        .frame(maxWidth: 560)
    }
}
