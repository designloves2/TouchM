import SwiftUI
import TouchMCore

/// Diagnostics: device, live contacts, log.
struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    @State private var log = ""
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("State") {
                    HStack(spacing: 6) { StatusDot(color: model.device.connected ? .green : .red); Text(model.device.connected ? "Connected" : "Not found") }
                }
                LabeledContent("Input mode", value: model.device.modeOK ? "Multi-touch" : "Mouse (not switched)")
                ForEach(model.device.info, id: \.0) { LabeledContent($0.0, value: $0.1) }
                LabeledContent("Report rate", value: "\(model.fps) frames/s")
                HStack {
                    Button("Re-send multi-touch mode") { model.device.resendMode() }
                    Spacer()
                    Toggle("Debug log", isOn: Binding(get: { TMLog.enabled }, set: { TMLog.enabled = $0 })).toggleStyle(.switch)
                }
            }
            Section("Live contacts") {
                if model.live.isEmpty {
                    Text("No fingers on the panel").foregroundStyle(.secondary)
                } else {
                    ForEach(model.live, id: \.id) { c in
                        HStack {
                            Text("#\(c.id)").fontWeight(.semibold).frame(width: 32, alignment: .leading)
                            Text("x \(c.x)   y \(c.y)").monospacedDigit()
                            Spacer()
                            Text("\(c.width)×\(c.height)").monospacedDigit().foregroundStyle(.secondary)
                            if !c.confident { Text("palm?").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            Section("Log") {
                ScrollView {
                    Text(log.isEmpty ? "Empty" : log).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 150)
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.dir.appendingPathComponent("debug.log")]) }
                    Button("Clear") { try? Data().write(to: Store.dir.appendingPathComponent("debug.log")); log = "" }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .onAppear(perform: refresh).onReceive(tick) { _ in refresh() }
    }

    func refresh() {
        let t = (try? String(contentsOf: Store.dir.appendingPathComponent("debug.log"), encoding: .utf8)) ?? ""
        log = t.split(separator: "\n").suffix(40).joined(separator: "\n")
    }
}
