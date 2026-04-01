//
//  PanelController.swift
//  reprompter
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class PanelController: NSObject, ObservableObject, NSWindowDelegate {
    let settings = SettingsStore()

    private let minimumPanelSize = NSSize(width: 600, height: 360)
    private let hardInputCharacterLimit = 400_000

    @Published var promptText = ""
    @Published var isRewriting = false
    @Published var statusMessage: String? {
        didSet { if statusMessage == nil { statusMessageDetail = nil } }
    }
    @Published var statusMessageDetail: String?
    @Published var repromptInstructions = ""
    @Published private(set) var isPanelVisible = false
    @Published var isCollapsed = false
    @Published var focusedEditor: FocusedEditor = .prompt
    @Published private(set) var isTestingProviderConnection = false
    @Published private(set) var providerConnectionTestMessage: String?
    @Published private(set) var providerConnectionTestDetailMessage: String?
    @Published private(set) var providerConnectionTestIsError = false
    @Published private(set) var isDictationEnabled = false
    @Published private(set) var isWritingToolsEnabled = false
    @Published private(set) var promptHistory: [PromptHistoryEntry] = []
    @Published private(set) var archives: [ArchiveEntry] = []

    private var panel: FloatingPanel?
    private weak var promptTextView: NSTextView?
    private weak var guideTextView: NSTextView?
    private var collapseButton: NSButton?
    private var headerAccessoryController: NSTitlebarAccessoryViewController?
    private var expandedFrameBeforeCollapse: NSRect?
    private var expandedMinSizeBeforeCollapse: NSSize?
    private var expandedContentMinSizeBeforeCollapse: NSSize?
    private let repromptService = RepromptService()
    private var activeRewriteTask: Task<Void, Never>?
    private var rewriteRequestID: UInt64 = 0
    private let hotkeyManager = GlobalHotkeyManager()

    override init() {
        super.init()
        settings.onWindowBehaviorChanged = { [weak self] in
            self?.applyWindowBehavior()
        }
        settings.onHotkeyChanged = { [weak self] in
            self?.applyHotkey()
        }
        settings.onProviderOrModelChanged = { [weak self] in
            self?.providerConnectionTestMessage = nil
            self?.providerConnectionTestDetailMessage = nil
            self?.providerConnectionTestIsError = false
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidFinishLaunching),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
    }

    deinit {
        activeRewriteTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleDidFinishLaunching() {
        showPanel()
        applyHotkey()
        DispatchQueue.main.async { [weak self] in
            self?.refreshAccessoryCapabilities()
        }
    }

    // MARK: - Panel Visibility

    func showPanel() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        if panel.frame.width < minimumPanelSize.width || (!isCollapsed && panel.frame.height < minimumPanelSize.height) {
            let clampedSize = NSSize(
                width: max(panel.frame.width, minimumPanelSize.width),
                height: max(panel.frame.height, minimumPanelSize.height)
            )
            panel.setContentSize(clampedSize)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isPanelVisible = true
    }

    func hidePanel() {
        cancelActiveRewrite(resetLoadingState: true)
        if let panel {
            persistWindowPlacement(panel)
            panel.orderOut(nil)
        }
        isPanelVisible = false
    }

    func togglePanel() {
        if isPanelVisible { hidePanel() } else { showPanel() }
    }

    // MARK: - Hotkey

    private func applyHotkey() {
        if settings.isHotkeyEnabled, let config = settings.hotkeyConfig {
            hotkeyManager.register(config: config) { [weak self] in
                self?.togglePanel()
            }
        } else {
            hotkeyManager.unregister()
        }
    }

    var hasInputMonitoringPermission: Bool { hotkeyManager.hasPermission }

    func openInputMonitoringSettings() { hotkeyManager.openPermissionSettings() }

    // MARK: - Prompt Editing

    func clearPrompt() {
        switch focusedEditor {
        case .prompt:
            promptText = ""
        case .guide:
            repromptInstructions = ""
        }
        statusMessage = nil
    }

    func copyPromptToClipboard() {
        let sourceText: String
        switch focusedEditor {
        case .prompt:
            sourceText = promptText
        case .guide:
            sourceText = repromptInstructions
        }

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceText, forType: .string)
    }

    func pastePromptFromClipboard() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string),
              !clipboardText.isEmpty else {
            NSSound.beep()
            return
        }

        switch focusedEditor {
        case .prompt:
            promptText = clipboardText
        case .guide:
            repromptInstructions = clipboardText
        }
        statusMessage = nil
    }

    var canPasteClipboardText: Bool {
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            return false
        }
        return !clipboardText.isEmpty
    }

    var canCopyFocusedText: Bool {
        let text: String
        switch focusedEditor {
        case .prompt:
            text = promptText
        case .guide:
            text = repromptInstructions
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canClearFocusedText: Bool {
        canCopyFocusedText
    }

    // MARK: - Rewrite Orchestration

    /// Initiates a rewrite of the current prompt text.
    ///
    /// The flow:
    /// 1. Validates that input is non-empty and no rewrite is already in progress.
    /// 2. Guards against provider configuration errors (missing API key, etc.).
    /// 3. Stamps a monotonically incrementing `rewriteRequestID` so that any
    ///    in-flight `onPartialOutput` callbacks from a previous request can
    ///    detect they are stale and self-discard.
    /// 4. Cancels any running `activeRewriteTask` before starting the new one.
    /// 5. Dispatches an async `Task` that calls `RepromptService.rewrite()`.
    ///    Streaming providers send incremental text via `onPartialOutput`; each
    ///    callback re-checks `rewriteRequestID` before applying the update.
    /// 6. On completion, bumps `rewriteRequestID` again to invalidate any
    ///    remaining queued `onPartialOutput` closures, preventing stale partial
    ///    text from overwriting the final result.
    /// 7. On success, replaces `promptText` with the result and appends the
    ///    original text to history (unless the output is identical).
    /// 8. On failure, restores `promptText` to its pre-rewrite value and
    ///    surfaces the error in `statusMessage` / `statusMessageDetail`.
    ///
    /// - Parameter copyOnSuccess: If `true`, also writes the result to the
    ///   system clipboard after a successful rewrite.
    func rewritePrompt(copyOnSuccess: Bool = false) {
        let input = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRewriting else { return }
        if let blockerMessage = repromptBlockerMessage {
            statusMessage = blockerMessage
            return
        }
        let promptBeforeRewrite = promptText
        let systemPrompt = settings.composeRewriteSystemPrompt(guideText: repromptInstructions)

        isRewriting = true
        statusMessage = nil
        rewriteRequestID &+= 1
        let currentRequestID = rewriteRequestID
        cancelActiveRewrite(resetLoadingState: false)

        activeRewriteTask = Task { [weak self] in
            guard let self else { return }
            let result = await repromptService.rewrite(
                input,
                provider: settings.provider,
                providerCredentials: settings.credentialsForSelectedProvider(),
                systemPrompt: systemPrompt,
                onPartialOutput: { [weak self] partialText in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard !Task.isCancelled else { return }
                        guard self.rewriteRequestID == currentRequestID else { return }
                        self.promptText = partialText
                    }
                }
            )
            guard !Task.isCancelled else { return }
            guard self.rewriteRequestID == currentRequestID else { return }

            // Bump the ID before touching promptText. Any onPartialOutput tasks
            // still queued on the main actor check this ID and will self-invalidate,
            // preventing stale partial text from overwriting the final result.
            rewriteRequestID &+= 1

            if let message = result.message {
                // Failure: restore the exact pre-rewrite text so no partial
                // output remains visible, then surface the error.
                promptText = promptBeforeRewrite
                statusMessage = message
                statusMessageDetail = result.errorDetail
            } else {
                promptText = result.text
                if result.text != promptBeforeRewrite {
                    appendToHistory(promptBeforeRewrite)
                }
                if copyOnSuccess {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                }
                statusMessage = nil
            }
            isRewriting = false
            activeRewriteTask = nil
        }
    }

    func rewriteAndCopy() {
        rewritePrompt(copyOnSuccess: true)
    }

    private func cancelActiveRewrite(resetLoadingState: Bool) {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil
        if resetLoadingState {
            isRewriting = false
        }
    }

    // MARK: - History

    private func appendToHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != promptHistory.last?.text else { return }
        promptHistory.append(PromptHistoryEntry(text: trimmed, date: Date()))
        if promptHistory.count > 50 { promptHistory.removeFirst() }
    }

    func restoreFromHistory(_ entry: PromptHistoryEntry) {
        guard entry.text != promptText else { return }
        promptText = entry.text
        statusMessage = nil
    }

    func clearHistory() {
        promptHistory.removeAll()
    }

    // MARK: - Archive

    var canArchive: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRewriting
    }

    func archiveCurrentPrompt() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == archives.last?.text {
            // Already archived — bump the date so it sorts as most recent
            archives[archives.count - 1] = ArchiveEntry(text: trimmed, date: Date())
        } else {
            archives.append(ArchiveEntry(text: trimmed, date: Date()))
        }
        promptText = ""
        statusMessage = nil
    }

    func applyArchive(_ entry: ArchiveEntry) {
        promptText = entry.text
        statusMessage = nil
    }

    func removeArchive(_ entry: ArchiveEntry) {
        archives.removeAll { $0.id == entry.id }
    }

    func clearArchives() {
        archives.removeAll()
    }

    // MARK: - Connection Testing

    func testProviderConnection() {
        guard !isTestingProviderConnection else { return }
        if let configError = settings.providerConfigurationError {
            providerConnectionTestMessage = configError
            providerConnectionTestIsError = true
            return
        }

        isTestingProviderConnection = true
        providerConnectionTestMessage = nil
        providerConnectionTestIsError = false

        let selectedProvider = settings.provider
        let selectedCredentials = settings.credentialsForSelectedProvider()

        Task { [weak self] in
            guard let self else { return }
            let result = await repromptService.testConnection(
                provider: selectedProvider,
                providerCredentials: selectedCredentials
            )
            guard !Task.isCancelled else { return }
            isTestingProviderConnection = false
            providerConnectionTestMessage = result.message
            providerConnectionTestDetailMessage = result.errorDetail
            providerConnectionTestIsError = !result.isSuccess
        }
    }

    // MARK: - Token Estimation & Validation

    var estimatedPromptTokens: Int {
        estimateTokens(promptText)
    }

    var tokenUsageText: String {
        if estimatedPromptTokens == 0 {
            return "0 Tokens"
        }
        return "~\(estimatedPromptTokens.formatted()) Tokens"
    }

    var canRepromptWithCurrentProvider: Bool {
        repromptBlockerMessage == nil
    }

    var repromptBlockerMessage: String? {
        settings.providerConfigurationError ?? inputGuardrailError
    }

    var inputGuardrailError: String? {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        if trimmedPrompt.count > hardInputCharacterLimit {
            return "Prompt is too long (\(trimmedPrompt.count.formatted()) chars). Keep it under \(hardInputCharacterLimit.formatted()) characters."
        }

        return nil
    }

    private func estimateTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        // Two-signal heuristic for mixed prose and code:
        //   word-based:  words × 1.3  (accurate for natural-language text)
        //   char-based:  chars ÷ 3.5  (floor for dense code, URLs, long identifiers)
        // Taking the max leans slightly conservative, which is preferable when
        // using the result to gate token-limit warnings.
        let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        let wordBased = Int(ceil(Double(wordCount) * 1.3))
        let charBased = Int(ceil(Double(trimmed.count) / 3.5))
        return max(1, max(wordBased, charBased))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cancelActiveRewrite(resetLoadingState: true)
        if let panel {
            persistWindowPlacement(panel)
        }
        isPanelVisible = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        syncExpandedFrameOriginFromCollapsedWindow(window)
        persistWindowPlacement(window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateCollapseButtonAppearance(for: window)
        refreshAccessoryCapabilities()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateCollapseButtonAppearance(for: window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistWindowPlacement(window)
        layoutCollapseButton(in: window)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if isCollapsed {
            return sender.frame.size
        }

        return NSSize(
            width: max(frameSize.width, minimumPanelSize.width),
            height: max(frameSize.height, minimumPanelSize.height)
        )
    }

    // MARK: - Titlebar Accessories

    @objc
    func openWritingTools(_ sender: Any?) {
        let didOpen = NSApp.sendAction(NSSelectorFromString("showWritingTools:"), to: nil, from: sender)
        if !didOpen {
            NSSound.beep()
        }
    }

    @objc
    func triggerDictation(_ sender: Any?) {
        let sel = NSSelectorFromString("startDictation:")
        guard let panel else {
            NSSound.beep()
            return
        }

        let preferredResponder: NSResponder? = switch focusedEditor {
        case .prompt: promptTextView
        case .guide: guideTextView
        }

        // Keep the panel and expected editor active before dispatching dictation.
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let preferredResponder, panel.firstResponder !== preferredResponder {
            panel.makeFirstResponder(preferredResponder)
        }

        if let preferredResponder,
           preferredResponder.responds(to: sel),
           NSApp.sendAction(sel, to: preferredResponder, from: sender) {
            return
        }

        if NSApp.sendAction(sel, to: nil, from: sender) {
            return
        }

        // Retry once on the next run loop tick in case focus changed during click.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else {
                NSSound.beep()
                return
            }

            let retryTarget: NSResponder? = switch self.focusedEditor {
            case .prompt: self.promptTextView
            case .guide: self.guideTextView
            }

            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let retryTarget, panel.firstResponder !== retryTarget {
                panel.makeFirstResponder(retryTarget)
            }

            if let retryTarget,
               retryTarget.responds(to: sel),
               NSApp.sendAction(sel, to: retryTarget, from: sender) {
                return
            }

            if !NSApp.sendAction(sel, to: nil, from: sender) {
                NSSound.beep()
            }
        }
    }

    func registerTextView(_ textView: NSTextView, for editor: FocusedEditor) {
        switch editor {
        case .prompt:
            promptTextView = textView
        case .guide:
            guideTextView = textView
        }
    }

    private func refreshAccessoryCapabilities() {
        refreshWritingToolsAvailability()
        refreshDictationAvailability()
    }

    private func refreshWritingToolsAvailability() {
        let selector = NSSelectorFromString("showWritingTools:")
        isWritingToolsEnabled = NSApp.target(forAction: selector, to: nil, from: nil) != nil
    }

    private func refreshDictationAvailability() {
        if let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "DictationIMMasterDictationEnabled") as? Bool {
            isDictationEnabled = value
            return
        }

        let selector = NSSelectorFromString("startDictation:")
        isDictationEnabled = NSApp.target(forAction: selector, to: nil, from: nil) != nil
    }

    // MARK: - Collapse / Expand

    @objc
    func toggleCollapsed(_ sender: Any?) {
        guard panel != nil else { return }
        if isCollapsed {
            expandPanel()
        } else {
            collapsePanel()
        }
    }

    private func collapsePanel() {
        guard let panel, !isCollapsed else { return }

        let titlebarHeight = panel.frame.height - panel.contentLayoutRect.height
        let collapsedHeight = max(36, ceil(titlebarHeight))
        guard collapsedHeight.isFinite, collapsedHeight > 0 else { return }

        expandedFrameBeforeCollapse = panel.frame
        expandedMinSizeBeforeCollapse = panel.minSize
        expandedContentMinSizeBeforeCollapse = panel.contentMinSize
        isCollapsed = true
        setHeaderAccessoryVisibility(false, animated: true)
        updateCollapseButtonLabel()

        var nextFrame = panel.frame
        nextFrame.origin.y += (nextFrame.height - collapsedHeight)
        nextFrame.size.height = collapsedHeight

        panel.minSize = NSSize(width: panel.frame.width, height: collapsedHeight)
        panel.contentMinSize = NSSize(width: 1, height: 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    private func expandPanel() {
        guard let panel, isCollapsed else { return }

        isCollapsed = false
        setHeaderAccessoryVisibility(true, animated: true)
        updateCollapseButtonLabel()
        panel.minSize = expandedMinSizeBeforeCollapse ?? minimumPanelSize
        panel.contentMinSize = expandedContentMinSizeBeforeCollapse ?? minimumPanelSize

        if var restoredFrame = expandedFrameBeforeCollapse {
            restoredFrame.size.width = max(restoredFrame.size.width, minimumPanelSize.width)
            restoredFrame.size.height = max(restoredFrame.size.height, minimumPanelSize.height)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(restoredFrame, display: true)
            }
        } else {
            var frame = panel.frame
            frame.size.height = max(frame.size.height, minimumPanelSize.height)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }

        expandedMinSizeBeforeCollapse = nil
        expandedContentMinSizeBeforeCollapse = nil
    }

    // MARK: - Window Behavior & Placement

    private func applyWindowBehavior() {
        guard let panel else { return }

        panel.level = settings.isFloatingOnTop ? .floating : .normal
        panel.alphaValue = settings.isTranslucent ? 0.9 : 1.0
    }

    private func persistWindowPlacement(_ window: NSWindow) {
        let frameToPersist = (isCollapsed ? expandedFrameBeforeCollapse : nil) ?? window.frame
        UserDefaults.standard.set(NSStringFromRect(frameToPersist), forKey: DefaultsKey.panelFrame)

        if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            UserDefaults.standard.set(screenNumber.stringValue, forKey: DefaultsKey.panelScreen)
        }
    }

    private func restoreWindowPlacement(_ window: NSWindow) {
        guard let frameString = UserDefaults.standard.string(forKey: DefaultsKey.panelFrame) else { return }

        var restoredFrame = NSRectFromString(frameString)
        restoredFrame.size.width = max(restoredFrame.size.width, minimumPanelSize.width)
        restoredFrame.size.height = max(restoredFrame.size.height, minimumPanelSize.height)

        if let savedScreenID = UserDefaults.standard.string(forKey: DefaultsKey.panelScreen),
           let targetScreen = NSScreen.screens.first(where: {
               guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                   return false
               }
               return number.stringValue == savedScreenID
           }) {
            let visible = targetScreen.visibleFrame
            restoredFrame.origin.x = min(max(restoredFrame.origin.x, visible.minX), visible.maxX - restoredFrame.size.width)
            restoredFrame.origin.y = min(max(restoredFrame.origin.y, visible.minY), visible.maxY - restoredFrame.size.height)
        }

        window.setFrame(restoredFrame, display: false)
    }

    private func syncExpandedFrameOriginFromCollapsedWindow(_ window: NSWindow) {
        guard isCollapsed, var expandedFrame = expandedFrameBeforeCollapse else { return }

        let collapsedTopY = window.frame.origin.y + window.frame.size.height
        expandedFrame.origin.x = window.frame.origin.x
        expandedFrame.origin.y = collapsedTopY - expandedFrame.size.height
        expandedFrameBeforeCollapse = expandedFrame
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let panelSize = minimumPanelSize
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isReleasedWhenClosed = false
        panel.title = "Reprompter"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            panel.titlebarSeparatorStyle = .none
        }
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false

        panel.minSize = minimumPanelSize
        panel.contentMinSize = minimumPanelSize

        let content = ContentView(controller: self)

        panel.contentView = NSHostingView(rootView: content)
        let headerAccessory = makeHeaderAccessory()
        panel.addTitlebarAccessoryViewController(headerAccessory)
        headerAccessoryController = headerAccessory
        panel.delegate = self
        restoreWindowPlacement(panel)
        addCollapseButton(to: panel)
        panel.orderFrontRegardless()

        self.panel = panel
        applyWindowBehavior()
        self.isPanelVisible = true
    }

    // MARK: - Header Accessory

    private func makeHeaderAccessory() -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right

        let hostingView = NSHostingView(
            rootView: HeaderActionsAccessoryView(
                controller: self,
                writingToolsAction: {
                    self.openWritingTools(nil)
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        accessory.view = hostingView

        return accessory
    }

    private func setHeaderAccessoryVisibility(_ visible: Bool, animated: Bool) {
        guard let view = headerAccessoryController?.view else { return }

        if !animated {
            view.alphaValue = visible ? 1 : 0
            view.isHidden = !visible
            return
        }

        if visible {
            view.alphaValue = 0
            view.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 0
            }, completionHandler: {
                view.isHidden = true
            })
        }
    }

    // MARK: - Collapse Button

    private func addCollapseButton(to window: NSWindow) {
        guard collapseButton == nil,
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebarContainer = zoomButton.superview else {
            return
        }

        let trafficLightHeight = max(12, zoomButton.frame.height)
        let visualHeight = trafficLightHeight + 2
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: visualHeight))
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.focusRingType = .none
        button.title = ""
        button.imagePosition = .imageOnly
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = visualHeight / 2
        button.layer?.borderWidth = 0
        button.layer?.borderColor = nil
        button.layer?.shadowOpacity = 0
        button.target = self
        button.action = #selector(toggleCollapsed(_:))

        titlebarContainer.addSubview(button)
        collapseButton = button
        updateCollapseButtonLabel()
        layoutCollapseButton(in: window)
        updateCollapseButtonAppearance(for: window)
    }

    private func updateCollapseButtonLabel() {
        guard let button = collapseButton else { return }
        let title = isCollapsed ? "Expand" : "Collapse"
        let symbolName = isCollapsed ? "chevron.down" : "chevron.up"
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfig)
        button.toolTip = title
        let trafficLightHeight = max(12, panel?.standardWindowButton(.zoomButton)?.frame.height ?? 14)
        let visualHeight = trafficLightHeight + 2
        button.frame.size = NSSize(width: 28, height: visualHeight)
        button.layer?.cornerRadius = visualHeight / 2

        if let panel {
            layoutCollapseButton(in: panel)
        }
    }

    private func layoutCollapseButton(in window: NSWindow) {
        guard let zoomButton = window.standardWindowButton(.zoomButton),
              let collapseButton else {
            return
        }

        let y = zoomButton.frame.minY + ((zoomButton.frame.height - collapseButton.frame.height) / 2)
        collapseButton.frame.origin = NSPoint(x: zoomButton.frame.maxX + 8, y: y)
    }

    private func updateCollapseButtonAppearance(for window: NSWindow) {
        guard let collapseButton else { return }
        let isActive = window.isKeyWindow
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let backgroundColor: NSColor = switch (isActive, isDark) {
        case (true, false): NSColor(white: 0.74, alpha: 1.0)
        case (true, true): NSColor(white: 0.38, alpha: 1.0)
        case (false, false): NSColor(white: 0.86, alpha: 1.0)
        case (false, true): NSColor(white: 0.28, alpha: 1.0)
        }
        let iconColor: NSColor = switch (isActive, isDark) {
        case (true, false): NSColor.black.withAlphaComponent(0.72)
        case (true, true): NSColor.white.withAlphaComponent(0.88)
        case (false, false): NSColor.black.withAlphaComponent(0.45)
        case (false, true): NSColor.white.withAlphaComponent(0.55)
        }

        collapseButton.layer?.backgroundColor = backgroundColor.cgColor
        collapseButton.contentTintColor = iconColor
    }
}

// MARK: - Header Actions Accessory

private struct HeaderActionsAccessoryView: View {
    @ObservedObject var controller: PanelController
    let writingToolsAction: () -> Void
    @State private var showingHistory = false
    @State private var showingArchives = false

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if controller.isWritingToolsEnabled || controller.isDictationEnabled {
                ControlGroup {
                    if controller.isWritingToolsEnabled {
                        Button {
                            writingToolsAction()
                        } label: {
                            Label("Writing Tools", systemImage: "apple.intelligence")
                        }
                        .help("Open Writing Tools")
                        .disabled(controller.isRewriting)
                    }

                    if controller.isDictationEnabled {
                        Button {
                            controller.triggerDictation(nil)
                        } label: {
                            Label("Dictation", systemImage: "mic")
                        }
                        .help("Start Dictation")
                        .disabled(controller.isRewriting)
                    }
                }
                .labelStyle(.iconOnly)
                .controlGroupStyle(.navigation)
            }

            ControlGroup {
                Button {
                    controller.archiveCurrentPrompt()
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
                .disabled(!controller.canArchive)
                .help("Archive")

                Button {
                    showingArchives.toggle()
                } label: {
                    Label("Archives", systemImage: "archivebox")
                }
                .disabled(controller.archives.isEmpty)
                .help("Archives")
            }
            .labelStyle(.iconOnly)
            .controlGroupStyle(.navigation)
            .popover(isPresented: $showingArchives, arrowEdge: .bottom) {
                ArchivesPopoverView(controller: controller, isPresented: $showingArchives)
            }

            ControlGroup {
                Button {
                    showingHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(controller.promptHistory.isEmpty || controller.isRewriting)
                .help("Rewrite History")
            }
            .labelStyle(.iconOnly)
            .controlGroupStyle(.navigation)
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                HistoryPopoverView(controller: controller, isPresented: $showingHistory)
            }

            ControlGroup {
                Button {
                    controller.pastePromptFromClipboard()
                } label: {
                    Label("Paste Prompt", systemImage: "clipboard")
                }
                .disabled(controller.isRewriting || !controller.canPasteClipboardText)
                .help("Paste Clipboard Into Prompt")

                Button {
                    controller.copyPromptToClipboard()
                } label: {
                    Label("Copy Prompt", systemImage: "doc.on.doc")
                }
                .disabled(!controller.canCopyFocusedText || controller.isRewriting)
                .help("Copy Prompt")

                Button {
                    controller.clearPrompt()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(!controller.canClearFocusedText || controller.isRewriting)
                .help("Clear")
            }
            .labelStyle(.iconOnly)
            .controlGroupStyle(.navigation)
        }
        .padding(.top, 8)
        .padding(.trailing, 14)
    }
}

// MARK: - History Popover

private struct HistoryPopoverView: View {
    @ObservedObject var controller: PanelController
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rewrite History")
                    .font(.headline)
                Spacer()
                Button("Clear") { controller.clearHistory() }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(controller.promptHistory.reversed()) { entry in
                        HistoryEntryRow(entry: entry) {
                            controller.restoreFromHistory(entry)
                            isPresented = false
                        }
                        Divider()
                    }
                }
            }
            .frame(width: 320, height: 280)
        }
    }
}

private struct HistoryEntryRow: View {
    let entry: PromptHistoryEntry
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            VStack(alignment: .leading, spacing: 3) {
                Text(previewText)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001)) // improves hit-testing
    }

    private var previewText: String {
        let firstLine = entry.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let candidate = firstLine.isEmpty ? entry.text : firstLine
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

// MARK: - Archives Popover

private struct ArchivesPopoverView: View {
    @ObservedObject var controller: PanelController
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Archives")
                    .font(.headline)
                Spacer()
                Button("Clear All") { controller.clearArchives() }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(controller.archives.reversed()) { entry in
                        ArchiveEntryRow(entry: entry) {
                            controller.applyArchive(entry)
                            isPresented = false
                        } onDelete: {
                            controller.removeArchive(entry)
                        }
                        Divider()
                    }
                }
            }
            .frame(width: 320, height: 280)
        }
    }
}

private struct ArchiveEntryRow: View {
    let entry: ArchiveEntry
    let onApply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onApply) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(previewText)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.001))

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("Remove archive")
        }
    }

    private var previewText: String {
        let firstLine = entry.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let candidate = firstLine.isEmpty ? entry.text : firstLine
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

// MARK: - Floating Panel

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
