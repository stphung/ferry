// Ferry.app — a Dropbox-style menu bar app over the ferry CLI.
//
// All logic, config and safety rails live in the bash script; this app renders
// ferry's machine interfaces (status/activity/attic/doctor --porcelain) and
// shells out for actions. If the app dies, ferry loses nothing but the icon.
//
// Deliberately NOT here: a sync timer (launchd owns the schedule), any direct
// network call, and any one-click resync (the typed ritual lives in
// ResyncWindow).

import SwiftUI
import ServiceManagement

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
            PopoverView(model: model)
        } label: {
            // state carried by symbol shape; text carries age/counts.
            // start() hangs off the LABEL, not the popover content: the label
            // renders immediately, the content only on first click.
            HStack {
                Image(systemName: model.symbol)
                if !model.title.isEmpty { Text(model.title) }
            }
            .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Ferry Output", id: "output") {
            OutputWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Ferry Doctor", id: "doctor") {
            DoctorWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Ferry Attic", id: "attic") {
            AtticWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Ferry Resync", id: "resync") {
            ResyncWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Ferry Settings", id: "settings") {
            SettingsWindow(model: model)
        }
        .windowResizability(.contentSize)
    }
}
