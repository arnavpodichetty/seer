import SwiftUI

struct OverlayActions {
    var toggleMonitoring: () -> Void
    var close: () -> Void
    var setCollapsed: (Bool) -> Void
    var retry: () -> Void
    var reset: () -> Void
    var solveNow: () -> Void
    var sendChat: (String, Bool) -> Void
    var stopChat: () -> Void
    var focusForTyping: () -> Void
    var openSettings: () -> Void
    var openScreenRecordingSettings: () -> Void
}

struct AnswerOverlayView: View {
    let state: AppState
    let settings: AppSettings
    let actions: OverlayActions

    @State private var copied = false

    var body: some View {
        Group {
            if state.isOverlayCollapsed {
                collapsed
            } else {
                expanded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Opacity applies to the background only; text and controls stay fully opaque.
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(settings.overlayOpacity)
        }
        .ignoresSafeArea()
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            Text(collapsedLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { actions.setCollapsed(false) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .hoverHint("Expand")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    private var collapsedLabel: String {
        switch state.phase {
        case .solving: "Solving…"
        case .answer: "Answer ready"
        case .error: "Needs attention"
        case .idle: state.isMonitoring ? "Watching" : "Paused"
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let question = state.question, showsQuestion {
                            QuestionHeader(question: question)
                        }
                        content
                        if !state.chat.isEmpty {
                            ChatTranscript(messages: state.chat)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.chat.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.chat.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            ChatBar(isChatting: state.isChatting, send: actions.sendChat, stop: actions.stopChat, focusForTyping: actions.focusForTyping)
            footer
        }
    }

    private var showsQuestion: Bool {
        switch state.phase {
        case .solving, .answer: true
        case .error: state.errorAction != .openScreenRecordingSettings
        case .idle: false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            Text("Seer")
                .font(.headline)
                .lineLimit(1)
                .hoverHint(state.isMonitoring ? "Watching — \(state.captureStatus)" : "Monitoring paused", alignment: .leading)
            Spacer(minLength: 4)
            Group {
                if case .unreachable = state.ollamaStatus {
                    OllamaWarningButton()
                }
                Button(action: actions.toggleMonitoring) {
                    Image(systemName: state.isMonitoring ? "pause.fill" : "play.fill")
                }
                .hoverHint(state.isMonitoring ? "Pause monitoring" : "Start monitoring")
                Button(action: actions.reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .hoverHint("Reset answer (\(settings.resetShortcut.label))")
                Button(action: copyAnswer) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .hoverHint("Copy answer")
                .disabled(state.parsed.isEmpty)
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape")
                }
                .hoverHint("Settings")
                Button { actions.setCollapsed(true) } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .hoverHint("Collapse")
                Button(action: actions.close) {
                    Image(systemName: "xmark")
                }
                .hoverHint("Close (Esc)")
            }
            .buttonStyle(.borderless)
            .imageScale(.medium)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 36)
        .zIndex(1)   // hover hints draw over the content below
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case let .idle(message):
            IdleView(message: message, state: state, settings: settings, actions: actions)
        case .solving:
            if state.parsed.isEmpty {
                SolvingView(state: state)
            } else {
                AnswerBody(parsed: state.parsed, settings: settings, streaming: true)
            }
        case .answer:
            AnswerBody(parsed: state.parsed, settings: settings, streaming: false)
        case let .error(title, detail, hint):
            ErrorView(title: title, detail: detail, hint: hint, action: state.errorAction, actions: actions)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let model = state.activeModel {
                Label(model, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
            }
            if state.answerFromCache { Text("· cached") }
            if let duration = state.answerDuration { Text("· \(duration, specifier: "%.1f")s") }
            Spacer()
            if let note = state.modelNote {
                Image(systemName: "info.circle").hoverHint(note, edge: .top)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(state.activeModel == nil && state.modelNote == nil ? 0 : 1)
    }

    private func copyAnswer() {
        let parsed = state.parsed
        var text = parsed.answer
        if !parsed.explanation.isEmpty { text += "\n\n" + parsed.explanation }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - Pieces

private struct ChatTranscript: View {
    let messages: [ChatMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            ForEach(messages) { message in
                switch message.role {
                case .user:
                    HStack {
                        Spacer(minLength: 40)
                        HStack(spacing: 4) {
                            if message.attachedScreen { Image(systemName: "camera.fill").font(.caption2) }
                            Text(message.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                case .assistant:
                    VStack(alignment: .leading, spacing: 4) {
                        if message.text.isEmpty && message.isStreaming {
                            ProgressView().controlSize(.small)
                        } else {
                            MarkdownText(text: message.text, font: .callout)
                                .foregroundStyle(message.isError ? .red : .primary)
                        }
                        if let model = message.model {
                            Text(model).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ChatBar: View {
    let isChatting: Bool
    let send: (String, Bool) -> Void
    let stop: () -> Void
    let focusForTyping: () -> Void

    @State private var text = ""
    @State private var includeScreen = false
    @State private var fieldHeight: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { includeScreen.toggle() } label: {
                Image(systemName: includeScreen ? "camera.fill" : "camera")
                    .foregroundStyle(includeScreen ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .hoverHint(includeScreen ? "Screenshot will be attached" : "Attach a screenshot", edge: .top, alignment: .leading)

            // A line-limited field cuts off longer text with no way to scroll back to it, so the
            // field grows inside a scroll view that stops growing at about four lines.
            ScrollView {
                TextField("Ask a follow-up…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    // The overlay never takes keyboard focus on its own; clicking here asks for it.
                    .simultaneousGesture(TapGesture().onEnded {
                        focusForTyping()
                        focused = true
                    })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .frame(height: fieldHeight > 0 ? min(fieldHeight, 76) : nil)

            if isChatting {
                Button(action: stop) { Image(systemName: "stop.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .hoverHint("Stop", edge: .top)
            } else {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .hoverHint("Send (Return) · New line (Shift+Return)", edge: .top)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isChatting else { return }
        send(message, includeScreen)
        text = ""
        includeScreen = false
        focused = true
    }
}

private struct StatusDot: View {
    let state: AppState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .hoverHint(state.captureStatus, alignment: .leading)
    }

    private var color: Color {
        if case .error = state.phase { return .red }
        if case .solving = state.phase { return .orange }
        return state.isMonitoring ? .green : .gray
    }
}

private struct QuestionHeader: View {
    let question: QuestionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(question.kind.displayName, systemImage: question.kind.symbolName)
                if question.mode == .vision {
                    Label("Visual", systemImage: "eye")
                }
                if let app = question.sourceApp {
                    Text("· \(app)")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Text("“\(question.excerpt)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AnswerBody: View {
    let parsed: ParsedAnswer
    let settings: AppSettings
    let streaming: Bool

    private var isShortAnswer: Bool {
        let answer = parsed.answer
        return answer.count <= 90 && !answer.contains("\n") && !answer.contains("```") && !answer.hasPrefix("#")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Answer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let confidence = parsed.confidence {
                    ConfidenceBadge(confidence: confidence)
                }
                if streaming {
                    ProgressView().controlSize(.mini)
                }
            }
            // A one-line answer is shown big; longer answers render as headings + body text.
            MarkdownText(text: parsed.answer.isEmpty ? "…" : parsed.answer,
                         font: isShortAnswer ? .title3.weight(.semibold) : .body)

            if !parsed.explanation.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { settings.explanationExpanded }, set: { settings.explanationExpanded = $0 })) {
                    MarkdownText(text: parsed.explanation, font: .callout)
                        .padding(.top, 4)
                } label: {
                    Text("Explanation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: AnswerConfidence

    var body: some View {
        Text(confidence.rawValue.capitalized + " confidence")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
    }
}

private struct SolvingView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if state.isThinking {
                    Text("\(state.thinkingCharacters) characters of reasoning so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let model = state.activeModel {
                    Text("Running \(model) locally. The first answer may take longer while the model loads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        if state.isThinking { return "Reasoning…" }
        return state.activeModel == nil ? "Preparing…" : "Solving…"
    }
}

private struct IdleView: View {
    let message: String
    let state: AppState
    let settings: AppSettings
    let actions: OverlayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: state.isMonitoring ? "eye" : "eye.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Solve Screen Now (\(settings.solveShortcut.label))", action: actions.solveNow)
                    .buttonStyle(.borderedProminent)
                if !state.isMonitoring {
                    Button("Start Monitoring", action: actions.toggleMonitoring)
                }
            }
            .controlSize(.regular)
            if state.isMonitoring && !state.detectionStatus.isEmpty {
                Text(state.detectionStatus)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Small header icon when Ollama is down; click for the details. It's only the offline
/// fallback, so it stays out of the way.
private struct OllamaWarningButton: View {
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .hoverHint("Ollama isn't running")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ollama isn't running").font(.headline)
                Text("Ollama is only the offline fallback. Answers still come from Groq and Gemini.")
                    .foregroundStyle(.secondary)
                Text("To use it, start the Ollama app or run `ollama serve`.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(12)
        }
    }
}

private struct ErrorView: View {
    let title: String
    let detail: String
    let hint: String?
    let action: ErrorAction?
    let actions: OverlayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text(detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch action {
            case .openScreenRecordingSettings:
                Button("Open System Settings", action: actions.openScreenRecordingSettings)
            case .openAISettings:
                Button("Open AI Settings", action: actions.openSettings)
            case .retry:
                Button("Retry", action: actions.retry)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Hover hints

/// Standard tooltips only appear in the active app, and the overlay never activates Seer,
/// so it shows its own small label after a short hover.
private struct HoverHint: ViewModifier {
    let text: String
    let edge: VerticalEdge
    let alignment: HorizontalAlignment
    @State private var hovering = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        if hovering { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
                    }
                } else {
                    visible = false
                }
            }
            .overlay(alignment: Alignment(horizontal: alignment, vertical: edge == .bottom ? .bottom : .top)) {
                if visible && !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                        .alignmentGuide(edge == .bottom ? .bottom : .top) { d in
                            edge == .bottom ? d[.top] - 6 : d[.bottom] + 6
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(text)
    }
}

private extension View {
    /// A hover label shown below (or above, for `.top`) the view, right-aligned by default
    /// so labels near the window's right edge stay inside it.
    func hoverHint(_ text: String, edge: VerticalEdge = .bottom, alignment: HorizontalAlignment = .trailing) -> some View {
        modifier(HoverHint(text: text, edge: edge, alignment: alignment))
    }
}
