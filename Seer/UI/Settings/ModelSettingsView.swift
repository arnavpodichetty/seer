import SwiftUI

struct ModelSettingsView: View {
    let environment: AppEnvironment
    @State private var refreshing = false

    var body: some View {
        @Bindable var settings = environment.settings
        let state = environment.state
        let hasKey = settings.geminiAPIKey != nil
        let hasGroqKey = settings.groqAPIKey != nil
        Form {
            Section {
                Picker("Order", selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                if settings.aiProvider != .ollama, let custom = settings.activeCustomModel {
                    LabeledContent("Tried first") {
                        Button(custom) { environment.openSettings(tab: .apiKeys) }
                            .buttonStyle(.link)
                    }
                }
                if settings.aiProvider != .ollama && (!hasKey || !hasGroqKey) {
                    LabeledContent {
                        Button("Add Keys…") { environment.openSettings(tab: .apiKeys) }
                    } label: {
                        Label("Missing \([hasGroqKey ? nil : "Groq", hasKey ? nil : "Gemini"].compactMap { $0 }.joined(separator: " and ")) key",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(settings.aiProvider == .ollama
                     ? "Everything stays on this Mac."
                     : "If a provider fails, is busy or hits its free limit, Seer moves to the next one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Answers") {
                Picker("Speed", selection: $settings.speedPreference) {
                    ForEach(SpeedPreference.allCases) { Text($0.label).tag($0) }
                }
                Picker("Detail", selection: $settings.detailLevel) {
                    ForEach(DetailLevel.allCases) { Text($0.label).tag($0) }
                }
                Picker("Maximum length", selection: $settings.maxResponseTokens) {
                    Text("Short").tag(512)
                    Text("Medium").tag(1024)
                    Text("Long").tag(2048)
                    Text("Very long").tag(4096)
                }
                Toggle(isOn: $settings.useAIClassification) {
                    Text("Double-check uncertain questions")
                    Text("Asks the AI whether borderline text is really a question.")
                }
                Toggle(isOn: $settings.useWebSearch) {
                    Text("Search the web when needed")
                    Text("Only for questions about a company or recent events. Needs a Gemini key with billing turned on; the first 5,000 searches a month are free.")
                }
                .disabled(settings.geminiAPIKey == nil)
            }

            if settings.aiProvider != .ollama {
                Section("Groq") {
                    Picker("Model", selection: $settings.groqModel) {
                        ForEach(AppSettings.groqModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Images", selection: $settings.groqVisionModel) {
                        ForEach(AppSettings.groqVisionModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Gemini") {
                    Picker("Model", selection: $settings.geminiModel) {
                        ForEach(AppSettings.geminiModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("If busy", selection: $settings.geminiFallbackModel) {
                        ForEach(AppSettings.geminiModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Images", selection: $settings.geminiVisionModel) {
                        ForEach(AppSettings.geminiModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.ollamaStatus.isConnected ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(state.ollamaStatus.label).foregroundStyle(.secondary)
                        if refreshing { ProgressView().controlSize(.small) }
                        Button("Check", action: refresh)
                    }
                }
                DisclosureGroup("Advanced") {
                    TextField("Server", text: $settings.ollamaAddress, prompt: Text("http://127.0.0.1:11434"))
                        .onSubmit { refresh() }
                    modelPicker("Text model", selection: $settings.textModel, installed: state.installedModels)
                    modelPicker("Vision model", selection: $settings.visionModel, installed: state.installedModels)
                    if state.visionModelCapable == false {
                        Label("“\(settings.visionModel)” doesn't support images. Choose a vision model such as qwen3-vl:4b.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Picker("Strategy", selection: $settings.modelStrategy) {
                        ForEach(ModelStrategy.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Keep only one model in memory", isOn: $settings.keepSingleModelLoaded)
                    Picker("Timeout", selection: $settings.requestTimeout) {
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("3 minutes").tag(180.0)
                        Text("5 minutes").tag(300.0)
                    }
                }
            } header: {
                Text(settings.aiProvider == .ollama ? "Ollama" : "Ollama (offline fallback)")
            } footer: {
                if state.ollamaStatus.isConnected {
                    EmptyView()
                } else {
                    Text("Optional. Install Ollama from ollama.com, then run “ollama pull \(settings.textModel)” and “ollama pull \(settings.visionModel)” in Terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func modelPicker(_ title: String, selection: Binding<String>, installed: [OllamaModelInfo]) -> some View {
        let names = installed.map(\.name)
        let current = selection.wrappedValue
        Picker(title, selection: selection) {
            ForEach(installed) { model in
                Text(model.sizeDescription.isEmpty ? model.name : "\(model.name) (\(model.sizeDescription))").tag(model.name)
            }
            if !ModelRouter.isInstalled(current, in: names) {
                Text("\(current) (not installed)").tag(current)
            }
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            await environment.orchestrator.refreshOllamaStatus()
            refreshing = false
        }
    }
}
