import SwiftUI
import TouchMCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, touch, display, magnifier, commander, console, general
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"; case .touch: "Touch"; case .display: "Display"
        case .magnifier: "Magnifier"; case .commander: "Commander"; case .console: "Console"; case .general: "General"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"; case .touch: "hand.tap.fill"; case .display: "display"
        case .magnifier: "plus.magnifyingglass"; case .commander: "command"; case .console: "waveform.path.ecg"; case .general: "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .overview: .blue; case .touch: .green; case .display: .indigo
        case .magnifier: .teal; case .commander: .orange; case .console: .gray; case .general: .secondary
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: SettingsPage?
    init(initial: SettingsPage = .overview) { _page = State(initialValue: initial) }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    row(.overview)
                }
                Section("Input") { row(.touch); row(.display); row(.magnifier) }
                Section("Automation") { row(.commander) }
                Section("System") { row(.console); row(.general) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    StatusDot(color: model.statusLine.color)
                    Text(LocalizedStringKey(model.statusLine.text)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12)
            }
        } detail: {
            Group {
                switch page ?? .overview {
                case .overview: OverviewPage()
                case .touch: TouchPage()
                case .display: DisplayPage()
                case .magnifier: MagnifierPage()
                case .commander: Page(title: "Commander", subtitle: "Gestures and the actions they trigger, per app and UI element.") { CommanderView().padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity) }
                case .console: Page(title: "Console", subtitle: "Device information, live touches and the diagnostic log.") { ConsoleView() }
                case .general: GeneralPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    func row(_ p: SettingsPage) -> some View {
        Label { Text(p.title) } icon: { IconTile(symbol: p.symbol, color: p.color, size: 24) }.tag(p)
    }
}

// MARK: - Overview
struct OverviewPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "Overview", subtitle: "Touch screen driver for macOS") {
            Form {
                Section {
                    HStack(spacing: 14) {
                        IconTile(symbol: "hand.point.up.left.fill", color: .blue, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.device.info.first { $0.0 == "Product" }?.1 ?? "No touch panel").font(.headline)
                            HStack(spacing: 6) {
                                StatusDot(color: model.statusLine.color)
                                Text(LocalizedStringKey(model.statusLine.text)).foregroundStyle(.secondary)
                                if model.device.connected {
                                    Text("· multi-touch \(model.device.modeOK ? "on" : "off") · \(model.fps) Hz").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Toggle("", isOn: $model.settings.enabled).toggleStyle(.switch).labelsHidden()
                    }.padding(.vertical, 4)
                }
                Section("Permissions") {
                    PermissionRow(title: "Accessibility", detail: "Lets TouchM click, drag and scroll for you.",
                                  granted: model.accessibilityOK) { model.openPrivacy("Privacy_Accessibility") }
                    PermissionRow(title: "Input Monitoring", detail: "Lets TouchM read the touch panel.",
                                  granted: model.inputMonitoringOK) { model.openPrivacy("Privacy_ListenEvent") }
                    PermissionRow(title: "Screen Recording (optional)", detail: "Only needed for the magnifier.",
                                  granted: model.screenRecordingOK) { model.openPrivacy("Privacy_ScreenCapture") }
                }
                Section("Tools") {
                    HStack(spacing: 10) {
                        ToolTile(symbol: "scope", title: "Calibrate", color: .indigo) { Calibration.shared.begin() }
                        ToolTile(symbol: "hand.draw.fill", title: "Touch test", color: .green) { Overlay.shared.testMode.toggle() }
                        ToolTile(symbol: "pencil.tip.crop.circle.fill", title: "Annotate", color: .pink) { Annotate.shared.toggle() }
                        ToolTile(symbol: "plus.magnifyingglass", title: "Magnifier", color: .teal) { Magnifier.shared.toggle() }
                        ToolTile(symbol: "command", title: "Commander", color: .orange) { SettingsWindow.shared.show(page: .commander) }
                    }.padding(.vertical, 4)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Touch
struct TouchPage: View {
    @EnvironmentObject var model: AppModel
    @State private var advanced = false
    var body: some View {
        Page(title: "Touch", subtitle: "How fingers become mouse, scroll and gesture input.") {
            Form {
                Section("Pointer") {
                    Picker("Touch acts as", selection: $model.settings.clickMode) {
                        Text("Click and drag").tag(0); Text("Move, then click").tag(1); Text("Point and click").tag(2); Text("Move only").tag(3)
                    }
                    Text("Click and drag: the button goes down where you touch and comes up when you lift. Move, then click: the pointer follows your finger and clicks when you lift. Point and click: a click at the first touch, movement ignored. Move only: no click.")
                        .font(.caption).foregroundStyle(.secondary)
                    ToggleRow(title: "Hide the pointer while touching", detail: "The arrow disappears under your finger, as on a tablet.", isOn: $model.settings.hideCursorDuringTouches)
                    ToggleRow(title: "Right-click by pressing and holding",
                              detail: "Rest a finger in place and a ring fills; release to open the context menu.",
                              isOn: $model.settings.rightClickOnHold)
                    if model.settings.rightClickOnHold {
                        Picker("When the time is up", selection: $model.settings.holdMode) {
                            Text("Right-click now").tag("immediate"); Text("Right-drag").tag("drag"); Text("Click on lift").tag("latched"); Text("Off").tag("off")
                        }
                        Text("Right-click now: the menu opens as soon as the ring fills. Right-drag: the right button is held until you lift. Click on lift: the menu opens when you lift.")
                            .font(.caption).foregroundStyle(.secondary)
                        IntSliderRow(title: "Hold time", detail: "How long you press before the right-click happens. Default: 550 ms.", value: $model.settings.holdMs, range: 100...2000, step: 50, unit: "ms")
                        ToggleRow(title: "Show hold ring", isOn: $model.settings.holdVisual)
                        if model.settings.holdVisual { IntSliderRow(title: "Ring appears after", detail: "The ring starts filling after this long and is full when the hold time is reached.", value: $model.settings.holdRingDelayMs, range: 0...1000, step: 50, unit: "ms") }
                        ToggleRow(title: "Hold in pages and lists: menu on release", detail: "In web pages and scrollable areas, hold then move to drag; hold then lift without moving to open the context menu.", isOn: $model.settings.holdReleaseMenu)
                    }
                    IntSliderRow(title: "Double-click time", detail: "Two taps within this time and distance count as a double-click.",
                                 value: $model.settings.assistedDoubleClickMs, range: 100...1000, step: 50, unit: "ms")
                }
                Section("Scrolling") {
                    ToggleRow(title: "Two-finger scrolling", isOn: $model.settings.twoFingerScroll)
                    if model.settings.twoFingerScroll {
                        ToggleRow(title: "Natural scrolling", detail: "Content follows your fingers.", isOn: $model.settings.naturalScroll)
                        SliderRow(title: "Speed", value: $model.settings.scrollSpeed, range: 0.2...3, step: 0.1, unit: "×", format: "%.1f")
                        ToggleRow(title: "Inertia", detail: "Content keeps gliding after you lift your fingers, like a tablet.", isOn: $model.settings.scrollMomentum)
                        if model.settings.scrollMomentum {
                            SliderRow(title: "Glide", detail: "How far it travels before stopping.", value: $model.settings.scrollInertia, range: 0...1, step: 0.05, format: "%.2f")
                        }
                    }
                }
                Section("Tablet feel") {
                    ToggleRow(title: "Drag to scroll in pages and lists",
                              detail: "In web pages and scrollable areas, one finger drags the content like a tablet. Press and hold, then drag, to select or move things. Finder keeps icon dragging.",
                              isOn: $model.settings.tabletScroll)
                }
                Section("Smoothness") {
                    SliderRow(title: "Smoothing", detail: "Steadies the pointer. Higher is smoother but adds lag.",
                              value: $model.settings.lowPassGain, range: 0...0.9, step: 0.05, format: "%.2f")
                    IntSliderRow(title: "Ignore first frames", detail: "Filters the jitter right after a finger lands.",
                                 value: $model.settings.deglitchFrames, range: 0...6)
                }
                Section("Mouse and touch together") {
                    ToggleRow(title: "Return the pointer after a touch",
                              detail: "Puts the mouse pointer back where it was before you touched, so a mouse and the touch screen can be used interchangeably.",
                              isOn: $model.settings.anchorMouse)
                    if model.settings.anchorMouse {
                        IntSliderRow(title: "Return after", value: $model.settings.anchorReturnMs, range: 0...3000, step: 50, unit: "ms")
                    }
                }
                Section("Feedback") {
                    ToggleRow(title: "Show touch points", detail: "Draw a circle under each finger. This is separate from the hold ring.", isOn: $model.settings.showTouchFeedback)
                    ToggleRow(title: "Sound when touching", isOn: $model.settings.soundOnTouch)
                    ToggleRow(title: "Sound when lifting", isOn: $model.settings.soundOnLift)
                }
                Section {
                    DisclosureGroup("Advanced gesture tuning", isExpanded: $advanced) {
                        IntSliderRow(title: "Lift-off timeout", detail: "A finger with no touch data for this long counts as lifted. 0 = off.", value: $model.settings.liftoffMs, range: 0...2000, step: 50, unit: "ms")
                        IntSliderRow(title: "Click duration", value: $model.settings.clickLastsMs, range: 10...200, step: 5, unit: "ms")
                        SliderRow(title: "Click-nearest distance", detail: "Snap a tap to a button this close to it.",
                                  value: $model.settings.clickNearestPx, range: 5...80, step: 5, unit: "px")
                        IntSliderRow(title: "Press & tap: first finger rests", value: $model.settings.pressTapRestMs, range: 50...600, step: 25, unit: "ms")
                        IntSliderRow(title: "Press & tap: second finger within", value: $model.settings.pressTapMaxMs, range: 150...1000, step: 25, unit: "ms")
                        SliderRow(title: "Swipe distance (3+ fingers)", value: $model.settings.swipeDistancePx, range: 40...400, step: 10, unit: "px")
                        SliderRow(title: "Edge swipe starts within", value: $model.settings.edgeMarginPx, range: 10...150, step: 5, unit: "px")
                        SliderRow(title: "Edge swipe distance", value: $model.settings.edgeDistancePx, range: 50...500, step: 10, unit: "px")
                        SliderRow(title: "Pinch zoom step", value: $model.settings.pinchStepPx, range: 10...120, step: 2, unit: "px")
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Display
struct DisplayPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "Display", subtitle: "Match touch positions to the screen.") {
            Form {
                Section("Resolution and rotation") {
                    DisplayControls()
                    Text("Rotating the screen turns the touch input with it. Resolution and rotation change immediately.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Brightness") {
                    BrightnessRows()
                }
                Section("Calibration") {
                    HStack(spacing: 12) {
                        Image(systemName: model.settings.calibration == nil ? "scope" : "checkmark.seal.fill")
                            .font(.title2).foregroundStyle(model.settings.calibration == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.settings.calibration == nil ? "Not calibrated" : "Calibrated").fontWeight(.medium)
                            Text(model.settings.calibration == nil ? "Using the rotation setting below." : "A custom transform is in use.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.settings.calibration != nil { Button("Reset") { model.settings.calibration = nil } }
                        Button("Calibrate…") { Calibration.shared.begin() }.buttonStyle(.borderedProminent)
                    }
                    Picker("Points", selection: $model.settings.calibrationPoints) {
                        Text("4").tag(4); Text("9").tag(9); Text("25").tag(25)
                    }.pickerStyle(.segmented)
                    Text("More points correct edge distortion better. Press Esc to cancel while calibrating.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Orientation") {
                    ToggleRow(title: "Follow display rotation", detail: "Rotates touch input when the screen is rotated in macOS.", isOn: $model.settings.autoRotate)
                    Picker("Override rotation", selection: Binding(get: { model.settings.rotationOverride ?? -1 },
                                                                   set: { model.settings.rotationOverride = $0 < 0 ? nil : $0 })) {
                        Text("Automatic").tag(-1)
                        Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                    }
                    Picker("Gesture direction", selection: $model.settings.gestureOrientation) {
                        Text("Automatic").tag("auto"); Text("Normal").tag("normal"); Text("Inverted").tag("inverted"); Text("Custom").tag("custom")
                    }.pickerStyle(.segmented)
                    Text("Swipes and screen-edge swipes are read as if the screen were turned the other way. Automatic reverses them when the display is rotated 180°. If an edge swipe reacts at the opposite edge, switch this.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.settings.gestureOrientation == "custom" {
                        ToggleRow(title: "Mirror left ↔ right", detail: "Swipes and edges on the left behave as on the right.", isOn: $model.settings.gestureFlipX)
                        ToggleRow(title: "Mirror up ↔ down", detail: "Off if swiping up from the bottom edge should be \"up\".", isOn: $model.settings.gestureFlipY)
                    }
                    ToggleRow(title: "Flip horizontally", isOn: $model.settings.flipX)
                    ToggleRow(title: "Flip vertically", isOn: $model.settings.flipY)
                    ToggleRow(title: "Swap X and Y", isOn: $model.settings.swapXY)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

// MARK: - General
struct GeneralPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "General", subtitle: "Startup, backup and about.") {
            Form {
                Section("Startup") {
                    ToggleRow(title: "Open TouchM at login", isOn: $model.settings.startAtLogin)
                    ToggleRow(title: "Re-initialise the panel after wake", detail: "Some panels fall back to mouse mode after sleep.", isOn: $model.settings.reinitOnWake)
                    IntSliderRow(title: "Delay touch after launch", value: $model.settings.startupDelaySec, range: 0...30, unit: "s")
                }
                Section("Backup") {
                    HStack {
                        Button("Export settings…") { model.exportSettings() }
                        Button("Import settings…") { model.importSettings() }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.dir]) }
                    }
                }
                Section("About") {
                    HStack(spacing: 14) {
                        IconTile(symbol: "hand.point.up.left.fill", color: .blue, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TouchM").font(.headline)
                            Text("Version 0.1.1 · touch driver, calibration, gestures and Commander in one app").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 2)
                    LabeledContent("Developer") { Text("TJ.Choi").textSelection(.enabled) }
                    LabeledContent("Email") { Link("tj.choi.79@gmail.com", destination: URL(string: "mailto:tj.choi.79@gmail.com")!) }
                    LabeledContent("GitHub") { Link("github.com/designloves2", destination: URL(string: "https://github.com/designloves2")!) }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}


// MARK: - Magnifier
struct MagnifierPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "Magnifier", subtitle: "A lens that enlarges the screen around your finger.") {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: model.screenRecordingOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3).foregroundStyle(model.screenRecordingOK ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.screenRecordingOK ? "Ready" : "Screen Recording permission needed").fontWeight(.medium)
                            Text("The lens reads the screen to enlarge it.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.screenRecordingOK { Button("Open Settings") { model.openPrivacy("Privacy_ScreenCapture") } }
                        Button("Show / hide") { Magnifier.shared.toggle() }.buttonStyle(.borderedProminent)
                    }
                }
                Section("Gesture") {
                    Picker("Opens and closes with", selection: $model.settings.magnifierGesture) {
                        ForEach(CommanderRule.magnifierChoices, id: \.self) { Text(Names.gesture($0)).tag($0) }
                    }
                    Text("Commander cannot use this gesture while it opens the magnifier. Any Commander rule that used it is switched off and shown with a lock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Behaviour") {
                    Picker("Lens", selection: $model.settings.magnifierFollow) {
                        Text("Stays put").tag("never"); Text("Touches").tag("touches"); Text("Mouse").tag("mouse")
                    }.pickerStyle(.segmented)
                    Text("Stays put: the lens opens where you tap. Touch inside it to press the magnified spot, and drag with two fingers to move it. Touches / Mouse: the lens stays centred on your finger or the pointer.")
                        .font(.caption).foregroundStyle(.secondary)
                    ToggleRow(title: "Animate lens movement", isOn: $model.settings.magnifierAnimate)
                }
                Section("Appearance") {
                    IntSliderRow(title: "Magnification", value: $model.settings.magnifierZoom, range: 125...800, step: 25, unit: "%")
                    SliderRow(title: "Width", value: $model.settings.magnifierWidth, range: 160...900, step: 10, unit: "px")
                    SliderRow(title: "Height", value: $model.settings.magnifierHeight, range: 120...700, step: 10, unit: "px")
                    Picker("Shape", selection: $model.settings.magnifierCircle) { Text("Rectangle").tag(false); Text("Circle").tag(true) }.pickerStyle(.segmented)
                    Picker("Refresh rate", selection: $model.settings.magnifierHz) { Text("15").tag(15); Text("30").tag(30); Text("60").tag(60) }.pickerStyle(.segmented)
                }
                Section("Pinch to zoom") {
                    SliderRow(title: "Speed", value: $model.settings.magnifierPinchSpeed, range: 0.3...3, step: 0.1, unit: "×", format: "%.1f")
                    ToggleRow(title: "Reverse direction", detail: "Spreading fingers zooms out.", isOn: $model.settings.magnifierZoomReversed)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

struct BrightnessRows: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var b = Brightness.shared
    var body: some View {
        Picker("Brightness method", selection: $model.settings.brightnessMethod) {
            Text("Automatic").tag("auto"); Text("Hardware (DDC)").tag("ddc"); Text("Software dimming").tag("software")
        }
        ForEach(b.screens) { s in
            SliderRow(title: LocalizedStringKey(s.name), detail: nil,
                      value: Binding(get: { (b.values[s.id] ?? 1) * 100 }, set: { b.set($0 / 100, for: s.id, method: model.settings.brightnessMethod) }),
                      range: 0...100, step: 1, unit: "%")
            SliderRow(title: "Contrast", detail: nil,
                      value: Binding(get: { (b.contrast[s.id] ?? 0.5) * 100 }, set: { b.setContrast($0 / 100, for: s.id, method: model.settings.brightnessMethod) }),
                      range: 0...100, step: 1, unit: "%")
        }
        Text("Hardware brightness uses DDC/CI over the display cable; monitors without it are dimmed in software.").font(.caption).foregroundStyle(.secondary)
    }
}
