//
//  GitHubCopilotAuthManager.swift
//  reprompter
//

import Foundation
import AppKit
import Observation
import OSLog

// MARK: - Auth Manager

@Observable
@MainActor
final class GitHubCopilotAuthManager {

    // Public client ID used by VS Code / first-party Copilot clients.
    // This is intentionally hardcoded — it carries no secret and is the same
    // value embedded in every Copilot extension build.
    static let clientID = "Iv1.b507a08c87ecfe98"

    enum State: Equatable {
        case disconnected
        case requestingCode
        case waitingForUser(userCode: String, verificationURL: URL, expiresAt: Date)
        case polling
        case connected
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.requestingCode, .requestingCode),
                 (.polling, .polling),
                 (.connected, .connected):
                return true
            case (.waitingForUser(let a, let b, _), .waitingForUser(let c, let d, _)):
                return a == c && b == d
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    struct CopilotModel: Decodable, Identifiable {
        let id: String
        let name: String?
        struct Capabilities: Decodable {
            let type: String?
        }
        let capabilities: Capabilities?
        var displayName: String { name ?? id }
        var isChatCapable: Bool { capabilities?.type == "chat" }
    }

    private(set) var state: State = .disconnected
    /// The GitHub login (username) shown after a successful sign-in.
    private(set) var connectedUsername: String?
    /// Chat-capable models fetched from the Copilot API.
    private(set) var availableModels: [CopilotModel] = []
    private(set) var isFetchingModels = false

    /// Called with the GitHub OAuth access token once authorization succeeds.
    var onTokenReceived: ((String) -> Void)?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.reprompter", category: "GitHubCopilotAuth")

    private var pollingTask: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Reprompter/1.0"]
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    func startDeviceFlow() async {
        pollingTask?.cancel()
        connectedUsername = nil
        state = .requestingCode

        do {
            let response = try await requestDeviceCode()
            guard let verificationURL = URL(string: response.verificationUri) else {
                state = .error("GitHub returned an invalid verification URL.")
                return
            }
            let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
            state = .waitingForUser(userCode: response.userCode,
                                    verificationURL: verificationURL,
                                    expiresAt: expiresAt)
            NSWorkspace.shared.open(verificationURL)
            startPolling(deviceCode: response.deviceCode, interval: response.interval)
        } catch {
            state = .error("Failed to start sign-in: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        connectedUsername = nil
        state = .disconnected
    }

    /// Called on launch when a persisted access token is found.
    func markAsConnected(username: String? = nil) {
        pollingTask?.cancel()
        pollingTask = nil
        connectedUsername = username
        state = .connected
    }

    // MARK: - Device Code Request

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard let deviceCodeURL = URL(string: "https://github.com/login/device/code") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(Self.clientID)&scope=read:user".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    // MARK: - Token Polling

    private func startPolling(deviceCode: String, interval: Int) {
        // State stays .waitingForUser so the code remains visible while we poll silently.
        pollingTask = Task { [weak self] in
            await self?.pollForToken(deviceCode: deviceCode, interval: interval)
        }
    }

    private struct TokenPollResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case interval
        }
    }

    private func pollForToken(deviceCode: String, interval: Int) async {
        var currentInterval = max(interval, 5)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(currentInterval))
            guard !Task.isCancelled else { return }

            do {
                guard let tokenURL = URL(string: "https://github.com/login/oauth/access_token") else {
                    state = .error("Internal error: invalid OAuth URL.")
                    return
                }
                var request = URLRequest(url: tokenURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let body = "client_id=\(Self.clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
                request.httpBody = body.data(using: .utf8)

                let (data, _) = try await session.data(for: request)
                let result = try JSONDecoder().decode(TokenPollResponse.self, from: data)

                if let token = result.accessToken, !token.isEmpty {
                    // Fetch username before marking connected (fire-and-wait; non-critical)
                    let username = try? await fetchGitHubUsername(token: token)
                    connectedUsername = username
                    state = .connected
                    onTokenReceived?(token)
                    return
                }

                switch result.error {
                case "authorization_pending":
                    continue // keep polling at same interval
                case "slow_down":
                    currentInterval += (result.interval ?? 5)
                case "expired_token":
                    state = .error("Authorization timed out. Please try again.")
                    return
                case "access_denied":
                    state = .error("Authorization was denied.")
                    return
                default:
                    if let errorMsg = result.error {
                        state = .error("Authorization failed: \(errorMsg)")
                        return
                    }
                }
            } catch {
                if Task.isCancelled { return }
                state = .error("Polling failed: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Model Fetching

    private struct CopilotSessionToken: Decodable {
        let token: String
    }

    private struct ModelsResponse: Decodable {
        let data: [CopilotModel]
    }

    /// Fetches the list of chat-capable models from the Copilot API.
    /// Silently fails — text field fallback remains available.
    func fetchModels(githubToken: String) async {
        guard !githubToken.isEmpty else { return }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            // Exchange GitHub token for a Copilot session token
            guard let sessionTokenURL = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
                throw AuthError.invalidURL
            }
            var tokenReq = URLRequest(url: sessionTokenURL)
            tokenReq.setValue("token \(githubToken)", forHTTPHeaderField: "Authorization")
            tokenReq.setValue("application/json", forHTTPHeaderField: "Accept")
            let (tokenData, tokenResp) = try await session.data(for: tokenReq)
            if let http = tokenResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Self.logger.error("fetchModels session-token HTTP \(http.statusCode)")
                throw AuthError.httpError(http.statusCode)
            }
            let sessionToken = try JSONDecoder().decode(CopilotSessionToken.self, from: tokenData).token

            // Fetch models list
            guard let modelsURL = URL(string: "https://api.githubcopilot.com/models") else {
                throw AuthError.invalidURL
            }
            var modelsReq = URLRequest(url: modelsURL)
            modelsReq.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            modelsReq.setValue("application/json", forHTTPHeaderField: "Accept")
            modelsReq.setValue("vscode-chat", forHTTPHeaderField: "copilot-integration-id")
            modelsReq.setValue("vscode/1.99.0", forHTTPHeaderField: "editor-version")
            modelsReq.setValue("copilot-chat/0.24.0", forHTTPHeaderField: "editor-plugin-version")
            modelsReq.setValue("GitHubCopilotChat/0.24.0", forHTTPHeaderField: "User-Agent")
            modelsReq.setValue("2025-04-01", forHTTPHeaderField: "x-github-api-version")
            let (modelsData, modelsResp) = try await session.data(for: modelsReq)
            if let http = modelsResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Self.logger.error("fetchModels /models HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: modelsData)
            var seen = Set<String>()
            availableModels = decoded.data
                .filter { $0.isChatCapable }
                .filter { seen.insert($0.id).inserted }
        } catch {
            Self.logger.error("fetchModels error: \(error)")
            availableModels = []
        }
    }

    // MARK: - GitHub Username

    private struct GitHubUser: Decodable {
        let login: String
    }

    private func fetchGitHubUsername(token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GitHubUser.self, from: data).login
    }

    // MARK: - Errors

    private enum AuthError: LocalizedError {
        case httpError(Int)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "HTTP \(code) from GitHub."
            case .invalidURL: return "Internal error: could not construct a valid URL."
            }
        }
    }
}
