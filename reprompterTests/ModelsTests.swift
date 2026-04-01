//
//  ModelsTests.swift
//  reprompterTests
//

import Testing
import AppKit
@testable import reprompter

// MARK: - HotkeyConfig Tests

@Suite("HotkeyConfig")
@MainActor
struct HotkeyConfigTests {

    // MARK: isValid

    @Test("isValid is true when command modifier is set")
    func isValid_commandModifier() {
        let config = HotkeyConfig(
            keyCode: 15,
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            displayKey: "R"
        )
        #expect(config.isValid == true)
    }

    @Test("isValid is true when shift+option modifiers are set")
    func isValid_shiftOptionModifiers() {
        let flags = NSEvent.ModifierFlags([.shift, .option])
        let config = HotkeyConfig(keyCode: 49, modifiers: flags.rawValue, displayKey: "Space")
        #expect(config.isValid == true)
    }

    @Test("isValid is false when no recognized modifiers are set")
    func isValid_noModifiers() {
        let config = HotkeyConfig(keyCode: 15, modifiers: 0, displayKey: "R")
        #expect(config.isValid == false)
    }

    // MARK: displayString

    @Test("displayString concatenates modifier symbols and key")
    func displayString_commandR() {
        let config = HotkeyConfig(
            keyCode: 15,
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            displayKey: "R"
        )
        #expect(config.displayString == "⌘R")
    }

    @Test("displayString includes all four modifier symbols in order")
    func displayString_allModifiers() {
        let flags = NSEvent.ModifierFlags([.control, .option, .shift, .command])
        let config = HotkeyConfig(keyCode: 15, modifiers: flags.rawValue, displayKey: "X")
        // Expected order: ⌃⌥⇧⌘
        #expect(config.displayString == "⌃⌥⇧⌘X")
    }

    @Test("displayString with shift+command")
    func displayString_shiftCommand() {
        let flags = NSEvent.ModifierFlags([.shift, .command])
        let config = HotkeyConfig(keyCode: 36, modifiers: flags.rawValue, displayKey: "↩")
        #expect(config.displayString == "⇧⌘↩")
    }

    // MARK: modifierSymbols

    @Test("modifierSymbols returns empty string for zero modifiers")
    func modifierSymbols_empty() {
        let config = HotkeyConfig(keyCode: 0, modifiers: 0, displayKey: "A")
        #expect(config.modifierSymbols == "")
    }

    @Test("modifierSymbols returns only command symbol")
    func modifierSymbols_commandOnly() {
        let config = HotkeyConfig(
            keyCode: 0,
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            displayKey: "A"
        )
        #expect(config.modifierSymbols == "⌘")
    }

    @Test("modifierSymbols returns only control symbol")
    func modifierSymbols_controlOnly() {
        let config = HotkeyConfig(
            keyCode: 0,
            modifiers: NSEvent.ModifierFlags.control.rawValue,
            displayKey: "A"
        )
        #expect(config.modifierSymbols == "⌃")
    }

    // MARK: Codable round-trip

    @Test("HotkeyConfig survives JSON encode/decode round-trip")
    func codable_roundTrip() throws {
        let original = HotkeyConfig(
            keyCode: 15,
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            displayKey: "R"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyConfig.self, from: data)

        #expect(decoded.keyCode == original.keyCode)
        #expect(decoded.modifiers == original.modifiers)
        #expect(decoded.displayKey == original.displayKey)
    }

    // MARK: Equatable

    @Test("Two HotkeyConfigs with same values are equal")
    func equatable_equal() {
        let a = HotkeyConfig(keyCode: 15, modifiers: 256, displayKey: "R")
        let b = HotkeyConfig(keyCode: 15, modifiers: 256, displayKey: "R")
        #expect(a == b)
    }

    @Test("HotkeyConfigs with different keyCode are not equal")
    func equatable_differentKeyCode() {
        let a = HotkeyConfig(keyCode: 15, modifiers: 256, displayKey: "R")
        let b = HotkeyConfig(keyCode: 16, modifiers: 256, displayKey: "R")
        #expect(a != b)
    }

    @Test("HotkeyConfigs with different modifiers are not equal")
    func equatable_differentModifiers() {
        let a = HotkeyConfig(keyCode: 15, modifiers: 256, displayKey: "R")
        let b = HotkeyConfig(keyCode: 15, modifiers: 512, displayKey: "R")
        #expect(a != b)
    }
}

// MARK: - ReprompterProvider Tests

@Suite("ReprompterProvider")
struct ReprompterProviderTests {

    @Test("allCases contains all six providers")
    func allCases_count() {
        #expect(ReprompterProvider.allCases.count == 6)
    }

    @Test("allCases contains expected providers")
    func allCases_contents() {
        let cases = ReprompterProvider.allCases
        #expect(cases.contains(.foundationModel))
        #expect(cases.contains(.openAI))
        #expect(cases.contains(.anthropic))
        #expect(cases.contains(.google))
        #expect(cases.contains(.githubCopilot))
        #expect(cases.contains(.ollama))
    }

    @Test("id property matches rawValue")
    func id_matchesRawValue() {
        for provider in ReprompterProvider.allCases {
            #expect(provider.id == provider.rawValue)
        }
    }

    @Test("rawValues are human-readable strings")
    func rawValues() {
        #expect(ReprompterProvider.openAI.rawValue == "OpenAI")
        #expect(ReprompterProvider.anthropic.rawValue == "Anthropic")
        #expect(ReprompterProvider.google.rawValue == "Google")
        #expect(ReprompterProvider.githubCopilot.rawValue == "GitHub Copilot")
        #expect(ReprompterProvider.ollama.rawValue == "Ollama")
        #expect(ReprompterProvider.foundationModel.rawValue == "Apple Foundation Model")
    }

    @Test("Initializing from rawValue succeeds for all providers")
    func initFromRawValue() {
        for provider in ReprompterProvider.allCases {
            let reconstructed = ReprompterProvider(rawValue: provider.rawValue)
            #expect(reconstructed == provider)
        }
    }

    @Test("Initializing from unknown rawValue returns nil")
    func initFromUnknownRawValue() {
        #expect(ReprompterProvider(rawValue: "Unknown Provider") == nil)
    }
}

// MARK: - ProviderCredentials Tests

@Suite("ProviderCredentials")
struct ProviderCredentialsTests {

    @Test("ProviderCredentials stores all properties")
    func properties() {
        let creds = ProviderCredentials(
            apiKey: "sk-test-123",
            baseURL: "https://api.example.com/v1",
            modelName: "gpt-4o"
        )
        #expect(creds.apiKey == "sk-test-123")
        #expect(creds.baseURL == "https://api.example.com/v1")
        #expect(creds.modelName == "gpt-4o")
    }

    @Test("ProviderCredentials allows nil baseURL and modelName")
    func nilOptionals() {
        let creds = ProviderCredentials(apiKey: "key", baseURL: nil, modelName: nil)
        #expect(creds.baseURL == nil)
        #expect(creds.modelName == nil)
    }
}
