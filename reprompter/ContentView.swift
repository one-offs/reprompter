//
//  ContentView.swift
//  reprompter
//
//  Created by Karthik on 01/04/26.
//

import SwiftUI
import AppKit

// MARK: - Main View

struct ContentView: View {
    private enum UIConstants {
        static let panelSpacing: CGFloat = 12
        static let guideSpacing: CGFloat = 12
        static let promptInset: CGFloat = 8
        static let guideInset: CGFloat = 8
        static let minimumPromptHeight: CGFloat = 120
        static let minimumGuideHeight: CGFloat = 64
        static let footerGuideToggleSpacing: CGFloat = 6
        static let footerActionsSpacing: CGFloat = 8
        static let statusAnimationDuration: Double = 0.16
        static let guideToggleAnimationDuration: Double = 0.18
    }

    @ObservedObject var controller: PanelController
    @State private var promptIsFocused = false
    @State private var guideIsFocused = false
    @State private var showingStatusDetail = false

    private var promptIsEmpty: Bool {
        controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var guideIsEmpty: Bool {
        controller.repromptInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var guideToggleBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.isGuideEnabled },
            set: { newValue in
                withAnimation(.easeInOut(duration: UIConstants.guideToggleAnimationDuration)) {
                    controller.settings.isGuideEnabled = newValue
                }
                if !newValue {
                    controller.focusedEditor = .prompt
                }
            }
        )
    }

    var body: some View {
        if controller.isCollapsed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: UIConstants.panelSpacing) {
                editorArea
                footerBar
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editorArea: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let splitSpacing: CGFloat = controller.settings.isGuideEnabled ? UIConstants.guideSpacing : 0
            let contentHeight = max(0, totalHeight - splitSpacing)
            let promptHeight = controller.settings.isGuideEnabled ? max(UIConstants.minimumPromptHeight, contentHeight * 0.8) : totalHeight
            let instructionsHeight = max(UIConstants.minimumGuideHeight, contentHeight * 0.2)

            VStack(spacing: controller.settings.isGuideEnabled ? UIConstants.guideSpacing : 0) {
                promptEditor(height: promptHeight)

                if controller.settings.isGuideEnabled {
                    guideEditor(height: instructionsHeight)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var footerBar: some View {
        HStack {
            HStack(spacing: UIConstants.footerGuideToggleSpacing) {
                Text("Guide")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Guide", isOn: guideToggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .disabled(controller.isRewriting)

            Spacer()

            if controller.isRewriting {
                ProgressView()
                    .controlSize(.small)
            } else if let status = controller.statusMessage ?? controller.repromptBlockerMessage {
                HStack(spacing: 4) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    if controller.statusMessageDetail != nil {
                        Button {
                            showingStatusDetail = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showingStatusDetail, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Error Detail").font(.subheadline.weight(.semibold))
                                Divider()
                                ScrollView {
                                    Text(controller.statusMessageDetail ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.bottom, 4)
                                }
                            }
                            .padding()
                            .frame(width: 400)
                            .frame(maxHeight: 260)
                        }
                    }
                }
            }

            HStack(spacing: UIConstants.footerActionsSpacing) {

                let isRewriteDisabled =
                    controller.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    controller.isRewriting ||
                    !controller.canRepromptWithCurrentProvider

                ControlGroup {
                    Button("Rewrite") {
                        controller.rewritePrompt()
                    }
                    .keyboardShortcut(.return)
                    .disabled(isRewriteDisabled)

                    Button {
                        controller.rewriteAndCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(isRewriteDisabled)
                    .help("Rewrite and copy to clipboard")
                }
            }
            .controlSize(.large)
        }
        .padding(.top, controller.settings.isGuideEnabled ? UIConstants.guideSpacing : 0)
    }

    private func promptEditor(height: CGFloat) -> some View {
        ZStack {
            PromptTextEditor(
                text: $controller.promptText,
                isEditable: !controller.isRewriting,
                topContentInset: UIConstants.promptInset,
                bottomContentInset: UIConstants.promptInset,
                onTextViewReady: { textView in
                    controller.registerTextView(textView, for: .prompt)
                },
                onFocusChange: { isFocused in
                    promptIsFocused = isFocused
                    if isFocused {
                        controller.focusedEditor = .prompt
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )

            VStack {
                Text("Prompt to rewrite\nExample: \"Build an iOS SwiftUI task manager app with reminders, tags, and offline sync.\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .padding(.leading, 16)
                Spacer()
            }
            .opacity(promptIsEmpty && !promptIsFocused ? 1 : 0)
            .animation(.easeInOut(duration: UIConstants.statusAnimationDuration), value: promptIsEmpty)
            .animation(.easeInOut(duration: UIConstants.statusAnimationDuration), value: promptIsFocused)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(controller.tokenUsageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .clipShape(Capsule(style: .continuous))
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
    }

    private func guideEditor(height: CGFloat) -> some View {
        ZStack {
            PromptTextEditor(
                text: $controller.repromptInstructions,
                isEditable: !controller.isRewriting,
                topContentInset: UIConstants.guideInset,
                bottomContentInset: UIConstants.guideInset,
                onTextViewReady: { textView in
                    controller.registerTextView(textView, for: .guide)
                },
                onFocusChange: { isFocused in
                    guideIsFocused = isFocused
                    if isFocused {
                        controller.focusedEditor = .guide
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )

            VStack {
                Text("Guide for rewriting\nExample: \"Keep it concise, include acceptance criteria, and output bullet points.\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .padding(.leading, 16)
                Spacer()
            }
            .opacity(guideIsEmpty && !guideIsFocused ? 1 : 0)
            .animation(.easeInOut(duration: UIConstants.statusAnimationDuration), value: guideIsEmpty)
            .animation(.easeInOut(duration: UIConstants.statusAnimationDuration), value: guideIsFocused)
            .allowsHitTesting(false)
        }
        .frame(height: height)
    }
}

// MARK: - Prompt Editor

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var onTextViewReady: ((NSTextView) -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChange: onFocusChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: bottomContentInset, right: 0)

        let textView = FocusAwareTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = onFocusChange
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 10)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        onTextViewReady?(textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusAwareTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEditable
        textView.onFocusChange = onFocusChange
        scrollView.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: bottomContentInset, right: 0)
        onTextViewReady?(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onFocusChange: ((Bool) -> Void)?

        init(text: Binding<String>, onFocusChange: ((Bool) -> Void)?) {
            _text = text
            self.onFocusChange = onFocusChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange?(false)
        }
    }
}

// MARK: - Focus Tracking TextView

private final class FocusAwareTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }
}

#Preview {
    ContentView(controller: PanelController())
        .frame(width: 480, height: 340)
}
