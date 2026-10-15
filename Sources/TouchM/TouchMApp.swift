import SwiftUI
import TouchMCore

@main
struct TouchMApp: App {
    @StateObject private var model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppModel.shared.start()
            StatusController.shared.start()
            // Debug aid: TOUCHM_PAGE=touch opens that settings page at launch.
            if let dir = ProcessInfo.processInfo.environment["TOUCHM_DEMO"] {
                // Safari rules as in the bug report: the held-key condition was set instead of the shortcut's own modifier.
                var st = AppModel.shared.settings
                var a = CommanderRule(gesture: "three finger swipe right", action: "keystroke", params: ["key": "]"], appId: "com.apple.Safari"); a.modifiers = ["cmd"]
                st.commands.removeAll { $0.appId == "com.apple.Safari" }; st.commands.append(a)
                AppModel.shared.settings = st
                SettingsWindow.shared.snapshot(view: CommanderView(startApp: "com.apple.Safari", select: a.id).padding(20), size: NSSize(width: 1000, height: 640), to: "\(dir)/demo.png", dark: false)
            }
            if let dir = ProcessInfo.processInfo.environment["TOUCHM_RESIZE"] {
                // Same page at a small and a large window size, to check that the content grows with the window.
                SettingsWindow.shared.snapshot(page: .commander, to: "\(dir)/commander-small.png", size: NSSize(width: 980, height: 620))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { SettingsWindow.shared.snapshot(page: .commander, to: "\(dir)/commander-large.png", size: NSSize(width: 1200, height: 1100)) }
            }
            if let dir = ProcessInfo.processInfo.environment["TOUCHM_KEYS"] {
                let dark = ProcessInfo.processInfo.environment["TOUCHM_DARK"] != nil
                SettingsWindow.shared.snapshot(view: GroupBox { KeystrokeEditor(combo: .constant("ctrl+shift+left")).frame(maxWidth: .infinity, alignment: .leading) }.padding(16), size: NSSize(width: 620, height: 130), to: "\(dir)/keys.png", dark: dark)
            }
            if let dir = ProcessInfo.processInfo.environment["TOUCHM_MENU"] {
                let dark = ProcessInfo.processInfo.environment["TOUCHM_DARK"] != nil
                SettingsWindow.shared.snapshot(view: MenuPanel(), size: NSSize(width: 380, height: 190), to: "\(dir)/menu.png", dark: dark)
            }
            if let dir = ProcessInfo.processInfo.environment["TOUCHM_SNAPSHOT"] {
                for (i, p) in SettingsPage.allCases.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2) { SettingsWindow.shared.snapshot(page: p, to: "\(dir)/\(p.rawValue).png", dark: ProcessInfo.processInfo.environment["TOUCHM_DARK"] != nil) }
                }
            }
            if let name = ProcessInfo.processInfo.environment["TOUCHM_PAGE"] { SettingsWindow.shared.show(page: SettingsPage(rawValue: name) ?? .overview) }
        }
    }

    var body: some Scene {
        // The real menu bar item is StatusController's; this scene only gives SwiftUI something to run and never appears.
        MenuBarExtra(isInserted: .constant(false)) { EmptyView() } label: { EmptyView() }
    }
}
