import SwiftUI

/// The user's instructions for how Seer should respond, plus facts about them.
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
                Text("When on, the chat and personal questions get the text below. It's sent to the AI provider along with your message.")
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
                    .overlay(alignment: .topLeading) {
                        if settings.profileSummary.isEmpty {
                            // Matches the editor's 5pt line fragment padding so the placeholder sits where typing starts.
                            Text("e.g. Talk casually and keep replies short. Explain math step by step. Show code in Swift.\n\nI'm a third-year CS student interning at a fintech this summer.")
                                .font(.body)
                                .lineSpacing(3)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(!settings.useProfileInAnswers)
                    .opacity(settings.useProfileInAnswers ? 1 : 0.5)
            } header: {
                Text("Instructions and context")
            } footer: {
                HStack {
                    Text("How you want the chat to talk, plus anything it should know about you.")
                    Spacer()
                    Text("\(settings.profileSummary.count) characters")
                        .monospacedDigit()
                    if !settings.profileSummary.isEmpty {
                        Button("Clear", role: .destructive) { confirmClear = true }
                            .buttonStyle(.link)
                            .confirmationDialog("Delete your context?", isPresented: $confirmClear) {
                                Button("Clear", role: .destructive) {
                                    settings.profileSummary = ""
                                    Task { await environment.cache.removeAll(kind: .personal) }
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
