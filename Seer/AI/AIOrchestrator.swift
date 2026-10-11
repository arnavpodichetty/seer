import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

/// Drives the pipeline: capture → change detection → OCR → question detection →
/// stabilization → dedup/cache → local inference → overlay.
///
/// Runs on the main actor but only coordinates; capture, OCR, image encoding and
/// detection run on actors or detached tasks. The loop is strictly sequential so
/// frames can never pile up, and at most one inference (plus one short
/// classification) is in flight; a new question cancels the old inference.
final class AIOrchestrator {
    let state: AppState
    let settings: AppSettings
    let cache: AnswerCache

    /// Called when the overlay should appear for a new answer.
    var showOverlay: (() -> Void)?

    private let capture = ScreenCaptureManager()
    private let ocr = OCRService()
    private let detector = QuestionDetector()
    private var gate = StabilityGate()

    private var loopTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?

    private var lastSignature: FrameSignature?
    private var lastDetection: DetectionOutcome?
    private var lastOCRText = ""
    private var lastOCRAt: Date?
    private var sameTextStreak = 0
    private var lastOCRWordCount = 0
    /// Picture-only screens: a frame must repeat once before it's checked, and each is checked once.
    private var pendingVisual: FrameSignature?
    private var checkedVisual: [FrameSignature] = []

    private var currentQuestion: DetectedQuestion?
    private var currentImage: CGImage?
    private var dismissed: [QuestionFingerprint] = []
    private var rejected: [QuestionFingerprint] = []
    private var lastModelUsed: String?
    private var solveGeneration = 0
    private var checkedVisionModel: String?

    private var cachedClient: (key: String, client: OllamaClient)?

    init(state: AppState, settings: AppSettings, cache: AnswerCache) {
        self.state = state
        self.settings = settings
        self.cache = cache
    }

    var client: OllamaClient {
        let key = "\(settings.ollamaURL.absoluteString)|\(settings.requestTimeout)"
        if let cachedClient, cachedClient.key == key { return cachedClient.client }
        let client = OllamaClient(baseURL: settings.ollamaURL, idleTimeout: max(30, settings.requestTimeout))
        cachedClient = (key, client)
        return client
    }

    // MARK: - Ollama status

    func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOllamaStatus()
                let delay: Double = self.state.ollamaStatus.isConnected ? 30 : 10
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func refreshOllamaStatus() async {
        let client = self.client
        if case .unknown = state.ollamaStatus { state.ollamaStatus = .checking }
        do {
            async let version = client.version()
            async let models = client.listModels()
            let (v, m) = try await (version, models)
            state.ollamaStatus = .connected(version: v, modelCount: m.count)
            if m != state.installedModels { state.installedModels = m }
            await checkVisionCapability(client: client)
        } catch {
            state.ollamaStatus = .unreachable(error.localizedDescription)
            if !state.installedModels.isEmpty { state.installedModels = [] }
        }
    }

    private func checkVisionCapability(client: OllamaClient) async {
        guard let model = ModelRouter.resolve(settings.visionModel, in: state.installedModelNames) else {
            state.visionModelCapable = nil
            checkedVisionModel = nil
            return
        }
        guard checkedVisionModel != model else { return }
        checkedVisionModel = model
        if let caps = try? await client.capabilities(of: model) {
            state.visionModelCapable = caps.contains("vision")
        } else {
            state.visionModelCapable = state.installedModels.first { ModelRouter.canonical($0.name) == ModelRouter.canonical(model) }?.looksVisionCapable
        }
    }

    // MARK: - Monitoring

    func setMonitoring(_ enabled: Bool) {
        enabled ? startMonitoring() : stopMonitoring()
    }

    func startMonitoring() {
        guard loopTask == nil else { return }
        state.screenPermissionGranted = PermissionsManager.hasScreenRecordingAccess
        if !state.screenPermissionGranted {
            PermissionsManager.requestScreenRecordingAccess()
            state.screenPermissionGranted = PermissionsManager.hasScreenRecordingAccess
        }
        guard state.screenPermissionGranted else {
            showPermissionError(reveal: true)   // direct response to the user's click
            return
        }
        state.isMonitoring = true
        state.captureStatus = "Starting…"
        if case .idle = state.phase { state.phase = .idle("Watching for questions…") }
        if case .error = state.phase, state.errorAction == .openScreenRecordingSettings {
            state.phase = .idle("Watching for questions…")
            state.errorAction = nil
        }
        Task { [weak self] in await self?.preloadModels() }
        loopTask = Task { [weak self] in
            await self?.ocr.warmUp()
            await self?.runLoop()
        }
    }

    func stopMonitoring() {
        loopTask?.cancel()
        loopTask = nil
        state.isMonitoring = false
        state.captureStatus = "Monitoring paused"
        state.detectionStatus = ""
        gate.reset()
        lastSignature = nil
        lastDetection = nil
        if case .idle = state.phase { state.phase = .idle("Monitoring paused.") }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let delay = await tick()
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
        }
    }

    private func tick() async -> TimeInterval {
        let interval = max(0.5, settings.captureInterval)
        let request = makeCaptureRequest()

        let outcome: CaptureOutcome
        do {
            outcome = try await capture.capture(request)
        } catch CaptureError.permissionDenied {
            state.screenPermissionGranted = false
            stopMonitoring()
            showPermissionError(reveal: settings.showOverlayForNewAnswers)
            return interval
        } catch {
            state.captureStatus = error.localizedDescription
            Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            return interval * 2
        }
        guard !Task.isCancelled else { return interval }
        state.lastCaptureAt = Date()

        switch outcome {
        case let .skipped(reason):
            state.captureStatus = reason
            lastSignature = nil
            lastDetection = nil
            gate.reset()
            return interval

        case let .frame(frame):
            state.captureStatus = "Watching \(frame.appName ?? "screen")"
            state.lastCaptureApp = frame.appName
            let change = frame.signature.map { ScreenChangeDetector.compare(lastSignature, $0) } ?? .major
            lastSignature = frame.signature

            let detection: DetectionOutcome
            if let previous = lastDetection, shouldReuseDetection(for: change) {
                detection = previous
            } else {
                do {
                    let result = try await ocr.recognize(frame.image, signature: frame.signature)
                    let text = result.fullText
                    sameTextStreak = text == lastOCRText ? sameTextStreak + 1 : 0
                    lastOCRText = text
                    lastOCRWordCount = QuestionDetector.wordTokens(text)
                    lastOCRAt = Date()
                    let detector = self.detector
                    detection = await Task.detached(priority: .utility) { detector.detect(result) }.value
                } catch {
                    state.detectionStatus = error.localizedDescription
                    return interval
                }
                lastDetection = detection
            }
            guard !Task.isCancelled else { return interval }
            return await handle(detection, frame: frame, interval: interval)
        }
    }

    /// Skip OCR for identical frames, and for small repeated changes (animations,
    /// blinking carets) once OCR has shown the text isn't changing.
    private func shouldReuseDetection(for change: ChangeLevel) -> Bool {
        switch change {
        case .none: return true
        case .minor: return sameTextStreak >= 2 && (lastOCRAt.map { Date().timeIntervalSince($0) < 8 } ?? false)
        case .major: return false
        }
    }

    private func handle(_ detection: DetectionOutcome, frame: CapturedFrame, interval: TimeInterval) async -> TimeInterval {
        guard let question = detection.question else {
            _ = gate.observe(nil, at: Date())
            if case let .none(reason) = detection { state.detectionStatus = reason }
            if lastOCRWordCount < 15 { await checkForVisualQuestion(frame) }
            return interval
        }
        if rejected.contains(where: { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }) {
            gate.reset()
            state.detectionStatus = "No question detected"
            return interval
        }
        let stable = gate.observe(question.fingerprint, at: Date())
        if !stable { preconnect() }   // open the connection while the screen settles
        if let current = currentQuestion, QuestionFingerprintService.isSameQuestion(current.fingerprint, question.fingerprint) {
            state.detectionStatus = "Showing answer for the current question"
            return interval
        }
        guard stable else {
            state.detectionStatus = "Question found — waiting for the screen to settle"
            return min(interval, gate.settleInterval)
        }
        await adopt(question, image: frame.image, appName: frame.appName)
        return interval
    }

    /// Screens with (almost) no text may still hold a problem as a picture. Once a frame is
    /// stable, Gemini looks at it once and either solves it or replies NO_QUESTION.
    private func checkForVisualQuestion(_ frame: CapturedFrame) async {
        guard settings.aiProvider != .ollama, settings.geminiAPIKey != nil || settings.groqAPIKey != nil,
              let signature = frame.signature else { return }
        guard let pending = pendingVisual, ScreenChangeDetector.compare(pending, signature) == .none else {
            pendingVisual = signature   // wait for the same picture on the next frame
            preconnect()
            return
        }
        guard !checkedVisual.contains(where: { ScreenChangeDetector.compare($0, signature) == .none }),
              Self.hasVisualContent(signature) else { return }
        checkedVisual.append(signature)
        if checkedVisual.count > 30 { checkedVisual.removeFirst() }

        // One call: the model solves the picture, or replies NO_QUESTION (handled in finish).
        state.detectionStatus = "Looking at the image…"
        var question = DetectedQuestion.visual(ocrText: lastOCRText, signature: signature)
        question.needsConfirmation = true
        guard !rejected.contains(where: { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }) else { return }
        await adopt(question, image: frame.image, appName: frame.appName)
    }

    /// Skips blank or nearly uniform frames (empty windows, solid backgrounds).
    nonisolated static func hasVisualContent(_ signature: FrameSignature) -> Bool {
        let pixels = signature.thumbnail.map(Double.init)
        guard !pixels.isEmpty else { return false }
        let mean = pixels.reduce(0, +) / Double(pixels.count)
        let variance = pixels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(pixels.count)
        return variance.squareRoot() > 12
    }

    private func adopt(_ question: DetectedQuestion, image: CGImage, appName: String?) async {
        if question.isAmbiguous {
            guard settings.useAIClassification else {
                state.detectionStatus = "Possible question ignored (AI check is off)"
                remember(question.fingerprint, in: &rejected)
                return
            }
            state.detectionStatus = "Checking whether this is a question…"
            let verdict = await classify(question)
            guard !Task.isCancelled else { return }
            // Only a clear YES counts; unclear or failed checks are ignored rather than answered.
            if verdict != true {
                remember(question.fingerprint, in: &rejected)
                state.detectionStatus = "No question detected"
                return
            }
        }

        Log.detection.info("New question (\(question.kind.rawValue, privacy: .public), score \(question.score))")
        currentQuestion = question
        currentImage = question.mode == .vision ? image : nil
        state.question = QuestionSummary(excerpt: question.excerpt, kind: question.kind, mode: question.mode, sourceApp: appName)
        state.detectionStatus = "New question detected"
        cancelInference()

        if dismissed.contains(where: { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }) {
            state.resetAnswer()
            state.phase = .idle("This question was dismissed.")
            return
        }
        if let cached = await cache.lookup(question.fingerprint) {
            present(cached)
            return
        }
        startSolving(question, image: currentImage)
    }

    // MARK: - Inference

    private func cancelInference() {
        inferenceTask?.cancel()
        inferenceTask = nil
        solveGeneration += 1
    }

    private func startSolving(_ question: DetectedQuestion, image: CGImage?) {
        cancelInference()
        let generation = solveGeneration
        inferenceTask = Task { [weak self] in
            await self?.solve(question, image: image, generation: generation)
        }
    }

    func retryCurrentQuestion() {
        guard let question = currentQuestion else { return }
        dismissed.removeAll { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }
        startSolving(question, image: currentImage)
    }

    /// Clears the current question and answer and forgets what was seen, so whatever is
    /// on screen is detected again from scratch and answered fresh (its cached answer is dropped).
    func resetConversation() {
        manualTask?.cancel()
        manualTask = nil
        if let question = currentQuestion {
            let fingerprint = question.fingerprint
            Task { await cache.remove(matching: fingerprint) }
        }
        cancelInference()
        currentQuestion = nil
        currentImage = nil
        dismissed.removeAll()
        rejected.removeAll()
        gate.reset()
        lastDetection = nil
        lastSignature = nil
        state.resetAnswer()
        state.question = nil
        state.activeModel = nil
        state.detectionStatus = ""
        state.phase = .idle(state.isMonitoring ? "Watching for questions…" : "Monitoring paused.")
        chatTask?.cancel()
        chatTask = nil
        state.chat.removeAll()
        state.isChatting = false
    }

    // MARK: - Chat

    func sendChat(_ text: String, includeScreen: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        chatTask?.cancel()
        finishStreamingChat()
        let history = state.chat.filter { !$0.isError && !$0.text.isEmpty }
            .map { PromptBuilder.ChatTurn(fromUser: $0.role == .user, text: $0.text) }
        state.chat.append(ChatMessage(role: .user, text: message, attachedScreen: includeScreen))
        let reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
        state.chat.append(reply)
        state.isChatting = true
        showOverlay?()
        chatTask = Task { [weak self] in
            await self?.runChat(message, history: history, includeScreen: includeScreen, replyID: reply.id)
        }
    }

    func stopChat() {
        chatTask?.cancel()
        chatTask = nil
        finishStreamingChat()
    }

    private func finishStreamingChat() {
        for index in state.chat.indices where state.chat[index].isStreaming {
            state.chat[index].isStreaming = false
            if state.chat[index].text.isEmpty { state.chat[index].text = "_Stopped._" }
        }
        state.isChatting = false
    }

    private func updateReply(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = state.chat.firstIndex(where: { $0.id == id }) else { return }
        change(&state.chat[index])
    }

    private func runChat(_ message: String, history: [PromptBuilder.ChatTurn], includeScreen: Bool, replyID: UUID) async {
        var images: [String] = []
        if includeScreen {
            if case let .frame(frame)? = try? await capture.capture(makeCaptureRequest()),
               let encoded = await encodedImage(frame.image, region: .zero, maxDimension: 1536) {
                images = [encoded]
            }
        } else if let image = currentImage, let question = currentQuestion,
                  let encoded = await encodedImage(image, region: question.region, maxDimension: settings.visionMaxDimension) {
            images = [encoded]
        }
        guard !Task.isCancelled else { return }
        let prompt = PromptBuilder.chatPrompt(message: message, question: currentQuestion, answer: state.parsed.isEmpty ? "" : state.rawResponse,
                                              history: history, profile: settings.activeProfile, attachingScreen: !images.isEmpty)
        // Like answers, stream into the overlay at most ~12 times a second.
        var latest = ""
        var lastUpdate = Date.distantPast
        do {
            let model = try await complete(system: PromptBuilder.chatSystemPrompt, prompt: prompt, images: images,
                                           maxTokens: max(settings.maxResponseTokens, 1024),
                                           webSearch: canSearch && PromptBuilder.wantsWebSearch(chatMessage: message),
                                           preferGemini: currentQuestion.map(prefersGemini) ?? false) { [weak self] text in
                latest = text
                guard text.isEmpty || Date().timeIntervalSince(lastUpdate) > 0.08 else { return }
                lastUpdate = Date()
                self?.updateReply(replyID) { $0.text = text }
            }
            guard !Task.isCancelled else { return }
            updateReply(replyID) { $0.text = latest; $0.model = model; $0.isStreaming = false }
        } catch is CancellationError {
            return
        } catch {
            updateReply(replyID) {
                $0.text = "⚠️ \(error.localizedDescription)"
                $0.isError = true
                $0.isStreaming = false
            }
        }
        state.isChatting = false
    }

    /// Streams a free-form completion through the same chain as answers (Gemini models,
    /// then Ollama), calling `onText` with the accumulated text. Returns the model used.
    private func complete(system: String, prompt: String, images: [String], maxTokens: Int, webSearch: Bool = false,
                          preferGemini: Bool = false, onText: @escaping (String) -> Void) async throws -> String {
        let key = settings.geminiAPIKey
        let backends = currentBackends(withImage: !images.isEmpty, preferGemini: webSearch || preferGemini)
        var lastError: Error = OllamaError.emptyResponse
        for backend in backends {
            try Task.checkCancellation()
            do {
                switch backend {
                case let .gemini(model):
                    var thinking: String? = "low"
                    var search = webSearch
                    for _ in 0..<3 {
                        do {
                            var raw = ""
                            for try await event in gemini(key ?? "").stream(.init(model: model, system: system, text: prompt, imagesBase64JPEG: images,
                                                                                    maxOutputTokens: maxTokens + 2048, temperature: 0.4, thinkingLevel: thinking,
                                                                                    webSearch: search)) {
                                try Task.checkCancellation()
                                if case let .text(text) = event { raw += text; onText(raw) }
                            }
                            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudAIError.emptyResponse }
                            return model
                        } catch let CloudAIError.http(status, message) where status == 400 && thinking != nil && message.lowercased().contains("thinking") {
                            thinking = nil
                        } catch let CloudAIError.http(status, _) where status == 400 && search {
                            search = false
                        } catch let CloudAIError.rateLimited(message) where search {
                            search = false
                            noteSearchUnavailable(message)
                        }
                    }
                    throw CloudAIError.emptyResponse
                case let .groq(model):
                    let attach = AppSettings.groqVisionModelChoices.contains(model) ? images : []
                    return try await streamOpenAICompatible(groq(settings.groqAPIKey ?? ""), model: model, system: system, prompt: prompt,
                                                            images: attach, maxTokens: Self.groqTokenBudget(maxTokens), effort: "low", onText: onText)
                case let .custom(model):
                    guard let client = custom() else { throw CloudAIError.missingKey }
                    return try await streamOpenAICompatible(client, model: model, system: system, prompt: prompt,
                                                            images: images, maxTokens: maxTokens + 1024, effort: nil, onText: onText)
                case .ollama:
                    if state.installedModels.isEmpty || !state.ollamaStatus.isConnected { await refreshOllamaStatus() }
                    guard state.ollamaStatus.isConnected else { throw OllamaError.notRunning(settings.ollamaAddress) }
                    guard case let .success(choice) = ModelRouter.choose(mode: images.isEmpty ? .text : .vision, strategy: settings.modelStrategy,
                                                                         textModel: settings.textModel, visionModel: settings.visionModel,
                                                                         installed: state.installedModelNames)
                    else { throw OllamaError.modelNotFound(settings.textModel) }
                    let messages = [OllamaMessage(role: "system", content: system),
                                    OllamaMessage(role: "user", content: prompt, images: choice.attachImage && !images.isEmpty ? images : nil)]
                    var think: Bool? = false
                    for _ in 0..<2 {
                        do {
                            var raw = ""
                            let request = OllamaChatRequest(model: choice.model, messages: messages, think: think, keep_alive: OllamaDefaults.keepAlive,
                                                            options: .init(num_predict: maxTokens, temperature: 0.4, num_ctx: OllamaDefaults.contextLength))
                            for try await chunk in client.chat(request) {
                                try Task.checkCancellation()
                                if let content = chunk.message?.content, !content.isEmpty { raw += content; onText(AnswerParser.stripThinking(raw)) }
                            }
                            guard !AnswerParser.stripThinking(raw).isEmpty else { throw OllamaError.emptyResponse }
                            return choice.model
                        } catch let OllamaError.server(_, message) where think != nil && message.lowercased().contains("think") {
                            think = nil
                        }
                    }
                    throw OllamaError.emptyResponse
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                noteFailure(backend, error)
                lastError = error
                onText("")
            }
        }
        throw lastError
    }

    /// Free-form streaming through an OpenAI-compatible API; returns the model used.
    private func streamOpenAICompatible(_ client: GroqClient, model: String, system: String, prompt: String, images: [String],
                                        maxTokens: Int, effort initialEffort: String?, onText: @escaping (String) -> Void) async throws -> String {
        var effort = initialEffort
        for _ in 0..<2 {
            do {
                var raw = ""
                for try await event in client.stream(.init(model: model, system: system, text: prompt, imagesBase64JPEG: images,
                                                           maxTokens: maxTokens, temperature: 0.4, reasoningEffort: effort)) {
                    try Task.checkCancellation()
                    if case let .text(text) = event { raw += text; onText(raw) }
                }
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudAIError.emptyResponse }
                return model
            } catch let CloudAIError.http(status, message) where status == 400 && effort != nil && message.lowercased().contains("reasoning") {
                effort = nil
            }
        }
        throw CloudAIError.emptyResponse
    }

    /// Manual trigger: capture now and answer the best candidate on screen, skipping the
    /// stability wait and AI check. With no candidate, the model gets the whole screen.
    func solveNow() {
        manualTask?.cancel()
        manualTask = Task { [weak self] in await self?.runSolveNow() }
    }

    private func runSolveNow() async {
        preconnect()   // overlaps the TLS handshake with capture and OCR
        state.screenPermissionGranted = PermissionsManager.hasScreenRecordingAccess
        guard state.screenPermissionGranted else {
            PermissionsManager.requestScreenRecordingAccess()
            showPermissionError(reveal: true)
            return
        }
        cancelInference()
        state.resetAnswer()
        state.question = nil
        state.activeModel = nil
        state.phase = .solving
        state.answerStartedAt = Date()
        showOverlay?()

        let frame: CapturedFrame
        do {
            switch try await capture.capture(makeCaptureRequest()) {
            case let .frame(captured): frame = captured
            case let .skipped(reason):
                state.phase = .error(title: "Can't read the screen right now", detail: reason, hint: nil)
                state.errorAction = nil
                return
            }
        } catch {
            fail(error)
            return
        }
        let result: OCRResult
        do {
            result = try await ocr.recognize(frame.image, signature: frame.signature)
        } catch {
            fail(error)
            return
        }
        guard !Task.isCancelled else { return }

        let detector = self.detector
        let detection = await Task.detached(priority: .userInitiated) { detector.detect(result, forced: true) }.value
        var question: DetectedQuestion
        if var found = detection.question {
            found.isAmbiguous = false
            question = found
        } else {
            // No text question (or no text at all): the model reads the screenshot itself.
            question = .visual(ocrText: result.fullText, signature: frame.signature)
        }

        // Keep the monitoring loop from treating this as a new question.
        lastDetection = detection
        lastSignature = frame.signature
        gate.reset()
        rejected.removeAll { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }
        dismissed.removeAll { QuestionFingerprintService.isSameQuestion($0, question.fingerprint) }

        currentQuestion = question
        currentImage = question.mode == .vision ? frame.image : nil
        state.question = QuestionSummary(excerpt: question.findInScreen && !question.text.isEmpty ? "Whole screen" : question.excerpt,
                                         kind: question.kind, mode: question.mode, sourceApp: frame.appName)
        if let cached = await cache.lookup(question.fingerprint) {
            present(cached)
            showOverlay?()
            return
        }
        startSolving(question, image: currentImage)
    }

    func dismissCurrentQuestion() {
        if let question = currentQuestion { remember(question.fingerprint, in: &dismissed) }
        cancelInference()
        if case .solving = state.phase { state.phase = .idle("Dismissed.") }
    }

    /// Where an answer can come from, in the order tried.
    enum Backend: Equatable {
        /// The user's own OpenAI-compatible provider.
        case custom(String)
        case gemini(String)
        case groq(String)
        case ollama

        var cloudModel: String? {
            switch self {
            case let .custom(model), let .gemini(model), let .groq(model): model
            case .ollama: nil
            }
        }

        /// Cooldowns are per backend, so a custom model sharing a name with a Groq one isn't benched with it.
        var cooldownKey: String? {
            switch self {
            case let .custom(model): "custom:" + model
            case let .gemini(model), let .groq(model): model
            case .ollama: nil
            }
        }
    }

    /// Gemini primary → Gemini fallback → local Ollama (or Ollama alone).
    /// The order answers are tried in. Image questions try Gemini's vision model first;
    /// `groqModel` is nil when there's no Groq key.
    /// The user's custom model, when set, goes first (except in Ollama-only mode, which stays local).
    nonisolated static func backends(provider: AIProvider, hasGeminiKey: Bool, primary: String, fallback: String,
                                     vision: String? = nil, groqModel: String? = nil, customModel: String? = nil) -> [Backend] {
        guard provider != .ollama else { return [.ollama] }
        let custom: [Backend] = customModel.map { $0.isEmpty ? [] : [.custom($0)] } ?? []
        var gemini: [Backend] = []
        if hasGeminiKey {
            for model in [vision ?? "", primary, fallback] where !model.isEmpty && !gemini.contains(.gemini(model)) {
                gemini.append(.gemini(model))
            }
        }
        let groq: [Backend] = groqModel.map { $0.isEmpty ? [] : [.groq($0)] } ?? []
        return custom + (provider == .groq ? groq + gemini : gemini + groq) + [.ollama]
    }

    /// Interview and questionnaire answers built from the user's context go to Gemini first: in testing it kept to the
    /// facts given, while gpt-oss on Groq invented conflicts, targets and incidents. A long context
    /// also overruns Groq's free 8k tokens-per-minute limit after one answer.
    private func prefersGemini(_ question: DetectedQuestion) -> Bool {
        (question.kind == .interview || PromptBuilder.isSelfAssessment(question))
            && settings.activeProfile != nil && settings.geminiAPIKey != nil
    }

    /// Web search runs through Gemini's Google Search tool, so it needs a Gemini key.
    private var canSearch: Bool {
        settings.useWebSearch && settings.geminiAPIKey != nil && settings.aiProvider != .ollama
            && (searchUnavailableUntil.map { $0 <= Date() } ?? true)
    }

    /// Free-tier Gemini keys have no search quota: every search request fails with a quota
    /// error while plain requests work. After one such failure, stop offering search for a while.
    private var searchUnavailableUntil: Date?
    private static let searchUnavailableNote = "Web search isn't available on this Gemini key (it needs billing turned on)"

    /// Returns true when the error means the key has no search quota (not a brief per-minute limit).
    @discardableResult
    private func noteSearchUnavailable(_ message: String) -> Bool {
        guard !message.lowercased().contains("per minute") else { return false }
        searchUnavailableUntil = Date().addingTimeInterval(6 * 60 * 60)
        return true
    }

    /// Chain for the current settings, skipping cloud models that are cooling down. With
    /// `preferGemini`, Gemini goes first (it's the only provider here that can search).
    private func currentBackends(withImage: Bool, preferGemini: Bool) -> [Backend] {
        let chain = currentBackends(withImage: withImage)
        guard preferGemini else { return chain }
        let isGemini: (Backend) -> Bool = { if case .gemini = $0 { true } else { false } }
        return chain.filter(isGemini) + chain.filter { !isGemini($0) }
    }

    /// Chain for the current settings, skipping cloud models that are cooling down.
    private func currentBackends(withImage: Bool) -> [Backend] {
        let now = Date()
        let groqModel = settings.groqAPIKey == nil ? nil : (withImage ? settings.groqVisionModel : settings.groqModel)
        let customModel = withImage && !settings.customSendsImages ? nil : settings.activeCustomModel
        return Self.backends(provider: settings.aiProvider, hasGeminiKey: settings.geminiAPIKey != nil,
                             primary: settings.geminiModel, fallback: settings.geminiFallbackModel,
                             vision: withImage ? settings.geminiVisionModel : nil, groqModel: groqModel, customModel: customModel)
            .filter { backend in
                guard let key = backend.cooldownKey, let until = geminiCooldown[key] else { return true }
                return until <= now
            }
    }

    /// Benches a cloud model after overload (briefly) or a rate limit (longer; free tiers are per day).
    private func noteFailure(_ backend: Backend, _ error: Error) {
        guard let model = backend.cooldownKey, let cloudError = error as? CloudAIError else { return }
        switch cloudError {
        case .overloaded: geminiCooldown[model] = Date().addingTimeInterval(60)
        case let .rateLimited(message):
            // Per-minute token limits (Groq) clear quickly; daily quotas (Gemini free tier) don't.
            let perMinute = message.lowercased().contains("per minute") || message.lowercased().contains("request too large")
            geminiCooldown[model] = Date().addingTimeInterval(perMinute ? 60 : 15 * 60)
        default: break
        }
    }

    /// Groq's free tier counts the requested reply length against 8,000 tokens per minute,
    /// so keep requests modest.
    nonisolated static func groqTokenBudget(_ budget: Int) -> Int { min(budget + 512, 2048) }

    private var cachedCustom: GroqClient?

    /// Client for the user's custom provider (nil if its URL is invalid).
    private func custom() -> GroqClient? {
        guard let endpoint = settings.customEndpoint, let key = settings.customAPIKey else { return nil }
        if let cachedCustom, cachedCustom.apiKey == key, cachedCustom.endpoint == endpoint { return cachedCustom }
        let client = GroqClient(apiKey: key, endpoint: endpoint)
        cachedCustom = client
        return client
    }

    private var cachedGroq: GroqClient?

    private func groq(_ key: String) -> GroqClient {
        if let cachedGroq, cachedGroq.apiKey == key { return cachedGroq }
        let client = GroqClient(apiKey: key)
        cachedGroq = client
        return client
    }

    private struct SolveOutcome {
        var raw: String
        var model: String
        var mode: ReasoningMode
        var truncated: Bool
        var note: String?
    }

    private var lastPreconnect = Date.distantPast

    /// Opens a connection to the first cloud provider ahead of a request, so the answer
    /// doesn't wait on DNS and the TLS handshake.
    private func preconnect() {
        guard settings.aiProvider != .ollama, Date().timeIntervalSince(lastPreconnect) > 20 else { return }
        lastPreconnect = Date()
        switch currentBackends(withImage: false).first {
        case .custom?: custom()?.preconnect()
        case .groq?: groq(settings.groqAPIKey ?? "").preconnect()
        case .gemini?: gemini(settings.geminiAPIKey ?? "").preconnect()
        default: break
        }
    }

    private var cachedGemini: GeminiClient?
    /// Gemini models that just reported overload/rate limits are skipped until this time.
    private var geminiCooldown: [String: Date] = [:]

    private func gemini(_ key: String) -> GeminiClient {
        if let cachedGemini, cachedGemini.apiKey == key { return cachedGemini }
        let client = GeminiClient(apiKey: key)
        cachedGemini = client
        return client
    }

    private func solve(_ question: DetectedQuestion, image: CGImage?, generation: Int) async {
        state.resetAnswer()
        state.phase = .solving
        state.activeModel = nil
        state.answerStartedAt = Date()
        if settings.showOverlayForNewAnswers { showOverlay?() }

        let system = PromptBuilder.systemPrompt(detail: settings.detailLevel, kind: question.kind)
        // Leave room for a requested speaking length ("in 2 minutes…") plus the tips.
        let spokenWords = question.kind == .interview ? PromptBuilder.spokenWordTarget(question.text) ?? 0 : 0
        let budget = max(settings.maxResponseTokens, spokenWords * 2 + 300)
        let key = settings.geminiAPIKey
        let search = canSearch && PromptBuilder.wantsWebSearch(question)
        let backends = currentBackends(withImage: question.mode == .vision && image != nil,
                                       preferGemini: search || prefersGemini(question))

        var failures: [String] = []
        var lastError: Error?
        for backend in backends {
            guard generation == solveGeneration, !Task.isCancelled else { return }
            do {
                let outcome: SolveOutcome
                switch backend {
                case let .gemini(model):
                    outcome = try await solveWithGemini(question, image: image, model: model, key: key ?? "",
                                                        system: system, budget: budget, webSearch: search, generation: generation)
                case let .groq(model):
                    outcome = try await solveWithGroq(question, image: image, model: model, key: settings.groqAPIKey ?? "",
                                                      system: system, budget: budget, generation: generation)
                case let .custom(model):
                    guard let client = custom() else { throw CloudAIError.missingKey }
                    // Paid provider: no free-tier token cap, and its own reasoning defaults.
                    outcome = try await solveOpenAICompatible(question, image: image, model: model, client: client, system: system,
                                                              attachImages: true, maxTokens: budget + 1024, effort: nil, generation: generation)
                case .ollama:
                    outcome = try await solveWithOllama(question, image: image, system: system, budget: budget, generation: generation)
                }
                guard generation == solveGeneration else { return }
                await finish(outcome, question: question, failures: failures)
                return
            } catch is CancellationError {
                return
            } catch {
                guard generation == solveGeneration else { return }
                let name = backend.cloudModel ?? "Ollama"
                noteFailure(backend, error)
                let reason = (error as? CloudAIError)?.shortReason ?? error.localizedDescription
                Log.ai.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failures.append("\(name): \(reason)")
                lastError = error
                state.rawResponse = ""
                state.parsed = .empty
                state.isThinking = false
            }
        }
        guard let lastError else { return }
        fail(lastError)
        if failures.count > 1, case let .error(title, detail, hint) = state.phase {
            state.phase = .error(title: title, detail: detail + "\n\nAlso tried: " + failures.dropLast().joined(separator: "; "), hint: hint)
        }
    }

    private func finish(_ outcome: SolveOutcome, question: DetectedQuestion, failures: [String]) async {
        // A picture checked automatically turned out not to contain a question.
        if question.needsConfirmation, outcome.raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(PromptBuilder.noQuestionToken) {
            remember(question.fingerprint, in: &rejected)
            if let current = currentQuestion, current.fingerprint == question.fingerprint { currentQuestion = nil }
            state.resetAnswer()
            state.question = nil
            state.activeModel = nil
            state.phase = .idle(state.isMonitoring ? "Watching for questions…" : "Monitoring paused.")
            state.detectionStatus = "No question detected"
            return
        }
        let parsed = AnswerParser.parse(outcome.raw)
        state.rawResponse = outcome.raw
        state.parsed = parsed
        state.isThinking = false
        state.activeModel = outcome.model
        let duration = Date().timeIntervalSince(state.answerStartedAt ?? Date())
        state.answerDuration = duration
        state.phase = .answer
        var notes: [String] = []
        if !failures.isEmpty { notes.append("Fallback used (\(failures.joined(separator: "; ")))") }
        if let note = outcome.note { notes.append(note) }
        if outcome.truncated { notes.append("Answer may be truncated (max response length reached)") }
        state.modelNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
        await cache.store(AnswerRecord(
            fingerprint: question.fingerprint, questionExcerpt: question.excerpt, kind: question.kind,
            mode: outcome.mode, model: outcome.model, parsed: parsed, raw: outcome.raw,
            createdAt: Date(), duration: duration
        ))
    }

    /// Streams text into the overlay, throttled to ~12 updates per second.
    private func show(_ raw: String, lastUpdate: inout Date) {
        guard Date().timeIntervalSince(lastUpdate) > 0.08 else { return }
        if PromptBuilder.noQuestionToken.hasPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(11)) { return }
        state.rawResponse = raw
        state.parsed = AnswerParser.parse(raw)
        lastUpdate = Date()
    }

    private func encodedImage(_ image: CGImage, region: CGRect, maxDimension: Int) async -> String? {
        let crop = Self.visionCrop(for: region)
        return await Task.detached(priority: .userInitiated) {
            let focused = crop.flatMap { ImageUtilities.crop(image, normalized: $0) } ?? image
            return ImageUtilities.jpegData(ImageUtilities.downsample(focused, maxDimension: maxDimension))?.base64EncodedString()
        }.value
    }

    private func solveWithGemini(_ question: DetectedQuestion, image: CGImage?, model: String, key: String,
                                 system: String, budget: Int, webSearch: Bool, generation: Int) async throws -> SolveOutcome {
        state.activeModel = model
        var images: [String] = []
        if question.mode == .vision, let image,
           let encoded = await encodedImage(image, region: question.region, maxDimension: settings.visionMaxDimension) {
            images = [encoded]
        }
        var thinking: String? = PromptBuilder.geminiThinkingLevel(kind: question.kind, preference: settings.speedPreference)
        var webSearch = webSearch
        var searchNote: String?
        for _ in 0..<3 {
            let request = GeminiClient.Request(
                model: model, system: system,
                text: PromptBuilder.userPrompt(for: question, attachingImage: !images.isEmpty, profile: settings.activeProfile, webSearch: webSearch),
                imagesBase64JPEG: images, maxOutputTokens: budget + 2048, temperature: 0.3, thinkingLevel: thinking, webSearch: webSearch)
            do {
                var raw = ""
                var status: String?
                var searched = false
                var lastUpdate = Date.distantPast
                for try await event in gemini(key).stream(request) {
                    guard generation == solveGeneration, !Task.isCancelled else { throw CancellationError() }
                    switch event {
                    case .thinking:
                        state.isThinking = true
                    case .searching:
                        searched = true
                        state.isThinking = true
                    case let .text(text):
                        raw += text
                        state.isThinking = false
                        show(raw, lastUpdate: &lastUpdate)
                    case let .completed(s):
                        status = s
                    }
                }
                guard !AnswerParser.parse(raw).isEmpty else { throw CloudAIError.emptyResponse }
                return SolveOutcome(raw: raw, model: model, mode: images.isEmpty ? .text : .vision,
                                    truncated: status == "incomplete", note: searched ? "Searched the web" : searchNote)
            } catch let CloudAIError.http(status, message) where status == 400 && thinking != nil && message.lowercased().contains("thinking") {
                thinking = nil   // this model doesn't accept the thinking level; use its default
            } catch let CloudAIError.http(status, _) where status == 400 && webSearch {
                webSearch = false   // search isn't available for this model or key; answer without it
                searchNote = Self.searchUnavailableNote
            } catch let CloudAIError.rateLimited(message) where webSearch {
                webSearch = false   // retry right away without search
                if noteSearchUnavailable(message) { searchNote = Self.searchUnavailableNote }
            }
        }
        throw CloudAIError.emptyResponse
    }

    private func solveWithGroq(_ question: DetectedQuestion, image: CGImage?, model: String, key: String,
                               system: String, budget: Int, generation: Int) async throws -> SolveOutcome {
        try await solveOpenAICompatible(question, image: image, model: model, client: groq(key), system: system,
                                        attachImages: AppSettings.groqVisionModelChoices.contains(model),
                                        imageDimension: 1024,   // Groq's free per-minute token limit is tight
                                        maxTokens: Self.groqTokenBudget(budget),
                                        effort: PromptBuilder.geminiThinkingLevel(kind: question.kind, preference: settings.speedPreference),
                                        generation: generation)
    }

    /// Streams an answer from an OpenAI-compatible API (Groq or the custom provider).
    private func solveOpenAICompatible(_ question: DetectedQuestion, image: CGImage?, model: String, client: GroqClient,
                                       system: String, attachImages: Bool, imageDimension: Int? = nil, maxTokens: Int,
                                       effort initialEffort: String?, generation: Int) async throws -> SolveOutcome {
        state.activeModel = model
        var images: [String] = []
        if question.mode == .vision, let image, attachImages,
           let encoded = await encodedImage(image, region: question.region, maxDimension: imageDimension ?? settings.visionMaxDimension) {
            images = [encoded]
        }
        var effort = initialEffort
        for _ in 0..<2 {
            let request = GroqClient.Request(
                model: model, system: system,
                text: PromptBuilder.userPrompt(for: question, attachingImage: !images.isEmpty, profile: settings.activeProfile),
                imagesBase64JPEG: images, maxTokens: maxTokens,
                temperature: question.kind == .interview ? 0.2 : 0.3, reasoningEffort: effort)
            do {
                var raw = ""
                var finish: String?
                var lastUpdate = Date.distantPast
                for try await event in client.stream(request) {
                    guard generation == solveGeneration, !Task.isCancelled else { throw CancellationError() }
                    switch event {
                    case let .text(text):
                        raw += text
                        show(raw, lastUpdate: &lastUpdate)
                    case let .finished(reason):
                        finish = reason
                    }
                }
                guard !AnswerParser.parse(raw).isEmpty else { throw CloudAIError.emptyResponse }
                return SolveOutcome(raw: raw, model: model, mode: images.isEmpty ? .text : .vision,
                                    truncated: finish == "length", note: nil)
            } catch let CloudAIError.http(status, message) where status == 400 && effort != nil && message.lowercased().contains("reasoning") {
                effort = nil   // model without reasoning controls
            }
        }
        throw CloudAIError.emptyResponse
    }

    private func solveWithOllama(_ question: DetectedQuestion, image: CGImage?, system: String,
                                 budget: Int, generation: Int) async throws -> SolveOutcome {
        if state.installedModels.isEmpty || !state.ollamaStatus.isConnected { await refreshOllamaStatus() }
        guard state.ollamaStatus.isConnected else { throw OllamaError.notRunning(settings.ollamaAddress) }

        guard case let .success(choice) = ModelRouter.choose(mode: question.mode, strategy: settings.modelStrategy, textModel: settings.textModel,
                                                             visionModel: settings.visionModel, installed: state.installedModelNames)
        else { throw OllamaError.modelNotFound(settings.textModel) }
        state.activeModel = choice.model

        var images: [String]?
        if choice.attachImage, let image, let encoded = await encodedImage(image, region: question.region, maxDimension: settings.visionMaxDimension) {
            images = [encoded]
        }
        guard generation == solveGeneration, !Task.isCancelled else { throw CancellationError() }

        let client = self.client
        if settings.keepSingleModelLoaded, let previous = lastModelUsed,
           ModelRouter.canonical(previous) != ModelRouter.canonical(choice.model) {
            await client.unload(previous)
        }
        lastModelUsed = choice.model

        let messages = [
            OllamaMessage(role: "system", content: system),
            OllamaMessage(role: "user", content: PromptBuilder.userPrompt(for: question, attachingImage: images != nil, profile: settings.activeProfile), images: images),
        ]
        var think: Bool? = PromptBuilder.shouldThink(kind: question.kind, preference: settings.speedPreference)
        let deadline = Date().addingTimeInterval(settings.requestTimeout)

        for _ in 0..<3 {
            let request = OllamaChatRequest(
                model: choice.model, messages: messages, think: think, keep_alive: OllamaDefaults.keepAlive,
                options: .init(num_predict: budget + (think == true ? 3072 : 0), temperature: 0.2, num_ctx: OllamaDefaults.contextLength))
            do {
                var raw = ""
                var doneReason: String?
                var lastUpdate = Date.distantPast
                for try await chunk in client.chat(request) {
                    guard generation == solveGeneration, !Task.isCancelled else { throw CancellationError() }
                    if Date() > deadline { throw OllamaError.timedOut }
                    if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                        state.isThinking = true
                        state.thinkingCharacters += thinking.count
                    }
                    if let content = chunk.message?.content, !content.isEmpty {
                        raw += content
                        state.isThinking = false
                        show(raw, lastUpdate: &lastUpdate)
                    }
                    if chunk.done == true { doneReason = chunk.done_reason }
                }
                if AnswerParser.parse(raw).isEmpty {
                    // Thinking can exhaust the token budget; retry without it.
                    if think == true { think = false; continue }
                    throw OllamaError.emptyResponse
                }
                return SolveOutcome(raw: raw, model: choice.model, mode: images != nil ? .vision : .text,
                                    truncated: doneReason == "length", note: choice.note)
            } catch let OllamaError.server(_, message) where think != nil && message.lowercased().contains("think") {
                think = nil   // model doesn't support the think parameter
            }
        }
        throw OllamaError.emptyResponse
    }

    /// Full-width band around the question, generous enough to include a figure above or
    /// below it. Returns nil (use the whole image) when the band would cover most of it anyway.
    static func visionCrop(for region: CGRect) -> CGRect? {
        guard region.height > 0 else { return nil }
        let top = max(0, region.minY - 0.35)
        let bottom = min(1, region.maxY + 0.35)
        guard bottom - top < 0.85 else { return nil }
        return CGRect(x: 0, y: top, width: 1, height: bottom - top)
    }

    /// Loads the models now so the first answer doesn't wait for a cold start.
    func preloadModels() async {
        guard settings.aiProvider == .ollama else { return }   // Ollama is only a fallback; don't hold RAM
        if state.installedModels.isEmpty { await refreshOllamaStatus() }
        guard state.ollamaStatus.isConnected else { return }
        let installed = state.installedModelNames
        var models: [String] = []
        if settings.modelStrategy != .visionOnly, let text = ModelRouter.resolve(settings.textModel, in: installed) { models.append(text) }
        if settings.modelStrategy != .textOnly, let vision = ModelRouter.resolve(settings.visionModel, in: installed) { models.append(vision) }
        let client = self.client
        for model in models { await client.preload(model) }
    }

    /// Asks the first available model in the user's provider order whether the text is a real question.
    private func classify(_ question: DetectedQuestion) async -> Bool? {
        for backend in currentBackends(withImage: false) {
            guard !Task.isCancelled else { return nil }
            let output: String
            do {
                switch backend {
                case let .gemini(model):
                    output = try await gemini(settings.geminiAPIKey ?? "").generateText(.init(
                        model: model, system: PromptBuilder.classificationSystemPrompt,
                        text: PromptBuilder.classificationTranscript(for: question),
                        maxOutputTokens: 256, temperature: 0, thinkingLevel: "low"))
                case let .groq(model):
                    output = try await groq(settings.groqAPIKey ?? "").generateText(.init(
                        model: model, system: PromptBuilder.classificationSystemPrompt,
                        text: PromptBuilder.classificationTranscript(for: question),
                        maxTokens: 300, temperature: 0, reasoningEffort: "low"))
                case let .custom(model):
                    guard let client = custom() else { continue }
                    output = try await client.generateText(.init(
                        model: model, system: PromptBuilder.classificationSystemPrompt,
                        text: PromptBuilder.classificationTranscript(for: question),
                        maxTokens: 1024, temperature: 0, reasoningEffort: nil))
                case .ollama:
                    return await classifyWithOllama(question)
                }
            } catch {
                noteFailure(backend, error)
                continue
            }
            let answer = output.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if answer.hasPrefix("YES") { return true }
            if answer.hasPrefix("NO") { return false }
        }
        return nil
    }

    private func classifyWithOllama(_ question: DetectedQuestion) async -> Bool? {
        let strategy: ModelStrategy = settings.modelStrategy == .visionOnly ? .visionOnly : .textOnly
        guard case let .success(choice) = ModelRouter.choose(mode: .text, strategy: strategy, textModel: settings.textModel,
                                                             visionModel: settings.visionModel, installed: state.installedModelNames)
        else { return nil }
        let messages = PromptBuilder.classificationMessages(for: question)
        var think: Bool? = false
        for _ in 0..<2 {
            let request = OllamaChatRequest(model: choice.model, messages: messages, think: think, keep_alive: OllamaDefaults.keepAlive,
                                            options: .init(num_predict: 4, temperature: 0, num_ctx: OllamaDefaults.contextLength))
            do {
                var output = ""
                for try await chunk in client.chat(request) {
                    output += chunk.message?.content ?? ""
                }
                let answer = AnswerParser.stripThinking(output).uppercased()
                if answer.hasPrefix("YES") { return true }
                if answer.hasPrefix("NO") { return false }
                return nil
            } catch let OllamaError.server(_, message) where think != nil && message.lowercased().contains("think") {
                think = nil
            } catch {
                return nil
            }
        }
        return nil
    }

    private func present(_ record: AnswerRecord) {
        state.resetAnswer()
        state.parsed = record.parsed
        state.rawResponse = record.raw
        state.activeModel = record.model
        state.answerFromCache = true
        state.answerDuration = record.duration
        state.phase = .answer
        if settings.showOverlayForNewAnswers { showOverlay?() }
    }

    private func fail(_ error: Error) {
        Log.ai.error("Inference failed: \(error.localizedDescription, privacy: .public)")
        if let ollamaError = error as? OllamaError {
            let title: String
            switch ollamaError {
            case .notRunning: title = "Ollama isn't running"
            case .modelNotFound: title = "Model not installed"
            case .outOfMemory: title = "Out of memory"
            case .timedOut: title = "Model timed out"
            default: title = "Model error"
            }
            state.phase = .error(title: title, detail: ollamaError.localizedDescription, hint: ollamaError.recoveryHint)
            switch ollamaError {
            case .modelNotFound, .outOfMemory: state.errorAction = .openAISettings
            default: state.errorAction = .retry
            }
            if case .modelNotFound = ollamaError { Task { await refreshOllamaStatus() } }
        } else {
            state.phase = .error(title: "Something went wrong", detail: error.localizedDescription, hint: nil)
            state.errorAction = .retry
        }
        if settings.showOverlayForNewAnswers { showOverlay?() }
    }

    private func showPermissionError(reveal: Bool) {
        state.phase = .error(
            title: "Screen Recording permission needed",
            detail: "Seer needs Screen Recording access to read questions on screen. Screenshots stay on this Mac.",
            hint: "Open System Settings → Privacy & Security → Screen & System Audio Recording, enable Seer, then relaunch Seer."
        )
        state.errorAction = .openScreenRecordingSettings
        if reveal { showOverlay?() }
    }

    // MARK: - History & helpers

    func clearHistory() async {
        await cache.clear()
        dismissed.removeAll()
        rejected.removeAll()
    }

    private func remember(_ fingerprint: QuestionFingerprint, in list: inout [QuestionFingerprint]) {
        list.append(fingerprint)
        if list.count > 100 { list.removeFirst(list.count - 100) }
    }

    private func makeCaptureRequest() -> CaptureRequest {
        let front = NSWorkspace.shared.frontmostApplication
        return CaptureRequest(
            scope: settings.captureScope,
            maxDimension: settings.captureMaxDimension,
            excludedBundleIDs: Set(settings.excludedBundleIDs),
            excludedWindowKeywords: settings.excludedWindowKeywords,
            ownBundleID: Bundle.main.bundleIdentifier ?? "",
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            frontmostBundleID: front?.bundleIdentifier,
            frontmostAppName: front?.localizedName,
            frontmostProcessID: front?.processIdentifier,
            targetDisplayID: targetDisplayID(),
            secureInputActive: IsSecureEventInputEnabled()
        )
    }

    private func targetDisplayID() -> CGDirectDisplayID? {
        switch settings.displayTarget {
        case .primary:
            return CGMainDisplayID()
        case .underMouse:
            let location = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }?.displayID ?? CGMainDisplayID()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
