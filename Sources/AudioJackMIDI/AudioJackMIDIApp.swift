import SwiftUI

@main
struct AudioJackMIDIApp: App {
    @NSApplicationDelegateAdaptor(AudioJackAppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        Window("AudioJack MIDI", id: "main") {
            ContentView(state: state)
                .onAppear { delegate.state = state }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
final class AudioJackAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        state.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var advanced = false
    @State private var tests = false
    @State private var diagnostics = false
    @State private var calibrationExpanded = true

    private var deviceName: String {
        state.devices.first(where: { $0.id == state.selectedDevice })?.name ?? "No output selected"
    }
    private var connectionTitle: String {
        if state.busy { return "Updating adapter…" }
        if !state.portReady { return "MIDI port unavailable" }
        if !state.running { return "Adapter paused" }
        return state.activity ? "Receiving MIDI" : "Listening for MIDI"
    }
    private var connectionColor: Color {
        if !state.portReady { return .orange }
        return state.running && !state.busy ? .green : .secondary
    }
    private var calibrationEnabled: Bool {
        state.running && !state.busy && state.calibrationAvailable
    }
    private var amplitudeStep: Binding<Double> {
        let levels = AppState.calibrationAmplitudeLevels
        return Binding(
            get: {
                Double(levels.enumerated().min(by: {
                    abs($0.element - state.amplitude) < abs($1.element - state.amplitude)
                })?.offset ?? 0)
            },
            set: { newValue in
                let index = min(max(Int(newValue.rounded()), 0), levels.count - 1)
                state.amplitude = levels[index]
            }
        )
    }
    private var appIcon: NSImage {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return NSApplication.shared.applicationIconImage
        }
        return image
    }
    private var maximumContentHeight: CGFloat {
        max(500, (NSScreen.main?.visibleFrame.height ?? 900) - 100)
    }
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: appIcon)
                        .resizable().frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AudioJack MIDI").font(.title2.bold())
                        Text("Virtual MIDI → TRS MIDI adapter").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Circle().fill(connectionColor).frame(width: 9, height: 9)
                        Text(connectionTitle).font(.headline)
                        Spacer()
                        if state.running { Text("OUTPUT ON").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("VIRTUAL MIDI OUTPUT").sectionLabel()
                            Label("AudioJack MIDI Out", systemImage: "pianokeys")
                                .font(.system(size: 17, weight: .medium)).textSelection(.enabled)
                            Text("Available as a MIDI output in your DAW or MIDI app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 30)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AUDIO OUTPUT DEVICE").sectionLabel()
                            HStack {
                                Picker("Audio output device", selection: $state.selectedDevice) {
                                    if state.devices.isEmpty { Text("No stereo output devices").tag(UInt32(0)) }
                                    ForEach(state.devices) { Text($0.name).tag($0.id) }
                                }.labelsHidden().disabled(state.running || state.busy)
                                Button { state.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                                    .help("Refresh output devices").disabled(state.running || state.busy)
                            }
                            Text("\(state.sampleRate / 1000) kHz stereo · \(Int((state.amplitude * 100).rounded()))% amplitude · TRS MIDI \(state.reversed ? "Type A" : "Type B")")
                                .font(.caption).foregroundStyle(.secondary)
                            if state.outputVolume.needsAttention { volumeWarning }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        HStack {
                            VStack(alignment: .center, spacing: 4) {
                                Text("TRS MIDI TYPE").sectionLabel()
                                Picker("TRS MIDI type", selection: $state.reversed) {
                                    Text("A").tag(true)
                                    Text("B").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 130)
                                .disabled(state.busy)
                            }
                            Spacer()
                            Button("Panic", role: .destructive) { state.panic() }
                                .keyboardShortcut(".", modifiers: [.command])
                                .help("All Notes Off and All Sound Off on every channel (⌘.)")
                                .disabled(!state.running || state.busy)
                        }
                        Button { state.running ? state.stop() : state.start() } label: {
                            Text(state.running ? "Stop adapter" : "Start adapter")
                                .font(.headline.bold())
                                .frame(width: 165, height: 40)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(state.busy || !state.portReady || !state.supportedRates.contains(state.sampleRate))
                    }
                    VStack(spacing: 3) {
                        Text(state.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(state.running
                             ? "Forwarding incoming MIDI to \(deviceName)."
                             : "The virtual port stays available. Start the adapter to forward incoming MIDI.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity)
                }
                if !state.supportedRates.contains(state.sampleRate) {
                    Text("This device does not advertise \(state.sampleRate / 1000) kHz. Select another device or change the rate in Adapter settings.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if state.repeating {
                    HStack {
                        Label("Diagnostic sequence is repeating", systemImage: "repeat").font(.caption)
                        Spacer()
                        Button("Stop diagnostic") { state.toggleDiagnostic() }.font(.caption)
                    }
                }
                calibration
                boxedDisclosure(title: "Testing", isExpanded: $tests, dimmed: !state.running || state.busy) {
                    Text("Channel \(state.channel)").font(.caption).foregroundStyle(.secondary)
                } content: { testControls }
                boxedDisclosure(title: "Advanced settings", isExpanded: $advanced, dimmed: false) {
                    Text("\(state.sampleRate / 1000) kHz · \(state.velocityZero ? "Velocity-zero Note Off" : "Standard Note Off")")
                        .font(.caption).foregroundStyle(.secondary)
                } content: { settings }
                boxedDisclosure(title: "Diagnostics & byte monitor", isExpanded: $diagnostics, dimmed: false) {
                    EmptyView()
                } content: { monitor }
                Text("Experimental transport. AudioJack MIDI drives a TRS MIDI input from a headphone output and is not electrically compliant with the MIDI specification. Compatibility is not guaranteed.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .disclosureGroupStyle(FullWidthDisclosureStyle())
            .frame(width: 720)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 720)
        .frame(maxHeight: maximumContentHeight)
    }

    private var volumeWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: state.outputVolume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Text(state.outputVolume.muted
                 ? "Output is muted. Set it to 100% to enable calibration."
                 : "Output volume is \(state.outputVolumePercent ?? 0)%. Set it to 100% to enable calibration.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open Sound Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
        }
        .padding(8)
        .foregroundStyle(.orange)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                calibrationExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: calibrationExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                    Text("Calibration").font(.title3.bold())
                    Spacer()
                    Text("Step \(state.calibrationStep) of 2")
                        .font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if calibrationExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Two quick steps to find reliable settings.").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Channel", selection: $state.channel) {
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }.frame(width: 145)
                        Picker("Note", selection: $state.calibrationNote) {
                            ForEach(0...127, id: \.self) { Text(noteName($0)).tag($0) }
                        }.frame(width: 170)
                    }
                    calibrationStepOne
                    calibrationStepTwo
                }
                .disabled(!calibrationEnabled)
                .opacity(calibrationEnabled ? 1 : 0.48)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.10)))
        .opacity(calibrationEnabled ? 1 : 0.48)
    }

    private func boxedDisclosure<Trailing: View, Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        dimmed: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content().padding(.top, 12)
        } label: {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                trailing()
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.10)))
        .opacity(dimmed ? 0.48 : 1)
    }

    private var calibrationStepOne: some View {
        calibrationCard(step: 1, title: "Find the signal level", subtitle: "Start low. Increase until your instrument plays reliably.") {
            VStack(spacing: 10) {
                Grid(horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Amplitude")
                        Slider(value: amplitudeStep, in: 0...Double(AppState.calibrationAmplitudeLevels.count - 1), step: 1)
                        Text("\(Int((state.amplitude * 100).rounded()))%")
                            .monospacedDigit().frame(width: 48)
                    }
                    GridRow {
                        Color.clear.frame(height: 1)
                        HStack(spacing: 0) {
                            ForEach(AppState.calibrationAmplitudeLevels, id: \.self) { level in
                                Text("\(Int((level * 100).rounded()))")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Color.clear.frame(width: 48, height: 1)
                    }
                }
                calibrationActions(playTitle: "Play test note", active: state.calibrationStep == 1)
            }
        }
    }

    private var calibrationStepTwo: some View {
        calibrationCard(step: 2, title: "Find reliable message spacing", subtitle: "Send a burst of notes and CC. Increase spacing if notes drop or stick.") {
            VStack(spacing: 10) {
                HStack {
                    Text("Message spacing")
                    Slider(value: $state.messageIntervalMS, in: 0...20, step: 0.5)
                    Text("\(state.messageIntervalMS, specifier: "%.1f") ms").monospacedDigit().frame(width: 68)
                }
                calibrationActions(playTitle: "Play test burst", active: state.calibrationStep == 2)
            }
        }
        .opacity(state.calibrationStep == 2 ? 1 : 0.55)
    }

    private func calibrationCard<Content: View>(step: Int, title: String, subtitle: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(step)").font(.headline).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }

    private func calibrationActions(playTitle: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Button { state.playCalibrationTest() } label: {
                Label(playTitle, systemImage: "play.fill").frame(minWidth: 130)
            }.buttonStyle(.borderedProminent)
            if active && state.calibrationQuestionVisible {
                Text("Did it work?").fontWeight(.medium)
                Button("Yes") { state.calibrationWorked() }
                    .buttonStyle(AnswerButtonStyle(color: .green))
                Button("No") { state.calibrationFailed() }
                    .buttonStyle(AnswerButtonStyle(color: .red))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .disabled(!active || !state.running || state.busy)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Sample rate", selection: $state.sampleRate) {
                Text("96 kHz").tag(96000); Text("192 kHz").tag(192000)
            }.pickerStyle(.segmented).disabled(state.running || state.busy)
            Text("Stop the adapter to change device or rate. Note Off mode applies live.").font(.caption).foregroundStyle(.secondary)
            Picker("Note Off", selection: $state.velocityZero) {
                Text("Standard 0x8n").tag(false); Text("Note On, velocity 0").tag(true)
            }.pickerStyle(.segmented)
            Text("Amplitude and message spacing are set in Calibration. Inter-message idle is fixed at zero.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Send diagnostic MIDI without opening a DAW.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Channel", selection: $state.channel) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 150)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(TestPattern.allCases) { pattern in
                    Button { state.run(pattern) } label: {
                        Label(testTitle(pattern), systemImage: testIcon(pattern))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                }
            }.disabled(!state.running || state.busy)
            HStack {
                Label("Repeat C4 → E4 → G4 → C5", systemImage: "repeat")
                Spacer()
                Button(state.repeating ? "Stop" : "Play") { state.toggleDiagnostic() }
                    .disabled(!state.running || state.busy)
            }.padding(8).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func noteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(note) (\(names[note % 12])\(note / 12 - 1))"
    }
    private func testTitle(_ pattern: TestPattern) -> String {
        switch pattern {
        case .single: return "Single note"
        case .scale: return "C major scale"
        case .chord: return "C major chord"
        case .velocity: return "Velocity"
        case .fast: return "Fast notes"
        case .program: return "Program change"
        case .bend: return "Pitch bend"
        case .stress: return "Stress test"
        }
    }
    private func testIcon(_ pattern: TestPattern) -> String {
        switch pattern {
        case .single: return "music.note"
        case .scale, .velocity: return "chart.bar.fill"
        case .chord: return "line.3.horizontal"
        case .fast: return "music.note.list"
        case .program: return "doc.text"
        case .bend: return "waveform.path"
        case .stress: return "bolt.fill"
        }
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(state.received) bytes in · \(state.sent) sent · \(state.queued) queued · \(state.dropped) dropped")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Text("Includes test traffic and Panic output.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Clear log") { state.log.removeAll() }.font(.caption)
            }
            ScrollView {
                Text(state.log.joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130).padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct AnswerButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold).foregroundStyle(.white)
            .frame(minWidth: 54).padding(.vertical, 6)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension View {
    func sectionLabel() -> some View {
        font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// A single keyboard-accessible button owns the entire header hit area.
private struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
