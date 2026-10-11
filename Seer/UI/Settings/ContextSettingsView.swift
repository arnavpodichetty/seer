import SwiftUI

/// Facts about the user that Seer uses to answer questions about them.
struct ContextSettingsView: View {
    let environment: AppEnvironment
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = environment.settings
        Form {
            Section {
                Toggle("Context", isOn: $settings.useProfileInAnswers)
                    .toggleStyle(.switch)
            } footer: {
                Text("When on, the chat and personal questions get the context below. It's sent to the AI provider along with your message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The editor blends into the section card instead of drawing its own box.
                TextEditor(text: $settings.profileSummary)
                    .font(.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 240)
                    .padding(.vertical, 4)
                    .disabled(!settings.useProfileInAnswers)
                    .opacity(settings.useProfileInAnswers ? 1 : 0.5)
            } header: {
                Text("Context for the chat")
            } footer: {
                HStack {
                    Spacer()
                    Text("\(settings.profileSummary.count) characters")
                        .monospacedDigit()
                    if !settings.profileSummary.isEmpty {
                        Button("Clear", role: .destructive) { confirmClear = true }
                            .buttonStyle(.link)
                            .confirmationDialog("Delete your context?", isPresented: $confirmClear) {
                                Button("Clear", role: .destructive) {
                                    settings.profileSummary = ""
                                    Task { await environment.cache.removeAll(kind: .interview) }
                                }
                            }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
