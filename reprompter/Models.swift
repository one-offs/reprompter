//
//  Models.swift
//  reprompter
//

import Foundation
import AppKit

enum FocusedEditor {
    case prompt
    case guide
}

enum ReprompterProvider: String, CaseIterable, Identifiable {
    case foundationModel = "Apple Foundation Model"
    case ollama = "Ollama"
    case githubCopilot = "GitHub Copilot"
    case openAI = "OpenAI"
    case google = "Google"
    case anthropic = "Anthropic"

    var id: String { rawValue }
}

struct ProviderCredentials {
    let apiKey: String
    let baseURL: String?
    let modelName: String?
}

// MARK: - Prompt History

struct PromptHistoryEntry: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

// MARK: - Archive

struct ArchiveEntry: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

// MARK: - Hotkey

struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt16
    /// Device-independent modifier flags rawValue, masked to ⌘⌃⌥⇧ only.
    let modifiers: UInt
    /// Display character captured at record time (e.g. "R", "Space", "F5").
    let displayKey: String

    var isValid: Bool {
        !NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .control, .option, .shift])
            .isEmpty
    }

    var displayString: String { modifierSymbols + displayKey }

    var modifierSymbols: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}
