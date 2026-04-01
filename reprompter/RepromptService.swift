//
//  RepromptService.swift
//  reprompter
//
//  Extracted service/provider/network logic from ContentView.swift.
//

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Reprompt Results

struct RepromptResult {
    let text: String
    let message: String?
    /// Raw HTTP response body / full error — for the "Advanced" detail view.
    let errorDetail: String?

    init(text: String, message: String? = nil, errorDetail: String? = nil) {
        self.text = text
        self.message = message
        self.errorDetail = errorDetail
    }
}

struct ConnectionTestResult {
    let isSuccess: Bool
    let message: String
    /// Raw HTTP response body / full error — for the "Advanced" detail view.
    let errorDetail: String?

    init(isSuccess: Bool, message: String, errorDetail: String? = nil) {
        self.isSuccess = isSuccess
        self.message = message
        self.errorDetail = errorDetail
    }
}

// MARK: - Provider Contracts

private protocol RepromptProviderClient {
    var provider: ReprompterProvider { get }
    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>?
}

private extension RepromptProviderClient {
    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        nil
    }
}

private enum RepromptClientError: Error {
    case missingCredentials
    case missingAPIKey
    case foundationModelUnavailable
    case foundationModelsUnsupportedOS
}

// MARK: - Provider Clients

private struct FoundationModelProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .foundationModel

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let systemModel = SystemLanguageModel.default
            guard case .available = systemModel.availability else {
                throw RepromptClientError.foundationModelUnavailable
            }

            let lmSession = LanguageModelSession(instructions: systemPrompt)
            let response = try await lmSession.respond(to: prompt)
            return response.content
        }
        throw RepromptClientError.foundationModelsUnsupportedOS
        #else
        throw RepromptClientError.foundationModelsUnsupportedOS
        #endif
    }
}

private struct OpenAIProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .openAI
    private static let defaultModel = "gpt-4o-mini"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.reprompter", category: "OpenAIProvider")

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }

        let endpointURL = ProviderNetworkTransport.openAIEndpoint(baseURL: credentials.baseURL)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let trimmedModelName = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedModelName.isEmpty ? Self.defaultModel : trimmedModelName

        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await ProviderNetworkTransport.fetchDataWithRetry(for: request, session: session)
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return decoded.choices.first?.message.content ?? ""
        } catch {
            Self.logger.error("OpenAI decode error: \(error)")
            throw error
        }
    }

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }

        let endpointURL = ProviderNetworkTransport.openAIEndpoint(baseURL: credentials.baseURL)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let trimmedModelNameForStream = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedModelNameForStream.isEmpty ? Self.defaultModel : trimmedModelNameForStream

        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let lineStream = ProviderNetworkTransport.streamSSEDataLines(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lineStream {
                        guard let chunk = line.data(using: .utf8) else { continue }
                        let decoded = try JSONDecoder().decode(OpenAIChatStreamChunk.self, from: chunk)
                        if let delta = decoded.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct AnthropicProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .anthropic
    private static let defaultModel = "claude-3-5-sonnet-latest"

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ProviderRequestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let trimmedAnthropicModel = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedAnthropicModel.isEmpty ? Self.defaultModel : trimmedAnthropicModel

        let payload = AnthropicMessagesRequest(
            model: model,
            max_tokens: 1024,
            temperature: 0.2,
            system: systemPrompt,
            messages: [.init(role: "user", content: prompt)],
            stream: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await ProviderNetworkTransport.fetchDataWithRetry(for: request, session: session)
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        return decoded.content
            .compactMap { $0.text }
            .joined(separator: "\n")
    }

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ProviderRequestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let trimmedAnthropicStreamModel = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedAnthropicStreamModel.isEmpty ? Self.defaultModel : trimmedAnthropicStreamModel

        let payload = AnthropicMessagesRequest(
            model: model,
            max_tokens: 1024,
            temperature: 0.2,
            system: systemPrompt,
            messages: [.init(role: "user", content: prompt)],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let lineStream = ProviderNetworkTransport.streamSSEDataLines(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lineStream {
                        guard let chunk = line.data(using: .utf8) else { continue }
                        if let decoded = try? JSONDecoder().decode(AnthropicStreamChunk.self, from: chunk),
                           decoded.type == "content_block_delta",
                           let text = decoded.delta?.text,
                           !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct GoogleProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .google
    private static let defaultModel = "gemini-2.0-flash-lite"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.reprompter", category: "GoogleProvider")

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }

        let trimmedGoogleModel = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedGoogleModel.isEmpty ? Self.defaultModel : trimmedGoogleModel
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw ProviderRequestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload = GoogleGenerateContentRequest(
            contents: [
                .init(role: "user", parts: [.init(text: prompt)])
            ],
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            generationConfig: .init(temperature: 0.2)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await ProviderNetworkTransport.fetchDataWithRetry(for: request, session: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("Google HTTP \(http.statusCode) for model=\(model, privacy: .public)")
        }
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(GoogleGenerateContentResponse.self, from: data)
        let parts = decoded.candidates.first?.content.parts ?? []
        return parts.compactMap(\.text).joined(separator: "\n")
    }

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        guard let credentials else { throw RepromptClientError.missingCredentials }
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw RepromptClientError.missingAPIKey }

        let trimmedGoogleStreamModel = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedGoogleStreamModel.isEmpty ? Self.defaultModel : trimmedGoogleStreamModel
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw ProviderRequestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload = GoogleGenerateContentRequest(
            contents: [
                .init(role: "user", parts: [.init(text: prompt)])
            ],
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            generationConfig: .init(temperature: 0.2)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let lineStream = ProviderNetworkTransport.streamSSEDataLines(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lineStream {
                        guard let chunk = line.data(using: .utf8) else { continue }
                        if let decoded = try? JSONDecoder().decode(GoogleGenerateContentResponse.self, from: chunk) {
                            let text = decoded.candidates.first?.content.parts.compactMap(\.text).joined(separator: "") ?? ""
                            if !text.isEmpty {
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - GitHub Copilot Provider

private final class GitHubCopilotProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .githubCopilot
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.reprompter", category: "GitHubCopilotProvider")

    // In-memory session token cache — avoids redundant exchange calls
    private var cachedSessionToken: String = ""
    private var sessionTokenExpiry: Date = .distantPast

    private struct CopilotSessionTokenResponse: Decodable {
        let token: String
        let expiresAt: Int  // Unix timestamp (seconds)

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    /// Returns a valid Copilot session token, serving from the in-memory cache
    /// when possible to avoid redundant exchange calls.
    ///
    /// GitHub Copilot uses a two-token system:
    /// 1. A long-lived **GitHub OAuth token** (stored in Keychain) that authorises the user.
    /// 2. A short-lived **session token** (typically valid ~1 hour) obtained by
    ///    exchanging the OAuth token at `api.github.com/copilot_internal/v2/token`.
    ///
    /// The session token is cached in `cachedSessionToken` / `sessionTokenExpiry`.
    /// A cached token is considered fresh if it has more than 60 seconds remaining,
    /// giving in-flight requests a comfortable window to complete before expiry.
    private func freshSessionToken(githubToken: String, session: URLSession) async throws -> String {
        if !cachedSessionToken.isEmpty, sessionTokenExpiry.timeIntervalSinceNow > 60 {
            return cachedSessionToken
        }
        guard let tokenURL = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
            throw ProviderRequestError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.setValue("token \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("Copilot session-token HTTP \(http.statusCode)")
        }
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        do {
            let decoded = try JSONDecoder().decode(CopilotSessionTokenResponse.self, from: data)
            cachedSessionToken = decoded.token
            sessionTokenExpiry = Date(timeIntervalSince1970: Double(decoded.expiresAt))
            return cachedSessionToken
        } catch {
            Self.logger.error("Copilot session-token decode error: \(error)")
            throw error
        }
    }

    private func copilotRequest(url: URL, sessionToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("vscode-chat", forHTTPHeaderField: "copilot-integration-id")
        request.setValue("vscode/1.99.0", forHTTPHeaderField: "editor-version")
        request.setValue("copilot-chat/0.24.0", forHTTPHeaderField: "editor-plugin-version")
        request.setValue("GitHubCopilotChat/0.24.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "x-github-api-version")
        request.timeoutInterval = 60
        return request
    }

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        let githubToken = credentials?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !githubToken.isEmpty else { throw RepromptClientError.missingAPIKey }
        let sessionToken = try await freshSessionToken(githubToken: githubToken, session: session)
        let model = credentials?.modelName ?? "gpt-4o"
        guard let copilotURL = URL(string: "https://api.githubcopilot.com/chat/completions") else {
            throw ProviderRequestError.invalidURL
        }
        var request = copilotRequest(url: copilotURL, sessionToken: sessionToken)
        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                OpenAIChatRequest.Message(role: "system", content: systemPrompt),
                OpenAIChatRequest.Message(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await ProviderNetworkTransport.fetchDataWithRetry(for: request, session: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logger.error("Copilot chat/completions HTTP \(http.statusCode)")
        }
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        let githubToken = credentials?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !githubToken.isEmpty else { throw RepromptClientError.missingAPIKey }
        let sessionToken = try await freshSessionToken(githubToken: githubToken, session: session)
        let model = credentials?.modelName ?? "gpt-4o"
        guard let copilotStreamURL = URL(string: "https://api.githubcopilot.com/chat/completions") else {
            throw ProviderRequestError.invalidURL
        }
        var request = copilotRequest(url: copilotStreamURL, sessionToken: sessionToken)
        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                OpenAIChatRequest.Message(role: "system", content: systemPrompt),
                OpenAIChatRequest.Message(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(payload)
        let dataStream = ProviderNetworkTransport.streamSSEDataLines(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in dataStream {
                        guard let chunk = try? JSONDecoder().decode(OpenAIChatStreamChunk.self,
                                                                     from: Data(line.utf8)),
                              let content = chunk.choices.first?.delta.content else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    Self.logger.error("Copilot stream error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Network Transport

private enum ProviderNetworkTransport {
    private static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private static let maxRetryAttempts = 2
    private static let baseRetryDelayNanoseconds: UInt64 = 400_000_000

    /// Fetches data for `request`, automatically retrying transient failures with
    /// exponential back-off.
    ///
    /// **Retry policy:**
    /// - Up to `maxRetryAttempts` retries (currently 2, giving 3 total attempts).
    /// - Retries on retryable HTTP status codes: 408, 429, 500, 502, 503, 504.
    /// - Retries on transient `URLError` codes: timeout, network connection lost,
    ///   not connected to internet, cannot find/connect to host, DNS lookup failed.
    /// - Delay uses exponential back-off starting at 400 ms
    ///   (attempt 1: 400 ms, attempt 2: 800 ms).
    /// - Checks `Task.isCancelled` before each attempt so cancellation stops the
    ///   retry loop immediately.
    static func fetchDataWithRetry(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        var attempt = 0

        while true {
            try Task.checkCancellation()
            do {
                let result = try await session.data(for: request)
                if shouldRetry(response: result.1), attempt < maxRetryAttempts {
                    attempt += 1
                    try await sleepForRetry(attempt: attempt)
                    continue
                }
                return result
            } catch {
                if shouldRetry(error: error), attempt < maxRetryAttempts {
                    attempt += 1
                    try await sleepForRetry(attempt: attempt)
                    continue
                }
                throw error
            }
        }
    }

    /// Returns an `AsyncThrowingStream` that yields the JSON payload string from
    /// each Server-Sent Events (SSE) `data:` line, filtering out control tokens.
    ///
    /// **SSE line parsing rules:**
    /// - Lines not prefixed with `"data:"` are skipped (e.g. `"event:"`, `"id:"`, blank lines).
    /// - The `"data:"` prefix and surrounding whitespace are stripped before yielding.
    /// - Lines whose payload equals `"[DONE]"` are skipped — this is the
    ///   stream-termination sentinel used by OpenAI-compatible APIs.
    ///
    /// **HTTP error handling:**
    /// If the server responds with a non-2xx status code the entire response body
    /// is drained before throwing `ProviderRequestError.httpStatus(_:_:)`, ensuring
    /// the JSON error message from the API is available to the caller.
    ///
    /// **Cancellation:**
    /// The underlying `URLSession` data task is cancelled when the stream's
    /// `onTermination` handler fires — this happens automatically if the consumer
    /// abandons the stream (e.g. the user cancels the rewrite mid-stream).
    static func streamSSEDataLines(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        // Collect the full error body before throwing
                        var bodyData = Data()
                        for try await byte in bytes { bodyData.append(byte) }
                        let body = String(data: bodyData, encoding: .utf8) ?? ""
                        throw ProviderRequestError.httpStatus(httpResponse.statusCode, body)
                    }

                    for try await rawLine in bytes.lines {
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func validateHTTP(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderRequestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderRequestError.httpStatus(httpResponse.statusCode, body)
        }
    }

    static func validateHTTPStatus(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderRequestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderRequestError.httpStatus(httpResponse.statusCode, "")
        }
    }

    // The default OpenAI chat completions endpoint. This literal is a compile-time
    // constant and is guaranteed to produce a valid URL — the force unwrap is intentional.
    static let defaultOpenAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    static func openAIEndpoint(baseURL: String?) -> URL {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return defaultOpenAIEndpoint
        }
        if trimmed.contains("/chat/completions"), let url = URL(string: trimmed) {
            return url
        }
        let cleaned = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        // Fall back to the default endpoint if the constructed URL is somehow invalid.
        return URL(string: "\(cleaned)/chat/completions") ?? defaultOpenAIEndpoint
    }

    private static func sleepForRetry(attempt: Int) async throws {
        let multiplier = UInt64(1 << (attempt - 1))
        let delay = baseRetryDelayNanoseconds * multiplier
        try await Task.sleep(nanoseconds: delay)
    }

    private static func shouldRetry(response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        return retryableHTTPStatusCodes.contains(httpResponse.statusCode)
    }

    private static func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Ollama Provider Client

private struct OllamaProviderClient: RepromptProviderClient {
    let provider: ReprompterProvider = .ollama

    func rewrite(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> String {
        guard let credentials, let model = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw RepromptClientError.missingCredentials
        }
        let base = credentials.baseURL ?? "http://localhost:11434"
        guard let url = URL(string: "\(base)/v1/chat/completions") else {
            throw ProviderRequestError.invalidURL
        }
        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: nil
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 120

        let (data, response) = try await ProviderNetworkTransport.fetchDataWithRetry(for: request, session: session)
        try ProviderNetworkTransport.validateHTTP(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    func rewriteStream(
        prompt: String,
        systemPrompt: String,
        credentials: ProviderCredentials?,
        session: URLSession
    ) async throws -> AsyncThrowingStream<String, Error>? {
        guard let credentials, let model = credentials.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw RepromptClientError.missingCredentials
        }
        let base = credentials.baseURL ?? "http://localhost:11434"
        guard let url = URL(string: "\(base)/v1/chat/completions") else {
            throw ProviderRequestError.invalidURL
        }
        let payload = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: true
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 120

        let lineStream = ProviderNetworkTransport.streamSSEDataLines(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lineStream {
                        guard let chunk = line.data(using: .utf8) else { continue }
                        let decoded = try JSONDecoder().decode(OpenAIChatStreamChunk.self, from: chunk)
                        if let delta = decoded.choices.first?.delta.content, !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Reprompt Service

struct RepromptService {
    private static let disallowedOutputPrefixes: [String] = [
        "prompt:",
        "rewritten prompt:",
        "revised prompt:",
        "output:"
    ]
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Reprompter",
        category: "RepromptService"
    )

    private let providerClients: [ReprompterProvider: any RepromptProviderClient] = [
        .foundationModel: FoundationModelProviderClient(),
        .openAI: OpenAIProviderClient(),
        .anthropic: AnthropicProviderClient(),
        .google: GoogleProviderClient(),
        .githubCopilot: GitHubCopilotProviderClient(),
        .ollama: OllamaProviderClient()
    ]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 75
        return URLSession(configuration: configuration)
    }()

    /// Rewrites `input` using the specified provider, returning a result that never throws.
    ///
    /// **Streaming flow** (all providers except Apple Foundation Models):
    /// 1. Calls `rewriteStream()` on the provider client. If it returns a non-nil
    ///    `AsyncThrowingStream`, chunks are accumulated and forwarded to
    ///    `onPartialOutput` as they arrive so the UI can update in real time.
    /// 2. If `rewriteStream()` returns `nil` (the provider opts out of streaming),
    ///    falls back to the non-streaming `rewrite()` path below.
    ///
    /// **Non-streaming flow** (Apple Foundation Models, and streaming fallback):
    /// 1. Calls `rewrite()` directly and waits for the complete response string.
    ///
    /// In both paths the final string is passed through `sanitizeModelOutput()`,
    /// which strips common LLM preamble prefixes (e.g. `"Rewritten prompt:"`).
    ///
    /// All errors are caught and converted into a `RepromptResult` with a non-nil
    /// `message` — this method never throws.
    ///
    /// - Parameters:
    ///   - input: The raw prompt text to rewrite.
    ///   - provider: The LLM backend to use.
    ///   - providerCredentials: Credentials for the selected provider (API key, model name, base URL).
    ///   - systemPrompt: The system prompt passed to the model.
    ///   - onPartialOutput: Called on an arbitrary thread with the accumulated
    ///     output so far during streaming. Not called for non-streaming providers.
    /// - Returns: A `RepromptResult` containing the final text on success, or an
    ///   error `message` (and optional `errorDetail`) on failure.
    func rewrite(
        _ input: String,
        provider: ReprompterProvider,
        providerCredentials: ProviderCredentials?,
        systemPrompt: String,
        onPartialOutput: (@Sendable (String) -> Void)? = nil
    ) async -> RepromptResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RepromptResult(text: "", message: nil)
        }

        let requestID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        debugLogStart(requestID: requestID, provider: provider)

        guard let client = providerClients[provider] else {
            debugLogStopFailure(
                requestID: requestID,
                provider: provider,
                startedAt: startedAt,
                errorClass: "missing_provider_client"
            )
            return RepromptResult(
                text: trimmed,
                message: "Rewrite failed"
            )
        }

        do {
            let output: String
            if provider != .foundationModel,
               let stream = try await client.rewriteStream(
                prompt: trimmed,
                systemPrompt: systemPrompt,
                credentials: providerCredentials,
                session: session
               ) {
                var combined = ""
                for try await chunk in stream {
                    combined += chunk
                    onPartialOutput?(combined)
                }
                output = combined
            } else {
                output = try await client.rewrite(
                    prompt: trimmed,
                    systemPrompt: systemPrompt,
                    credentials: providerCredentials,
                    session: session
                )
            }
            let sanitized = sanitizeModelOutput(output)
            guard !sanitized.isEmpty else {
                debugLogStopFailure(
                    requestID: requestID,
                    provider: provider,
                    startedAt: startedAt,
                    errorClass: "empty_output"
                )
                return RepromptResult(
                    text: trimmed,
                    message: "Rewrite failed"
                )
            }

            debugLogStopSuccess(
                requestID: requestID,
                provider: provider,
                startedAt: startedAt
            )
            return RepromptResult(text: sanitized, message: nil)
        } catch {
            if let clientError = error as? RepromptClientError {
                let (message, errorClass) = userMessageAndClass(for: clientError, provider: provider)
                debugLogStopFailure(
                    requestID: requestID,
                    provider: provider,
                    startedAt: startedAt,
                    errorClass: errorClass
                )
                return RepromptResult(text: trimmed, message: message)
            }

            let errorClass = classifyError(error)
            debugLogStopFailure(
                requestID: requestID,
                provider: provider,
                startedAt: startedAt,
                errorClass: errorClass
            )
            return RepromptResult(
                text: trimmed,
                message: "Rewrite failed",
                errorDetail: rawErrorDetail(for: error)
            )
        }
    }

    func testConnection(
        provider: ReprompterProvider,
        providerCredentials: ProviderCredentials?
    ) async -> ConnectionTestResult {
        let requestID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        #if DEBUG
        Self.logger.debug(
            "reprompt_test_start request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public)"
        )
        #endif

        guard let client = providerClients[provider] else {
            #if DEBUG
            Self.logger.debug(
                "reprompt_test_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=failure error_class=missing_provider_client elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)"
            )
            #endif
            return ConnectionTestResult(isSuccess: false, message: "Provider is not configured.")
        }

        do {
            _ = try await withTimeout(nanoseconds: 30_000_000_000) {
                try await client.rewrite(
                    prompt: "Connection test",
                    systemPrompt: "Reply with exactly OK.",
                    credentials: providerCredentials,
                    session: session
                )
            }
            #if DEBUG
            Self.logger.debug(
                "reprompt_test_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=success elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)"
            )
            #endif
            return ConnectionTestResult(isSuccess: true, message: "\(provider.rawValue) connection is working.")
        } catch {
            if let clientError = error as? RepromptClientError {
                let result: ConnectionTestResult
                switch clientError {
                case .missingCredentials, .missingAPIKey:
                    result = ConnectionTestResult(isSuccess: false, message: "Missing API key. Add it in Settings.")
                case .foundationModelUnavailable:
                    result = ConnectionTestResult(isSuccess: false, message: "Apple Intelligence isn’t available right now.")
                case .foundationModelsUnsupportedOS:
                    result = ConnectionTestResult(isSuccess: false, message: "Apple Foundation Model is unavailable on this macOS version.")
                }
                #if DEBUG
                Self.logger.debug(
                    "reprompt_test_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=failure error_class=\(String(describing: clientError), privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)"
                )
                #endif
                return result
            }

            let safeMessage = safeProviderErrorMessage(for: error)
            #if DEBUG
            Self.logger.debug(
                "reprompt_test_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=failure error_class=\(classifyError(error), privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)"
            )
            #endif
            return ConnectionTestResult(isSuccess: false, message: safeMessage, errorDetail: rawErrorDetail(for: error))
        }
    }

    private func withTimeout<T>(
        nanoseconds: UInt64,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func userMessageAndClass(
        for error: RepromptClientError,
        provider: ReprompterProvider
    ) -> (message: String, errorClass: String) {
        switch error {
        case .missingCredentials:
            return ("\(provider.rawValue) is selected. Add API key in Settings to enable rewrites.", "missing_credentials")
        case .missingAPIKey:
            return ("\(provider.rawValue) is selected. Add API key in Settings to enable rewrites.", "missing_api_key")
        case .foundationModelUnavailable:
            return ("Apple Intelligence isn’t available right now. Kept original text.", "foundation_model_unavailable")
        case .foundationModelsUnsupportedOS:
            return ("Foundation Models are unavailable on this macOS version. Kept original text.", "foundation_models_unavailable_os")
        }
    }

    private func sanitizeModelOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lowered = trimmed.lowercased()
        if let matchedPrefix = Self.disallowedOutputPrefixes.first(where: { lowered.hasPrefix($0) }) {
            let index = trimmed.index(trimmed.startIndex, offsetBy: matchedPrefix.count)
            return trimmed[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func safeProviderErrorMessage(for error: Error) -> String {
        if let providerError = error as? ProviderRequestError {
            switch providerError {
            case .invalidURL:
                return "Provider endpoint is invalid."
            case .invalidResponse:
                return "Provider returned an invalid response."
            case let .httpStatus(code, _):
                if code == 401 || code == 403 {
                    return "Authentication failed. Check your API key."
                }
                if code == 429 {
                    return "Rate limit reached. Try again shortly."
                }
                if (500...599).contains(code) {
                    return "Provider is temporarily unavailable (HTTP \(code))."
                }
                return "Provider request failed (HTTP \(code))."
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection."
            case .timedOut:
                return "Request timed out."
            case .networkConnectionLost:
                return "Network connection was lost."
            default:
                return "Network error occurred."
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection."
            case NSURLErrorTimedOut:
                return "Request timed out."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost."
            default:
                return "Network error occurred."
            }
        }

        return "An unexpected error occurred."
    }

    /// Returns a detail string for any error, for display in the ⓘ popover / Advanced detail view.
    private func rawErrorDetail(for error: Error) -> String? {
        if let providerError = error as? ProviderRequestError {
            switch providerError {
            case let .httpStatus(code, body) where !body.isEmpty:
                return "HTTP \(code)\n\(body)"
            case let .httpStatus(code, _):
                return "HTTP \(code)"
            default:
                break
            }
        }
        // Fall back to the error's own description for all other types
        // (DecodingError, URLError, etc.)
        let desc = error.localizedDescription
        return desc.isEmpty ? nil : desc
    }

    private func classifyError(_ error: Error) -> String {
        if let providerError = error as? ProviderRequestError {
            switch providerError {
            case .invalidURL:
                return "provider_invalid_url"
            case .invalidResponse:
                return "provider_invalid_response"
            case let .httpStatus(statusCode, _):
                return "provider_http_\(statusCode)"
            }
        }

        if let urlError = error as? URLError {
            return "url_error_\(urlError.code.rawValue)"
        }

        return String(describing: type(of: error))
    }

    private func debugLogStart(requestID: String, provider: ReprompterProvider) {
        #if DEBUG
        Self.logger.debug(
            "reprompt_start request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public)"
        )
        #endif
    }

    private func debugLogStopSuccess(requestID: String, provider: ReprompterProvider, startedAt: Date) {
        #if DEBUG
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        Self.logger.debug(
            "reprompt_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=success elapsed_ms=\(elapsedMs, privacy: .public)"
        )
        #endif
    }

    private func debugLogStopFailure(
        requestID: String,
        provider: ReprompterProvider,
        startedAt: Date,
        errorClass: String
    ) {
        #if DEBUG
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        Self.logger.debug(
            "reprompt_stop request_id=\(requestID, privacy: .public) provider=\(provider.rawValue, privacy: .public) result=failure error_class=\(errorClass, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public)"
        )
        #endif
    }
}

// MARK: - Provider Errors

private enum ProviderRequestError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid provider URL."
        case .invalidResponse:
            return "Invalid provider response."
        case let .httpStatus(code, _):
            return "HTTP \(code)"
        }
    }
}

// MARK: - Provider DTOs

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool?

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(stream, forKey: .stream)
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct OpenAIChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct AnthropicMessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let max_tokens: Int
    let temperature: Double
    let system: String
    let messages: [Message]
    let stream: Bool?

    private enum CodingKeys: String, CodingKey {
        case model, max_tokens, temperature, system, messages, stream
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(max_tokens, forKey: .max_tokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(system, forKey: .system)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(stream, forKey: .stream)
    }
}

private struct AnthropicMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}

private struct AnthropicStreamChunk: Decodable {
    struct Delta: Decodable {
        let text: String?
    }
    let type: String
    let delta: Delta?
}

private struct GoogleGenerateContentRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let role: String
        let parts: [Part]
    }

    struct SystemInstruction: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
    }

    let contents: [Content]
    let systemInstruction: SystemInstruction
    let generationConfig: GenerationConfig
}

private struct GoogleGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}
