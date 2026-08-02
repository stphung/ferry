// Ferry.app — one panel, opened from a status item.
//
// The status item is AppKit (NSStatusItem): unlike MenuBarExtra it can open a
// window on click instead of showing its own content — which is the whole
// design — and its attributed title carries state by colour as well as symbol.
//
// All logic, config and safety rails live in the ferry CLI; this app renders
// its machine interfaces and shells out for actions.

import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

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
        Window("Ferry", id: "main") {
            MainView(model: AppDelegate.sharedModel)
        }
        .defaultSize(width: 820, height: 560)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // one model for the status item and the panel — created before SwiftUI
    // asks for it so both see the same instance
    static let sharedModel = StatusModel()

    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(togglePanel)
        item.button?.target = self
        statusItem = item

        Self.sharedModel.start()
        cancellable = Self.sharedModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                // objectWillChange fires before values land; render after
                DispatchQueue.main.async { self?.renderTitle() }
            }
        renderTitle()

        // First run lands in onboarding — show the panel without a click.
        // FERRY_UI_PAGE (screenshot scaffolding) also opens it, since nothing
        // can click the status item in an automated capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            let s = Self.sharedModel.state
            if s == "unconfigured" || s == "noferry"
                || ProcessInfo.processInfo.environment["FERRY_UI_PAGE"] != nil {
                self?.showPanel()
            }
        }
    }

    // clicking the icon opens (or focuses) the one panel — no popover
    @objc private func togglePanel() {
        if let w = panelWindow(), w.isKeyWindow {
            w.close()
        } else {
            showPanel()
        }
    }

    private func panelWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Ferry" }
    }

    private func showPanel() {
        if let w = panelWindow() {
            w.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI restores the Window scene on reopen events
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }
        let m = Self.sharedModel

        let color: NSColor
        switch m.state {
        case "blocked", "failed", "noferry": color = .systemRed
        case "stale", "unestablished", "never", "unconfigured": color = .systemOrange
        case "syncing": color = .systemBlue
        default: color = .labelColor
        }

        let text = m.title.isEmpty ? "" : " \(m.title)"
        let attach = NSTextAttachment()
        if let img = NSImage(systemSymbolName: m.symbol, accessibilityDescription: "Ferry") {
            let conf = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            attach.image = img.withSymbolConfiguration(conf)
        }
        let title = NSMutableAttributedString(attachment: attach)
        title.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuBarFont(ofSize: 0),
            .baselineOffset: 2,
        ]))
        button.attributedTitle = title
    }
}
