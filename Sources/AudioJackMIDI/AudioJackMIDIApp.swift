import SwiftUI

@main
struct AudioJackMIDIApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        Window("AudioJack MIDI", id: "main") {
            ContentView(state: state)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in state.shutdown() }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var advanced = false
    @State private var tests = false
    @State private var diagnostics = false

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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
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
                    VStack(alignment: .leading, spacing: 5) {
                        Text("VIRTUAL MIDI INPUT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text("AudioJack MIDI Out").font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                        Text("Choose this as the MIDI output in your DAW or MIDI app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down").foregroundStyle(.secondary)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AUDIO OUTPUT DEVICE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        HStack {
                            Picker("Audio output device", selection: $state.selectedDevice) {
                                if state.devices.isEmpty { Text("No stereo output devices").tag(UInt32(0)) }
                                ForEach(state.devices) { Text($0.name).tag($0.id) }
                            }.labelsHidden().disabled(state.running || state.busy)
                            Button { state.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Refresh output devices").disabled(state.running || state.busy)
                        }
                        Text("\(state.sampleRate / 1000) kHz stereo · \(Int((state.amplitude * 100).rounded()))% amplitude · \(state.reversed ? "Reversed" : "Normal") polarity")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(state.running ? "Stop adapter" : "Start adapter") { state.running ? state.stop() : state.start() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(state.busy || !state.portReady || !state.supportedRates.contains(state.sampleRate))
                        Spacer()
                        Button("Panic", role: .destructive) { state.panic() }
                            .keyboardShortcut(".", modifiers: [.command])
                            .help("All Notes Off and All Sound Off on every channel (⌘.)")
                            .disabled(!state.running || state.busy)
                    }
                    Text(state.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(state.running
                         ? "Forwarding incoming MIDI to \(deviceName)."
                         : "The virtual port stays available. Start the adapter to forward incoming MIDI.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Divider()
                DisclosureGroup("Adapter settings", isExpanded: $advanced) { settings.padding(.top, 12) }
                DisclosureGroup("Test generator", isExpanded: $tests) { testControls.padding(.top, 12) }
                DisclosureGroup("Diagnostics & byte monitor", isExpanded: $diagnostics) { monitor.padding(.top, 12) }
                Text("Experimental transport. AudioJack MIDI drives a TRS MIDI input from a headphone output and is not electrically compliant with the MIDI specification. Compatibility is not guaranteed.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }.disclosureGroupStyle(FullWidthDisclosureStyle())
            .frame(width: 500, height: advanced || tests || diagnostics ? 760 : 600)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Sample rate", selection: $state.sampleRate) {
                Text("96 kHz").tag(96000); Text("192 kHz").tag(192000)
            }.pickerStyle(.segmented).disabled(state.running || state.busy)
            Text("Stop the adapter to change device or rate. Other settings apply live.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Amplitude")
                Slider(value: $state.amplitude, in: 0.50...0.99, step: 0.01)
                Text("\(Int((state.amplitude * 100).rounded()))%").monospacedDigit().frame(width: 42)
            }
            Picker("Polarity", selection: $state.reversed) {
                Text("Normal").tag(false); Text("Reversed").tag(true)
            }.pickerStyle(.segmented)
            Picker("Note Off", selection: $state.velocityZero) {
                Text("Standard 0x8n").tag(false); Text("Note On, velocity 0").tag(true)
            }.pickerStyle(.segmented)
            Stepper("Inter-message idle: \(state.idleBits) bits", value: $state.idleBits, in: 0...4)
        }
    }

    private var testControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send notes without a DAW to check the hardware connection.").font(.caption).foregroundStyle(.secondary)
            Picker("Test channel", selection: $state.channel) {
                ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
            }.frame(width: 180)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(TestPattern.allCases) { pattern in
                    Button(pattern.rawValue) { state.run(pattern) }.frame(maxWidth: .infinity)
                }
            }.disabled(!state.running || state.busy)
            Button(state.repeating ? "Stop diagnostic + Panic" : "Repeat C4 → E4 → G4 → C5") { state.toggleDiagnostic() }
                .disabled(!state.running || state.busy)
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
