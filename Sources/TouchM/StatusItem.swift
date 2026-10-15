import SwiftUI
import AppKit
import Combine

/// Menu bar icon and its panel, built on NSStatusItem + NSPopover. SwiftUI's MenuBarExtra could leave the icon stuck in its
/// pressed state after the panel had closed by itself (needing a click elsewhere first); here the state follows the popover.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    static let shared = StatusController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    private var closedAt = Date.distantPast

    func start() {
        let model = AppModel.shared
        let host = NSHostingController(rootView: MenuPanel().environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let b = item.button {
            b.target = self; b.action = #selector(toggle)
            b.sendAction(on: [.leftMouseDown])
        }
        updateIcon()
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.updateIcon() } }.store(in: &bag)
    }
    private func updateIcon() {
        let m = AppModel.shared
        let name = m.device.connected && m.settings.enabled ? "hand.point.up.left.fill" : "hand.point.up.left"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "TouchM")
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        // A transient popover closes itself on the very press that lands on the icon; that press must not reopen it.
        if Date().timeIntervalSince(closedAt) < 0.35 { return }
        guard let b = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        b.highlight(true)
    }
    func close() { if popover.isShown { popover.performClose(nil) } }
    func popoverDidClose(_ notification: Notification) { closedAt = Date(); item.button?.highlight(false) }
}
