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
                TextEditor(text: $settings.profileSummary)
                    .font(.callout)
                    .frame(minHeight: 260)
                    .overlay(alignment: .topLeading) {
                        if settings.profileSummary.isEmpty {
                            Text("Anything you want the chat to keep in mind: who you are, what you're working on, how you like answers.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!settings.useProfileInAnswers)
                    .opacity(settings.useProfileInAnswers ? 1 : 0.5)
                HStack {
                    Text("\(settings.profileSummary.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(settings.profileSummary.isEmpty)
                        .confirmationDialog("Delete your context?", isPresented: $confirmClear) {
                            Button("Clear", role: .destructive) {
                                settings.profileSummary = ""
                                Task { await environment.cache.removeAll(kind: .interview) }
                            }
                        }
                }
            } header: {
                Text("Context for the chat")
            }
        }
        .formStyle(.grouped)
    }
}
