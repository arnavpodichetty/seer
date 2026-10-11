import SwiftUI

/// Where to paste the Groq and Gemini keys (with links to get free ones), plus an optional
/// custom OpenAI-compatible provider that's tried first.
struct APIKeysSettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        @Bindable var settings = environment.settings
        let hasGroqKey = settings.groqAPIKey != nil
        let hasGeminiKey = settings.geminiAPIKey != nil
        Form {
            Section {
                APIKeyRow(placeholder: "Paste Groq API key (gsk_…)", hasKey: hasGroqKey) { key in
                    settings.setGroqAPIKey(key)
                }
                Link(destination: URL(string: "https://console.groq.com/keys")!) {
                    Label("Get a free key at console.groq.com", systemImage: "arrow.up.forward.app")
                }
                TestRow(enabled: hasGroqKey) {
                    try await GroqClient(apiKey: settings.groqAPIKey ?? "").generateText(.init(
                        model: settings.groqModel, system: nil, text: "Reply with exactly: ok", maxTokens: 300, temperature: 0))
                }
            } header: {
                KeyHeader(title: "Groq", subtitle: "Free and fastest", saved: hasGroqKey)
            }

            Section {
                APIKeyRow(placeholder: "Paste Gemini API key (AIza…)", hasKey: hasGeminiKey) { key in
                    settings.setGeminiAPIKey(key)
                }
                Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                    Label("Get a free key at aistudio.google.com", systemImage: "arrow.up.forward.app")
                }
                TestRow(enabled: hasGeminiKey) {
                    try await GeminiClient(apiKey: settings.geminiAPIKey ?? "").generateText(.init(
                        model: settings.geminiModel, system: nil, text: "Reply with exactly: ok", maxOutputTokens: 256, temperature: 0, thinkingLevel: "low"))
                }
            } header: {
                KeyHeader(title: "Gemini", subtitle: "Backup provider, also strong with images", saved: hasGeminiKey)
            } footer: {
                Label("Both keys are free. They're stored in your Mac's Keychain and only sent to their own provider.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.customEnabled) {
                    Text("Use my own model first")
                    Text("Answers come from this model; Groq, Gemini and Ollama become backups.")
                }
                if settings.customEnabled {
                    TextField("API URL", text: $settings.customBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .autocorrectionDisabled()
                    TextField("Model", text: $settings.customModel, prompt: Text("Model name from your provider"))
                        .autocorrectionDisabled()
                    APIKeyRow(placeholder: "Paste API key", hasKey: settings.customAPIKey != nil) { key in
                        settings.setCustomAPIKey(key)
                    }
                    Toggle(isOn: $settings.customSendsImages) {
                        Text("Send images to this model")
                        Text("Turn off if the model can't read images; picture questions then go to Groq or Gemini.")
                    }
                    TestRow(enabled: settings.activeCustomModel != nil) {
                        guard let endpoint = settings.customEndpoint else { throw CloudAIError.missingKey }
                        return try await GroqClient(apiKey: settings.customAPIKey ?? "", endpoint: endpoint).generateText(.init(
                            model: settings.customModel, system: nil, text: "Reply with exactly: ok", maxTokens: 1024, temperature: 0, reasoningEffort: nil))
                    }
                }
            } header: {
                KeyHeader(title: "Custom model", subtitle: "Optional: any OpenAI-compatible API you pay for",
                          saved: settings.activeCustomModel != nil, savedLabel: "Active", unsetLabel: "Off", isOptional: true)
            } footer: {
                if settings.customEnabled {
                    Text("Works with OpenAI (https://api.openai.com/v1), OpenRouter (https://openrouter.ai/api/v1), DeepSeek (https://api.deepseek.com/v1) and other OpenAI-compatible services. The key is stored in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyHeader: View {
    let title: String
    let subtitle: String
    let saved: Bool
    var savedLabel = "Saved"
    var unsetLabel = "Not set"
    /// Optional features show "off" quietly instead of as a warning.
    var isOptional = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(saved ? savedLabel : unsetLabel,
                  systemImage: saved ? "checkmark.circle.fill" : (isOptional ? "circle" : "exclamationmark.circle"))
                .font(.caption)
                .foregroundStyle(saved ? Color.green : (isOptional ? Color.secondary : Color.orange))
        }
    }
}

/// Text box for pasting an API key; saving moves it to the Keychain.
struct APIKeyRow: View {
    let placeholder: String
    let hasKey: Bool
    let save: (String) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("API key", text: $draft, prompt: Text(hasKey ? "Key saved. Paste a new one to replace it" : placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if hasKey {
                Button("Remove saved key", role: .destructive) { save("") }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func commit() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        save(draft)
        draft = ""
    }
}

/// "Test connection" button that sends a tiny request and reports whether the key works.
struct TestRow: View {
    let enabled: Bool
    let run: () async throws -> String
    @State private var result: Result<TimeInterval, Error>?
    @State private var testing = false

    var body: some View {
        HStack {
            Button("Test connection") {
                testing = true
                result = nil
                Task {
                    let start = Date()
                    do {
                        _ = try await run()
                        result = .success(Date().timeIntervalSince(start))
                    } catch {
                        result = .failure(error)
                    }
                    testing = false
                }
            }
            .disabled(!enabled || testing)
            if testing {
                ProgressView().controlSize(.small)
            } else if enabled, let result {
                switch result {
                case let .success(seconds):
                    Label("Working · responded in \(String(format: "%.1f", seconds)) s", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .onChange(of: enabled) { result = nil }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Seer")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider().frame(width: 220).padding(.vertical, 4)
            Text("Created by Arnav Podichetty")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
