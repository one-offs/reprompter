//
//  SettingsView.swift
//  reprompter
//

import SwiftUI
import AppKit

struct ReprompterSettingsView: View {
    @ObservedObject var controller: PanelController

    var body: some View {
        TabView {
            modelTab
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            systemPromptTab
                .tabItem {
                    Label("Prompt", systemImage: "text.quote")
                }

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .padding(20)
        .background(SettingsWindowTitleConfigurator(title: "Reprompter Settings"))
    }

    private var modelTab: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow(title: "Service provider:") {
                        Picker("Service provider", selection: Bindable(controller.settings).provider) {
                            ForEach(ReprompterProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Divider()

                    switch controller.settings.provider {
                    case .foundationModel:
                        settingsHintRow(
                            "Uses on-device Apple Foundation Models. No API key required."
                        )

                    case .openAI:
                        providerField(title: "OpenAI API key:", secureText: Bindable(controller.settings).openAIAPIKey)
                        settingsRow(title: "OpenAI model:") {
                            HStack(spacing: 8) {
                                let models = controller.settings.openAIAvailableModels
                                if models.isEmpty {
                                    if controller.settings.isFetchingOpenAIModels {
                                        ProgressView().controlSize(.small)
                                        Text("Loading models…").foregroundStyle(.secondary)
                                    } else {
                                        TextField("gpt-4o-mini", text: Bindable(controller.settings).openAIModel)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                } else {
                                    Picker("Model", selection: Bindable(controller.settings).openAIModel) {
                                        Text("Default (gpt-4o-mini)").tag("")
                                        ForEach(models, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    if controller.settings.isFetchingOpenAIModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button {
                                            Task { await controller.settings.fetchOpenAIModels() }
                                        } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless)
                                        .help("Refresh model list")
                                    }
                                }
                            }
                        }
                        providerField(title: "Base URL:", text: Bindable(controller.settings).openAIBaseURL, placeholder: "https://api.openai.com/v1/chat/completions")
                        if let urlError = controller.settings.openAIBaseURLError {
                            settingsErrorRow(urlError)
                        }

                    case .anthropic:
                        providerField(title: "Anthropic API key:", secureText: Bindable(controller.settings).anthropicAPIKey)
                        settingsRow(title: "Anthropic model:") {
                            HStack(spacing: 8) {
                                let models = controller.settings.anthropicAvailableModels
                                if models.isEmpty {
                                    if controller.settings.isFetchingAnthropicModels {
                                        ProgressView().controlSize(.small)
                                        Text("Loading models…").foregroundStyle(.secondary)
                                    } else {
                                        TextField("claude-3-5-sonnet-latest", text: Bindable(controller.settings).anthropicModel)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                } else {
                                    Picker("Model", selection: Bindable(controller.settings).anthropicModel) {
                                        Text("Default (claude-3-5-sonnet-latest)").tag("")
                                        ForEach(models) { Text($0.displayName).tag($0.id) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    if controller.settings.isFetchingAnthropicModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button {
                                            Task { await controller.settings.fetchAnthropicModels() }
                                        } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless)
                                        .help("Refresh model list")
                                    }
                                }
                            }
                        }

                    case .google:
                        providerField(title: "Google API key:", secureText: Bindable(controller.settings).googleAPIKey)
                        settingsRow(title: "Google model:") {
                            HStack(spacing: 8) {
                                let models = controller.settings.googleAvailableModels
                                if models.isEmpty {
                                    if controller.settings.isFetchingGoogleModels {
                                        ProgressView().controlSize(.small)
                                        Text("Loading models…").foregroundStyle(.secondary)
                                    } else {
                                        TextField("gemini-2.0-flash-lite", text: Bindable(controller.settings).googleModel)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                } else {
                                    Picker("Model", selection: Bindable(controller.settings).googleModel) {
                                        Text("Default (gemini-2.0-flash-lite)").tag("")
                                        ForEach(models, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    if controller.settings.isFetchingGoogleModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button {
                                            Task { await controller.settings.fetchGoogleModels() }
                                        } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless)
                                        .help("Refresh model list")
                                    }
                                }
                            }
                        }

                    case .githubCopilot:
                        githubCopilotSection

                    case .ollama:
                        settingsRow(title: "Base URL:") {
                            TextField("http://localhost:11434", text: Bindable(controller.settings).ollamaBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        settingsRow(title: "Model:") {
                            HStack(spacing: 8) {
                                let models = controller.settings.ollamaAvailableModels
                                if models.isEmpty {
                                    if controller.settings.isFetchingOllamaModels {
                                        ProgressView().controlSize(.small)
                                        Text("Loading models…").foregroundStyle(.secondary)
                                    } else {
                                        TextField("llama3.2", text: Bindable(controller.settings).ollamaModel)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                } else {
                                    Picker("Model", selection: Bindable(controller.settings).ollamaModel) {
                                        Text("Select a model").tag("")
                                        ForEach(models, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    if controller.settings.isFetchingOllamaModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button {
                                            Task { await controller.settings.fetchOllamaModels() }
                                        } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(.borderless)
                                        .help("Refresh model list")
                                    }
                                }
                            }
                        }
                        settingsHintRow("Requires Ollama running locally. Visit ollama.com to install and pull models.")
                    }

                    Divider()

                    settingsRow(title: "API key storage:") {
                        Toggle("Store in Keychain", isOn: Bindable(controller.settings).useKeychainStorage)
                    }
                    settingsHintRow("When off, API keys and access tokens are stored in app preferences. Enable for more secure storage via macOS Keychain.")

                    Divider()

                    settingsRow(title: "Connection:") {
                        HStack(spacing: 10) {
                            Button("Test Connection") {
                                controller.testProviderConnection()
                            }
                            .disabled(controller.isTestingProviderConnection || controller.settings.providerConfigurationError != nil)

                            if controller.isTestingProviderConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }

                    settingsHintRow("Runs a lightweight API call to validate credentials/connectivity.")

                    if let testMessage = controller.providerConnectionTestMessage {
                        if controller.providerConnectionTestIsError {
                            settingsErrorRow(testMessage, detail: controller.providerConnectionTestDetailMessage)
                        } else {
                            settingsSuccessRow(testMessage)
                        }
                    }

                    if let configError = controller.settings.providerConfigurationError {
                        settingsErrorRow(configError)
                    }

                    Spacer()
                }
                .frame(width: 740, alignment: .topLeading)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await controller.settings.fetchOpenAIModels()
            await controller.settings.fetchGoogleModels()
            await controller.settings.fetchAnthropicModels()
            await controller.settings.fetchOllamaModels()
        }
    }

    private var systemPromptTab: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text("System prompt sections")
                        .font(.headline)

                    Text("These are combined into one system prompt during rewrite.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    promptSection(
                        title: "Main section",
                        hint: "Core behavior used for all rewrites.",
                        text: Bindable(controller.settings).systemPromptMain,
                        defaultText: SettingsStore.defaultSystemPromptMain,
                        requiredPlaceholders: []
                    )

                    promptSection(
                        title: "Guide section",
                        hint: "Used when Guide has text. You can use {guide}.",
                        text: Bindable(controller.settings).systemPromptGuide,
                        defaultText: SettingsStore.defaultSystemPromptGuide,
                        requiredPlaceholders: ["{guide}"]
                    )
                }
                .frame(width: 820, alignment: .leading)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var githubCopilotSection: some View {
        settingsRow(title: "GitHub account:") {
            switch controller.settings.authManager.state {
            case .disconnected, .error:
                Button("Sign in with GitHub") {
                    Task { await controller.settings.authManager.startDeviceFlow() }
                }

            case .requestingCode, .polling:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Requesting code…").foregroundStyle(.secondary)
                }

            case .waitingForUser(let code, let url, _):
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.link)
                    Button("Open GitHub") { NSWorkspace.shared.open(url) }
                    Button("Cancel") {
                        controller.settings.authManager.disconnect()
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                }

            case .connected:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if let username = controller.settings.authManager.connectedUsername {
                        Text("@\(username)")
                    } else {
                        Text("Connected")
                    }
                    Spacer()
                    Button("Disconnect") {
                        controller.settings.authManager.disconnect()
                        controller.settings.githubCopilotAccessToken = ""
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                }
            }
        }

        if case .error(let msg) = controller.settings.authManager.state {
            settingsErrorRow(msg)
        }
        if case .waitingForUser = controller.settings.authManager.state {
            settingsHintRow("Visit github.com/login/device and enter the code above to authorize.")
        }

        settingsRow(title: "Model:") {
            HStack(spacing: 8) {
                let models = controller.settings.authManager.availableModels
                if models.isEmpty {
                    if controller.settings.authManager.isFetchingModels {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").foregroundStyle(.secondary)
                    } else {
                        TextField("gpt-4o", text: Bindable(controller.settings).githubCopilotModel)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    Picker("Model", selection: Bindable(controller.settings).githubCopilotModel) {
                        Text("Default (gpt-4o)").tag("")
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    if controller.settings.authManager.isFetchingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            let token = controller.settings.githubCopilotAccessToken
                            Task { await controller.settings.authManager.fetchModels(githubToken: token) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh model list")
                    }
                }
            }
        }
    }

    private var shortcutsTab: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow(title: "Toggle panel:") {
                        HStack(spacing: 8) {
                            ShortcutRecorderView(config: Bindable(controller.settings).hotkeyConfig)
                                .frame(width: 160, height: 28)
                            if controller.settings.hotkeyConfig != nil {
                                Button("Clear") {
                                    controller.settings.hotkeyConfig = nil
                                    controller.settings.isHotkeyEnabled = false
                                }
                            }
                        }
                    }
                    settingsHintRow("Click the field and press a key combination to record a shortcut.")

                    settingsRow(title: "") {
                        Toggle("Enable global shortcut", isOn: Bindable(controller.settings).isHotkeyEnabled)
                            .disabled(controller.settings.hotkeyConfig == nil)
                    }

                    Divider()

                    settingsRow(title: "Input Monitoring:") {
                        if controller.hasInputMonitoringPermission {
                            Text("Access granted")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                Button("Open System Settings") {
                                    controller.openInputMonitoringSettings()
                                }
                                Text("Required to receive events from other apps")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !controller.hasInputMonitoringPermission {
                        settingsHintRow("Allow Reprompter in System Settings → Privacy & Security → Input Monitoring, then re-enable the shortcut.")
                    }

                    Spacer()
                }
                .frame(width: 740, alignment: .topLeading)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func promptSection(
        title: String,
        hint: String,
        text: Binding<String>,
        defaultText: String,
        requiredPlaceholders: [String]
    ) -> some View {
        let missing = missingPlaceholders(in: text.wrappedValue, required: requiredPlaceholders)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button("Reset to defaults") {
                    text.wrappedValue = defaultText
                }
                .buttonStyle(.link)
                .disabled(text.wrappedValue == defaultText)
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            SyntaxHighlightedPromptEditor(text: text)
                .frame(minHeight: 110)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            if !missing.isEmpty {
                Text("Missing placeholder(s): \(missing.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func providerField(title: String, text: Binding<String>, placeholder: String = "") -> some View {
        settingsRow(title: title) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func providerField(title: String, secureText: Binding<String>) -> some View {
        settingsRow(title: title) {
            SecureField("", text: secureText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func settingsRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSuccessRow(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("")
                .frame(width: 220)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsHintRow(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("")
                .frame(width: 220)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsErrorRow(_ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("").frame(width: 220)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    DisclosureGroup("Advanced") {
                        Text(detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func missingPlaceholders(in text: String, required: [String]) -> [String] {
        guard !required.isEmpty else { return [] }
        let normalizedText = text.lowercased()
        return required.filter { !normalizedText.contains($0.lowercased()) }
    }
}

// MARK: - Syntax Highlighted Prompt Editor

struct SyntaxHighlightedPromptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 10, height: 10)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.applyHighlighting(in: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting(in: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private let tokenRegex = try? NSRegularExpression(pattern: "\\{[^\\}]+\\}")
        private let knownPlaceholders: Set<String> = ["{guide}"]

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            applyHighlighting(in: textView)
        }

        func applyHighlighting(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textStorage.beginEditing()
            textStorage.setAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor
                ],
                range: fullRange
            )

            if let tokenRegex {
                let matches = tokenRegex.matches(in: textStorage.string, range: fullRange)
                for match in matches {
                    let token = (textStorage.string as NSString).substring(with: match.range).lowercased()
                    let highlightColor: NSColor = knownPlaceholders.contains(token) ? .systemBlue : .systemOrange
                    textStorage.addAttributes(
                        [
                            .foregroundColor: highlightColor,
                            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
                        ],
                        range: match.range
                    )
                }
            }

            textStorage.endEditing()
        }
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var config: HotkeyConfig?

    func makeCoordinator() -> Coordinator { Coordinator(config: $config) }

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.config = config
        if !nsView.isRecording { nsView.updateDisplay() }
    }

    final class Coordinator {
        @Binding var config: HotkeyConfig?
        init(config: Binding<HotkeyConfig?>) { _config = config }
        func setConfig(_ c: HotkeyConfig?) { config = c }
    }
}

final class RecorderNSView: NSView {
    var coordinator: ShortcutRecorderView.Coordinator?
    var config: HotkeyConfig?
    var isRecording = false {
        didSet { updateDisplay(); needsDisplay = true }
    }

    private let label: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.alignment = .center
        f.font = .systemFont(ofSize: 13)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12)
        ])
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateDisplay() {
        if isRecording {
            label.stringValue = "Type shortcut…"
            label.textColor = .secondaryLabelColor
        } else if let config {
            label.stringValue = config.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = "Click to record"
            label.textColor = .placeholderTextColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let keyCode = event.keyCode

        // Escape — cancel without changing the config
        if keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        // Delete/Backspace — clear
        if keyCode == 51 || keyCode == 117 {
            coordinator?.setConfig(nil)
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        // Skip standalone modifier presses
        guard !isModifierKeyCode(keyCode) else { return }

        let modifiers = event.modifierFlags
            .intersection([.command, .control, .option, .shift])
        // Require at least one modifier so bare letter keys don't fire globally
        guard !modifiers.isEmpty else { return }

        coordinator?.setConfig(HotkeyConfig(
            keyCode: keyCode,
            modifiers: modifiers.rawValue,
            displayKey: displayKey(for: event)
        ))
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if isRecording { isRecording = false }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1.0
        path.stroke()
    }

    // MARK: - Helpers

    private func isModifierKeyCode(_ code: UInt16) -> Bool {
        // Left/right command, shift, option, control, caps lock, fn
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code)
    }

    private func displayKey(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 76: "↩",
            96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 115: "↖", 116: "⇞", 117: "⌦",
            118: "F4", 119: "↘", 120: "F2", 121: "⇟",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return special[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "?"
    }
}

// MARK: - Settings Window Title Configurator

struct SettingsWindowTitleConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
