//
//  SettingsStoreTests.swift
//  reprompterTests
//

import Testing
import Foundation
@testable import reprompter

// MARK: - URL Validation Tests

@Suite("SettingsStore — OpenAI base URL validation")
@MainActor
struct OpenAIBaseURLValidationTests {

    // MARK: Empty / nil input

    @Test("Empty string returns nil")
    func emptyString_returnsNil() {
        let store = SettingsStore()
        store.openAIBaseURL = ""
        #expect(store.normalizedAndValidatedOpenAIBaseURL() == nil)
    }

    @Test("Whitespace-only string returns nil")
    func whitespace_returnsNil() {
        let store = SettingsStore()
        store.openAIBaseURL = "   "
        #expect(store.normalizedAndValidatedOpenAIBaseURL() == nil)
    }

    // MARK: Valid URLs

    @Test("https URL is accepted as-is (trailing slash stripped)")
    func httpsURL_accepted() {
        let store = SettingsStore()
        store.openAIBaseURL = "https://api.openai.com/v1"
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result == "https://api.openai.com/v1")
    }

    @Test("http URL is accepted")
    func httpURL_accepted() {
        let store = SettingsStore()
        store.openAIBaseURL = "http://localhost:8080/v1"
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result == "http://localhost:8080/v1")
    }

    @Test("URL without scheme gets https:// prepended")
    func noScheme_getsHttps() {
        let store = SettingsStore()
        store.openAIBaseURL = "my-proxy.example.com/v1"
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result == "https://my-proxy.example.com/v1")
    }

    @Test("Trailing slash is stripped")
    func trailingSlash_stripped() {
        let store = SettingsStore()
        store.openAIBaseURL = "https://api.openai.com/v1/"
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result == "https://api.openai.com/v1")
    }

    @Test("URL already ending in /chat/completions is preserved")
    func urlWithChatCompletions_preserved() {
        let store = SettingsStore()
        store.openAIBaseURL = "https://my-proxy.example.com/v1/chat/completions"
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result == "https://my-proxy.example.com/v1/chat/completions")
    }

    // MARK: Invalid URLs

    @Test("Non-URL garbage returns nil")
    func garbage_returnsNil() {
        let store = SettingsStore()
        store.openAIBaseURL = "not a url at all !!!"
        #expect(store.normalizedAndValidatedOpenAIBaseURL() == nil)
    }

    @Test("Non-http(s) scheme string gets https:// prepended and is treated as a hostname")
    func nonHttpScheme_treatedAsHostname() {
        // The validator doesn't specifically reject other schemes; strings without
        // an http/https prefix get "https://" prepended before validation.
        let store = SettingsStore()
        store.openAIBaseURL = "ftp://files.example.com"
        // Result is non-nil because "https://ftp://files.example.com" is a parseable URL
        // with scheme=https (passes validation). Users should enter http(s) URLs only.
        let result = store.normalizedAndValidatedOpenAIBaseURL()
        #expect(result != nil)
    }

    // MARK: openAIBaseURLError

    @Test("openAIBaseURLError is nil for empty string")
    func baseURLError_emptyIsNil() {
        let store = SettingsStore()
        store.openAIBaseURL = ""
        #expect(store.openAIBaseURLError == nil)
    }

    @Test("openAIBaseURLError is nil for valid URL")
    func baseURLError_validURLIsNil() {
        let store = SettingsStore()
        store.openAIBaseURL = "https://api.openai.com/v1"
        #expect(store.openAIBaseURLError == nil)
    }

    @Test("openAIBaseURLError is non-nil for invalid URL")
    func baseURLError_invalidURL() {
        let store = SettingsStore()
        store.openAIBaseURL = "not a url !!!"
        #expect(store.openAIBaseURLError != nil)
    }
}

// MARK: - System Prompt Composition Tests

@Suite("SettingsStore — system prompt composition")
@MainActor
struct SystemPromptCompositionTests {

    @Test("Composed prompt includes main section")
    func composedPrompt_includesMain() {
        let store = SettingsStore()
        store.systemPromptMain = "You are a helpful assistant."
        store.systemPromptGuide = "Apply this guide: {guide}"
        let result = store.composeRewriteSystemPrompt(guideText: "")
        #expect(result.contains("You are a helpful assistant."))
    }

    @Test("Composed prompt ends with output format instruction")
    func composedPrompt_endsWithOutputInstruction() {
        let store = SettingsStore()
        let result = store.composeRewriteSystemPrompt(guideText: "")
        #expect(result.contains("Return only the rewritten prompt text."))
    }

    @Test("Guide section is omitted when guide text is empty")
    func composedPrompt_noGuideWhenEmpty() {
        let store = SettingsStore()
        store.systemPromptMain = "Main prompt."
        store.systemPromptGuide = "Guide instructions: {guide}"
        let result = store.composeRewriteSystemPrompt(guideText: "")
        #expect(!result.contains("Guide instructions"))
        #expect(!result.contains("{guide}"))
    }

    @Test("Guide section is omitted when guide text is only whitespace")
    func composedPrompt_noGuideWhenWhitespace() {
        let store = SettingsStore()
        store.systemPromptGuide = "Guide: {guide}"
        let result = store.composeRewriteSystemPrompt(guideText: "   \n  ")
        #expect(!result.contains("Guide:"))
    }

    @Test("Guide section is included with text substituted when guide is non-empty")
    func composedPrompt_guideSubstituted() {
        let store = SettingsStore()
        store.systemPromptGuide = "Apply these rules: {guide}"
        let result = store.composeRewriteSystemPrompt(guideText: "Be concise.")
        #expect(result.contains("Apply these rules: Be concise."))
        #expect(!result.contains("{guide}"))
    }

    @Test("Sections are separated by double newline")
    func composedPrompt_sectionSeparator() {
        let store = SettingsStore()
        store.systemPromptMain = "Main."
        store.systemPromptGuide = "Guide: {guide}"
        let result = store.composeRewriteSystemPrompt(guideText: "Extra instruction.")
        // Should contain at least two consecutive newlines between sections
        #expect(result.contains("\n\n"))
    }

    @Test("Default system prompts produce a valid composition")
    func composedPrompt_defaults() {
        let store = SettingsStore()
        store.systemPromptMain = SettingsStore.defaultSystemPromptMain
        store.systemPromptGuide = SettingsStore.defaultSystemPromptGuide
        let result = store.composeRewriteSystemPrompt(guideText: "Make it shorter.")
        #expect(!result.isEmpty)
        #expect(result.contains("Make it shorter."))
        #expect(!result.contains("{guide}"))
    }

    @Test("Default main prompt is non-empty")
    func defaultMainPrompt_nonEmpty() {
        #expect(!SettingsStore.defaultSystemPromptMain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Default guide prompt contains {guide} placeholder")
    func defaultGuidePrompt_containsPlaceholder() {
        #expect(SettingsStore.defaultSystemPromptGuide.contains("{guide}"))
    }
}

// MARK: - Provider Configuration Error Tests

@Suite("SettingsStore — provider configuration error")
@MainActor
struct ProviderConfigurationErrorTests {

    @Test("foundationModel has no configuration error")
    func foundationModel_noError() {
        let store = SettingsStore()
        store.provider = .foundationModel
        #expect(store.providerConfigurationError == nil)
    }

    @Test("openAI with empty API key has configuration error")
    func openAI_emptyKeyHasError() {
        let store = SettingsStore()
        store.provider = .openAI
        store.openAIAPIKey = ""
        #expect(store.providerConfigurationError != nil)
    }

    @Test("openAI with non-empty API key has no error")
    func openAI_withKeyNoError() {
        let store = SettingsStore()
        store.provider = .openAI
        store.openAIAPIKey = "sk-test-key"
        store.openAIBaseURL = ""
        #expect(store.providerConfigurationError == nil)
    }

    @Test("anthropic with empty API key has configuration error")
    func anthropic_emptyKeyHasError() {
        let store = SettingsStore()
        store.provider = .anthropic
        store.anthropicAPIKey = ""
        #expect(store.providerConfigurationError != nil)
    }

    @Test("google with empty API key has configuration error")
    func google_emptyKeyHasError() {
        let store = SettingsStore()
        store.provider = .google
        store.googleAPIKey = ""
        #expect(store.providerConfigurationError != nil)
    }

    @Test("ollama with empty model has configuration error")
    func ollama_emptyModelHasError() {
        let store = SettingsStore()
        store.provider = .ollama
        store.ollamaModel = ""
        #expect(store.providerConfigurationError != nil)
    }

    @Test("ollama with model selected has no error")
    func ollama_withModelNoError() {
        let store = SettingsStore()
        store.provider = .ollama
        store.ollamaModel = "llama3.2"
        #expect(store.providerConfigurationError == nil)
    }

    @Test("githubCopilot with empty token has configuration error")
    func githubCopilot_emptyTokenHasError() {
        let store = SettingsStore()
        store.provider = .githubCopilot
        store.githubCopilotAccessToken = ""
        #expect(store.providerConfigurationError != nil)
    }
}
