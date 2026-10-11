import AppKit
import SwiftUI

struct PrivacySettingsView: View {
    let environment: AppEnvironment
    @State private var newKeyword = ""
    @State private var historyCount = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = environment.settings
        let state = environment.state
        Form {
            Section {
                LabeledContent("Monitoring") {
                    HStack(spacing: 6) {
                        Circle().fill(state.isMonitoring ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(state.isMonitoring ? "On" : "Paused")
                        Button(state.isMonitoring ? "Pause" : "Start") {
                            environment.orchestrator.setMonitoring(!state.isMonitoring)
                        }
                    }
                }
                LabeledContent("Status", value: state.captureStatus)
                if let date = state.lastCaptureAt {
                    LabeledContent("Last capture", value: date.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("Screen Recording") {
                    HStack {
                        Text(state.screenPermissionGranted ? "Granted" : "Not granted")
                        if !state.screenPermissionGranted {
                            Button("Open System Settings") { PermissionsManager.openScreenRecordingSettings() }
                        }
                    }
                }
            } header: {
                Text("Capture status")
            } footer: {
                Text("Screenshots stay in memory and are never saved. Only the question text, and a cropped image for picture questions, is sent to the AI provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(for: bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                                settings.excludedBundleIDs.append(id)
                            }
                        }
                    }
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Nothing is captured while an excluded app is in front, and capture pauses while you type in a password field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded windows") {
                ForEach(settings.excludedWindowKeywords, id: \.self) { keyword in
                    HStack {
                        Text(keyword)
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedWindowKeywords.removeAll { $0 == keyword }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Window title contains", text: $newKeyword, prompt: Text("e.g. Incognito"))
                        .onSubmit(addKeyword)
                    Button("Add", action: addKeyword).disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("History") {
                Toggle("Save answer history on this Mac", isOn: $settings.historyEnabled)
                    .onChange(of: settings.historyEnabled) {
                        let enabled = settings.historyEnabled
                        Task { await environment.cache.setPersistence(enabled) }
                    }
                LabeledContent("Saved answers", value: "\(historyCount)")
                Button("Clear Answer History…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear all saved answers?", isPresented: $confirmClear) {
                        Button("Clear History", role: .destructive) {
                            Task {
                                await environment.orchestrator.clearHistory()
                                await loadCount()
                            }
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .task { await loadCount() }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, !environment.settings.excludedWindowKeywords.contains(keyword) else { return }
        environment.settings.excludedWindowKeywords.append(keyword)
        newKeyword = ""
    }

    private func loadCount() async {
        historyCount = await environment.cache.all().count
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
