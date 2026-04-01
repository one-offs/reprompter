//
//  RepromptServiceTests.swift
//  reprompterTests
//
//  Tests for RepromptService that do not require network access.
//  All tests exercise code paths that short-circuit before making HTTP calls:
//    - empty input guard
//    - missing-credentials / missing-API-key error paths
//

import Testing
@testable import reprompter

@Suite("RepromptService — no-network paths")
@MainActor
struct RepromptServiceNoNetworkTests {

    private let service = RepromptService()
    private let dummySystemPrompt = "You are a helpful assistant."

    // MARK: Empty input

    @Test("Empty string returns empty result without network call")
    func emptyInput_returnsEmptyResult() async {
        let result = await service.rewrite(
            "",
            provider: .openAI,
            providerCredentials: ProviderCredentials(apiKey: "sk-any", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "")
        #expect(result.message == nil)
    }

    @Test("Whitespace-only input returns empty result")
    func whitespaceInput_returnsEmptyResult() async {
        let result = await service.rewrite(
            "   \n\t  ",
            provider: .anthropic,
            providerCredentials: ProviderCredentials(apiKey: "sk-any", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "")
        #expect(result.message == nil)
    }

    // MARK: Missing API key (short-circuits before network)

    @Test("OpenAI with empty API key returns error message")
    func openAI_emptyKey_returnsMessage() async {
        let result = await service.rewrite(
            "Rewrite this prompt please.",
            provider: .openAI,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        // Text is preserved (original returned unchanged)
        #expect(result.text == "Rewrite this prompt please.")
        // A user-facing message is set
        #expect(result.message != nil)
    }

    @Test("Anthropic with empty API key returns error message")
    func anthropic_emptyKey_returnsMessage() async {
        let result = await service.rewrite(
            "Write a haiku about Swift.",
            provider: .anthropic,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "Write a haiku about Swift.")
        #expect(result.message != nil)
    }

    @Test("Google with empty API key returns error message")
    func google_emptyKey_returnsMessage() async {
        let result = await service.rewrite(
            "Summarize this text.",
            provider: .google,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "Summarize this text.")
        #expect(result.message != nil)
    }

    @Test("GitHub Copilot with empty token returns error message")
    func githubCopilot_emptyToken_returnsMessage() async {
        let result = await service.rewrite(
            "Improve my prompt.",
            provider: .githubCopilot,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "Improve my prompt.")
        #expect(result.message != nil)
    }

    @Test("Missing credentials (nil) returns error message for OpenAI")
    func openAI_nilCredentials_returnsMessage() async {
        let result = await service.rewrite(
            "Some prompt.",
            provider: .openAI,
            providerCredentials: nil,
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == "Some prompt.")
        #expect(result.message != nil)
    }

    // MARK: Original text is preserved on failure

    @Test("Original text is returned unchanged when credentials are missing")
    func originalTextPreserved_onMissingCredentials() async {
        let originalText = "This is my carefully crafted prompt with specific details."
        let result = await service.rewrite(
            originalText,
            provider: .anthropic,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        #expect(result.text == originalText)
    }

    @Test("Leading/trailing whitespace is trimmed from returned text on failure")
    func whitespaceIsTrimmedFromReturnedText() async {
        let result = await service.rewrite(
            "  trim me please  ",
            provider: .openAI,
            providerCredentials: ProviderCredentials(apiKey: "", baseURL: nil, modelName: nil),
            systemPrompt: dummySystemPrompt
        )
        // The service trims the input before returning it
        #expect(result.text == "trim me please")
    }
}

// MARK: - RepromptResult Tests

@Suite("RepromptResult")
struct RepromptResultTests {

    @Test("RepromptResult stores text and nil message")
    func initWithTextOnly() {
        let result = RepromptResult(text: "Hello world")
        #expect(result.text == "Hello world")
        #expect(result.message == nil)
        #expect(result.errorDetail == nil)
    }

    @Test("RepromptResult stores text, message, and errorDetail")
    func initWithAllFields() {
        let result = RepromptResult(
            text: "Original",
            message: "Rewrite failed",
            errorDetail: "HTTP 401"
        )
        #expect(result.text == "Original")
        #expect(result.message == "Rewrite failed")
        #expect(result.errorDetail == "HTTP 401")
    }
}

// MARK: - ConnectionTestResult Tests

@Suite("ConnectionTestResult")
struct ConnectionTestResultTests {

    @Test("ConnectionTestResult stores success state")
    func successResult() {
        let result = ConnectionTestResult(isSuccess: true, message: "Connection is working.")
        #expect(result.isSuccess == true)
        #expect(result.message == "Connection is working.")
        #expect(result.errorDetail == nil)
    }

    @Test("ConnectionTestResult stores failure state with detail")
    func failureResultWithDetail() {
        let result = ConnectionTestResult(
            isSuccess: false,
            message: "Authentication failed.",
            errorDetail: "HTTP 401\n{\"error\":\"Unauthorized\"}"
        )
        #expect(result.isSuccess == false)
        #expect(result.message == "Authentication failed.")
        #expect(result.errorDetail != nil)
    }
}
