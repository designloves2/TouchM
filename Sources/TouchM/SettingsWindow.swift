import SwiftUI

/// Settings window hosted by AppKit; more dependable than openWindow for a menu-bar (accessory) app.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(page: SettingsPage? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "TouchM"; w.titlebarAppearsTransparent = true; w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false; w.center(); w.setFrameAutosaveName("TouchMSettings")
            window = w
        }
        window?.contentView = NSHostingView(rootView: SettingsView(initial: page ?? .overview).environmentObject(AppModel.shared))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension SettingsWindow {
    /// Debug aid: renders a settings page into a PNG without needing Screen Recording permission.
    func snapshot(page: SettingsPage, to path: String, dark: Bool = false, size: NSSize = NSSize(width: 980, height: 680)) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: SettingsView(initial: page).environmentObject(AppModel.shared))
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        w.setFrame(NSRect(origin: NSPoint(x: -3000, y: 0), size: size), display: true)   // off-screen but laid out
        w.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            w.orderOut(nil)
        }
    }
}


extension SettingsWindow {
    func snapshot<V: View>(view: V, size: NSSize, to path: String, dark: Bool) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environmentObject(AppModel.shared))
        host.frame = NSRect(origin: .zero, size: size); w.contentView = host
        w.setFrame(NSRect(origin: NSPoint(x: -3000, y: 0), size: size), display: true); w.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            w.orderOut(nil)
        }
    }
}
