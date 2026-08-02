// The one panel. A sidebar of named pages — every item labelled, no naked
// icons — with onboarding replacing the whole panel until ferry is configured.

import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case status, activity, attic, doctor, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: return "Status"
        case .activity: return "Activity"
        case .attic: return "Attic"
        case .doctor: return "Doctor"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .status: return "arrow.left.arrow.right.circle"
        case .activity: return "clock.arrow.circlepath"
        case .attic: return "archivebox"
        case .doctor: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: StatusModel
    @State private var page: Page = {
        // FERRY_UI_PAGE exists so the UI can be screenshot per-page without
        // clicking; it is test scaffolding, never set in normal use.
        if let p = ProcessInfo.processInfo.environment["FERRY_UI_PAGE"],
           let pg = Page(rawValue: p) { return pg }
        return .status
    }()

    var body: some View {
        Group {
            if model.state == "unconfigured" || model.state == "noferry"
                || ProcessInfo.processInfo.environment["FERRY_UI_PAGE"] == "onboarding" {
                OnboardingView(model: model)
            } else {
                NavigationSplitView {
                    List(Page.allCases, selection: $page) { p in
                        Label(p.label, systemImage: p.symbol).tag(p)
                    }
                    .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
                } detail: {
                    switch page {
                    case .status:   StatusPage(model: model)
                    case .activity: ActivityPage(model: model)
                    case .attic:    AtticPage(model: model)
                    case .doctor:   DoctorPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.start() }
    }
}
