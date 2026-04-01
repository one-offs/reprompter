//
//  SettingsStore.swift
//  reprompter
//

import Foundation

// MARK: - Centralized Defaults Keys

enum DefaultsKey {
    static let provider = "Reprompter.Provider"
    static let useKeychainStorage = "Reprompter.UseKeychainStorage"
    static let guideEnabled = "Reprompter.GuideEnabled"
    static let openAIAPIKey = "Reprompter.Provider.OpenAI.APIKey"
    static let openAIBaseURL = "Reprompter.Provider.OpenAI.BaseURL"
    static let openAIModel = "Reprompter.Provider.OpenAI.Model"
    static let anthropicAPIKey = "Reprompter.Provider.Anthropic.APIKey"
    static let anthropicModel = "Reprompter.Provider.Anthropic.Model"
    static let googleAPIKey = "Reprompter.Provider.Google.APIKey"
    static let googleModel = "Reprompter.Provider.Google.Model"
    static let githubCopilotAccessToken = "Reprompter.Provider.GitHubCopilot.AccessToken"
    static let githubCopilotModel = "Reprompter.Provider.GitHubCopilot.Model"
    static let ollamaBaseURL = "Reprompter.Provider.Ollama.BaseURL"
    static let ollamaModel   = "Reprompter.Provider.Ollama.Model"
    static let systemPromptMain = "Reprompter.SystemPrompt.Main"
    static let systemPromptGuide = "Reprompter.SystemPrompt.Guide"
    static let panelFrame = "Reprompter.PanelFrame"
    static let panelScreen = "Reprompter.PanelScreen"
    static let hotkeyConfig = "Reprompter.HotkeyConfig"
    static let isHotkeyEnabled = "Reprompter.IsHotkeyEnabled"
}

// MARK: - Keychain Accounts

private enum KeychainAccount {
    static let openAIAPIKey = "provider.openai.apiKey"
    static let anthropicAPIKey = "provider.anthropic.apiKey"
    static let googleAPIKey = "provider.google.apiKey"
    static let githubCopilotAccessToken = "provider.githubcopilot.accessToken"
}

struct AnthropicModelInfo: Identifiable {
    let id: String
    let displayName: String
}

// MARK: - Settings Store

@Observable
final class SettingsStore {

    // MARK: Provider

    var provider: ReprompterProvider = .foundationModel {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: DefaultsKey.provider)
            onProviderOrModelChanged?()
        }
    }

    var useKeychainStorage = false {
        didSet {
            UserDefaults.standard.set(useKeychainStorage, forKey: DefaultsKey.useKeychainStorage)
            migrateAPIKeys(toKeychain: useKeychainStorage)
        }
    }

    var isGuideEnabled = false {
        didSet { UserDefaults.standard.set(isGuideEnabled, forKey: DefaultsKey.guideEnabled) }
    }

    // MARK: API Keys & Models

    var openAIAPIKey: String = "" {
        didSet { saveAPIKey(openAIAPIKey, account: KeychainAccount.openAIAPIKey, defaultsKey: DefaultsKey.openAIAPIKey) }
    }

    var openAIBaseURL: String = "" {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: DefaultsKey.openAIBaseURL) }
    }

    var openAIModel: String = "" {
        didSet { UserDefaults.standard.set(openAIModel, forKey: DefaultsKey.openAIModel); onProviderOrModelChanged?() }
    }

    private(set) var openAIAvailableModels: [String] = []
    private(set) var isFetchingOpenAIModels = false

    func fetchOpenAIModels() async {
        let apiKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { openAIAvailableModels = []; return }
        isFetchingOpenAIModels = true
        defer { isFetchingOpenAIModels = false }
        do {
            // Build /models URL relative to the configured base
            let base = normalizedAndValidatedOpenAIBaseURL() ?? "https://api.openai.com/v1"
            let apiBase = base.hasSuffix("/chat/completions")
                ? String(base.dropLast("/chat/completions".count))
                : base
            guard let url = URL(string: "\(apiBase)/models") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                openAIAvailableModels = []; return
            }
            struct ModelsResponse: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            // Keep only text/chat generation models; exclude embeddings, audio, image, moderation, and legacy completions
            let excluded = ["embedding", "embed", "whisper", "tts", "dall-e", "gpt-image",
                            "moderation", "realtime", "audio", "babbage", "davinci", "-instruct"]
            openAIAvailableModels = decoded.data
                .map { $0.id }
                .filter { id in !excluded.contains(where: { id.contains($0) }) }
                .sorted()
        } catch {
            openAIAvailableModels = []
        }
    }

    var anthropicAPIKey: String = "" {
        didSet { saveAPIKey(anthropicAPIKey, account: KeychainAccount.anthropicAPIKey, defaultsKey: DefaultsKey.anthropicAPIKey) }
    }

    var anthropicModel: String = "" {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: DefaultsKey.anthropicModel); onProviderOrModelChanged?() }
    }

    private(set) var anthropicAvailableModels: [AnthropicModelInfo] = []
    private(set) var isFetchingAnthropicModels = false

    func fetchAnthropicModels() async {
        let apiKey = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { anthropicAvailableModels = []; return }
        isFetchingAnthropicModels = true
        defer { isFetchingAnthropicModels = false }
        do {
            guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000") else { return }
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                anthropicAvailableModels = []; return
            }
            struct ModelsResponse: Decodable {
                struct Model: Decodable {
                    let id: String
                    let displayName: String
                    enum CodingKeys: String, CodingKey {
                        case id
                        case displayName = "display_name"
                    }
                }
                let data: [Model]
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            anthropicAvailableModels = decoded.data.map { AnthropicModelInfo(id: $0.id, displayName: $0.displayName) }
        } catch {
            anthropicAvailableModels = []
        }
    }

    var googleAPIKey: String = "" {
        didSet { saveAPIKey(googleAPIKey, account: KeychainAccount.googleAPIKey, defaultsKey: DefaultsKey.googleAPIKey) }
    }

    var googleModel: String = "" {
        didSet { UserDefaults.standard.set(googleModel, forKey: DefaultsKey.googleModel); onProviderOrModelChanged?() }
    }

    private(set) var googleAvailableModels: [String] = []
    private(set) var isFetchingGoogleModels = false

    func fetchGoogleModels() async {
        let apiKey = googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { googleAvailableModels = []; return }
        isFetchingGoogleModels = true
        defer { isFetchingGoogleModels = false }
        do {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                googleAvailableModels = []; return
            }
            struct ModelsResponse: Decodable {
                struct Model: Decodable {
                    let name: String                            // e.g. "models/gemini-2.0-flash"
                    let supportedGenerationMethods: [String]
                }
                let models: [Model]
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            googleAvailableModels = decoded.models
                .filter { $0.supportedGenerationMethods.contains("generateContent") }
                .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst("models/".count)) : $0.name }
                .sorted()
        } catch {
            googleAvailableModels = []
        }
    }

    // MARK: GitHub Copilot

    var githubCopilotAccessToken: String = "" {
        didSet { saveAPIKey(githubCopilotAccessToken, account: KeychainAccount.githubCopilotAccessToken, defaultsKey: DefaultsKey.githubCopilotAccessToken) }
    }

    var githubCopilotModel: String = "" {
        didSet { UserDefaults.standard.set(githubCopilotModel, forKey: DefaultsKey.githubCopilotModel); onProviderOrModelChanged?() }
    }

    let authManager = GitHubCopilotAuthManager()

    // MARK: Ollama

    var ollamaBaseURL: String = "http://localhost:11434" {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: DefaultsKey.ollamaBaseURL) }
    }

    var ollamaModel: String = "" {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: DefaultsKey.ollamaModel); onProviderOrModelChanged?() }
    }

    private(set) var ollamaAvailableModels: [String] = []
    private(set) var isFetchingOllamaModels = false

    func fetchOllamaModels() async {
        let base = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: "\(base)/api/tags") else {
            ollamaAvailableModels = []; return
        }
        isFetchingOllamaModels = true
        defer { isFetchingOllamaModels = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                ollamaAvailableModels = []; return
            }
            struct TagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            ollamaAvailableModels = decoded.models.map(\.name).sorted()
        } catch {
            ollamaAvailableModels = []
        }
    }

    // MARK: System Prompts

    var systemPromptMain: String = SettingsStore.defaultSystemPromptMain {
        didSet { UserDefaults.standard.set(systemPromptMain, forKey: DefaultsKey.systemPromptMain) }
    }

    var systemPromptGuide: String = SettingsStore.defaultSystemPromptGuide {
        didSet { UserDefaults.standard.set(systemPromptGuide, forKey: DefaultsKey.systemPromptGuide) }
    }

    static let defaultSystemPromptMain = """
    You rewrite rough user text into a clean AI-ready prompt.
    Keep intent intact. Improve clarity, constraints, and output format.
    """

    static let defaultSystemPromptGuide = """
    Apply these additional rewriting instructions from the user:
    {guide}
    """

    // MARK: Window Behavior

    var isFloatingOnTop = true {
        didSet { onWindowBehaviorChanged?() }
    }

    var isTranslucent = false {
        didSet { onWindowBehaviorChanged?() }
    }

    /// Called by PanelController to react to float/translucent changes.
    var onWindowBehaviorChanged: (() -> Void)?

    /// Called by PanelController to clear stale connection-test results when provider or model changes.
    var onProviderOrModelChanged: (() -> Void)?

    // MARK: Hotkey

    var isHotkeyEnabled = false {
        didSet {
            UserDefaults.standard.set(isHotkeyEnabled, forKey: DefaultsKey.isHotkeyEnabled)
            onHotkeyChanged?()
        }
    }

    var hotkeyConfig: HotkeyConfig? = nil {
        didSet {
            if let config = hotkeyConfig,
               let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.hotkeyConfig)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.hotkeyConfig)
            }
            onHotkeyChanged?()
        }
    }

    /// Called by PanelController to re-register the global monitor on changes.
    var onHotkeyChanged: (() -> Void)?

    // MARK: Init

    init() {
        authManager.onTokenReceived = { [weak self] token in
            self?.githubCopilotAccessToken = token
            Task { [weak self] in
                await self?.authManager.fetchModels(githubToken: token)
            }
        }
        loadSettings()
        // Fetch models on launch if already authenticated
        if !githubCopilotAccessToken.isEmpty {
            let token = githubCopilotAccessToken
            Task { [weak self] in
                await self?.authManager.fetchModels(githubToken: token)
            }
        }
    }

    // MARK: - Provider Validation

    var providerConfigurationError: String? {
        switch provider {
        case .foundationModel:
            return nil

        case .openAI:
            if openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenAI is selected. Add an API key in Settings."
            }
            if !openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                normalizedAndValidatedOpenAIBaseURL() == nil {
                return "OpenAI Base URL is invalid. Use a valid http(s) URL."
            }
            return nil

        case .anthropic:
            return anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Anthropic is selected. Add an API key in Settings."
                : nil

        case .google:
            return googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Google is selected. Add an API key in Settings."
                : nil

        case .githubCopilot:
            return githubCopilotAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "GitHub Copilot: Sign in with GitHub in Settings."
                : nil

        case .ollama:
            return ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Ollama: Select a model in Settings."
                : nil
        }
    }

    // MARK: - Credentials

    func credentialsForSelectedProvider() -> ProviderCredentials? {
        switch provider {
        case .foundationModel:
            return nil
        case .openAI:
            return ProviderCredentials(
                apiKey: openAIAPIKey,
                baseURL: normalizedAndValidatedOpenAIBaseURL(),
                modelName: openAIModel.isEmpty ? nil : openAIModel
            )
        case .anthropic:
            return ProviderCredentials(
                apiKey: anthropicAPIKey,
                baseURL: nil,
                modelName: anthropicModel.isEmpty ? nil : anthropicModel
            )
        case .google:
            return ProviderCredentials(
                apiKey: googleAPIKey,
                baseURL: nil,
                modelName: googleModel.isEmpty ? nil : googleModel
            )
        case .githubCopilot:
            return ProviderCredentials(
                apiKey: githubCopilotAccessToken,
                baseURL: nil,
                modelName: githubCopilotModel.isEmpty ? nil : githubCopilotModel
            )
        case .ollama:
            return ProviderCredentials(
                apiKey: "",
                baseURL: ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "http://localhost:11434"
                    : ollamaBaseURL,
                modelName: ollamaModel.isEmpty ? nil : ollamaModel
            )
        }
    }

    // MARK: - System Prompt Composition

    func composeRewriteSystemPrompt(guideText: String) -> String {
        let trimmedGuide = guideText.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []

        sections.append(systemPromptMain.trimmingCharacters(in: .whitespacesAndNewlines))

        if !trimmedGuide.isEmpty {
            let guideSection = systemPromptGuide
                .replacingOccurrences(of: "{guide}", with: trimmedGuide)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !guideSection.isEmpty {
                sections.append(guideSection)
            }
        }

        sections.append("Return only the rewritten prompt text. Do not add labels or prefixes such as \"Prompt:\", \"Rewritten Prompt:\", or \"Output:\".")
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - URL Validation

    /// Non-nil when the user has entered a non-empty Base URL that fails validation.
    /// Used for inline feedback in Settings; does not affect providerConfigurationError.
    var openAIBaseURLError: String? {
        let trimmed = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedAndValidatedOpenAIBaseURL() == nil
            ? "Enter a valid http or https URL, e.g. https://my-proxy.example.com/v1"
            : nil
    }

    func normalizedAndValidatedOpenAIBaseURL() -> String? {
        let trimmed = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }

        if candidate.hasSuffix("/chat/completions") {
            return candidate
        }
        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Persistence

    private func loadSettings() {
        if UserDefaults.standard.object(forKey: DefaultsKey.useKeychainStorage) != nil {
            useKeychainStorage = UserDefaults.standard.bool(forKey: DefaultsKey.useKeychainStorage)
        }
        if UserDefaults.standard.object(forKey: DefaultsKey.guideEnabled) != nil {
            isGuideEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.guideEnabled)
        }

        if let providerRawValue = UserDefaults.standard.string(forKey: DefaultsKey.provider),
           let savedProvider = ReprompterProvider(rawValue: providerRawValue) {
            provider = savedProvider
        }

        openAIAPIKey = loadAPIKey(account: KeychainAccount.openAIAPIKey, defaultsKey: DefaultsKey.openAIAPIKey)
        openAIBaseURL = UserDefaults.standard.string(forKey: DefaultsKey.openAIBaseURL) ?? ""
        openAIModel = UserDefaults.standard.string(forKey: DefaultsKey.openAIModel) ?? ""
        anthropicAPIKey = loadAPIKey(account: KeychainAccount.anthropicAPIKey, defaultsKey: DefaultsKey.anthropicAPIKey)
        anthropicModel = UserDefaults.standard.string(forKey: DefaultsKey.anthropicModel) ?? ""
        googleAPIKey = loadAPIKey(account: KeychainAccount.googleAPIKey, defaultsKey: DefaultsKey.googleAPIKey)
        googleModel = UserDefaults.standard.string(forKey: DefaultsKey.googleModel) ?? ""
        githubCopilotAccessToken = loadAPIKey(account: KeychainAccount.githubCopilotAccessToken,
                                              defaultsKey: DefaultsKey.githubCopilotAccessToken)
        githubCopilotModel = UserDefaults.standard.string(forKey: DefaultsKey.githubCopilotModel) ?? ""
        if !githubCopilotAccessToken.isEmpty { authManager.markAsConnected() }
        ollamaBaseURL = UserDefaults.standard.string(forKey: DefaultsKey.ollamaBaseURL) ?? "http://localhost:11434"
        ollamaModel   = UserDefaults.standard.string(forKey: DefaultsKey.ollamaModel) ?? ""

        if let savedMain = UserDefaults.standard.string(forKey: DefaultsKey.systemPromptMain),
           !savedMain.isEmpty {
            systemPromptMain = savedMain
        }

        if let savedGuide = UserDefaults.standard.string(forKey: DefaultsKey.systemPromptGuide),
           !savedGuide.isEmpty {
            systemPromptGuide = savedGuide
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.isHotkeyEnabled) != nil {
            isHotkeyEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.isHotkeyEnabled)
        }
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.hotkeyConfig),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            hotkeyConfig = config
        }
    }

    private func loadAPIKey(account: String, defaultsKey: String) -> String {
        if useKeychainStorage {
            if let value = KeychainStore.load(account: account) {
                return value
            }
            let fallback = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            if !fallback.isEmpty {
                KeychainStore.save(fallback, account: account)
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            return fallback
        } else {
            let value = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            if !value.isEmpty { return value }
            if let keychainValue = KeychainStore.load(account: account) {
                UserDefaults.standard.set(keychainValue, forKey: defaultsKey)
                KeychainStore.delete(account: account)
                return keychainValue
            }
            return ""
        }
    }

    private func saveAPIKey(_ value: String, account: String, defaultsKey: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if useKeychainStorage {
            if trimmed.isEmpty {
                KeychainStore.delete(account: account)
            } else {
                KeychainStore.save(value, account: account)
            }
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(value, forKey: defaultsKey)
            }
            KeychainStore.delete(account: account)
        }
    }

    private func migrateAPIKeys(toKeychain: Bool) {
        let keys: [(account: String, defaultsKey: String)] = [
            (KeychainAccount.openAIAPIKey, DefaultsKey.openAIAPIKey),
            (KeychainAccount.anthropicAPIKey, DefaultsKey.anthropicAPIKey),
            (KeychainAccount.googleAPIKey, DefaultsKey.googleAPIKey),
            (KeychainAccount.githubCopilotAccessToken, DefaultsKey.githubCopilotAccessToken)
        ]

        for key in keys {
            if toKeychain {
                let value = UserDefaults.standard.string(forKey: key.defaultsKey) ?? ""
                if !value.isEmpty {
                    KeychainStore.save(value, account: key.account)
                    UserDefaults.standard.removeObject(forKey: key.defaultsKey)
                }
            } else {
                if let value = KeychainStore.load(account: key.account), !value.isEmpty {
                    UserDefaults.standard.set(value, forKey: key.defaultsKey)
                    KeychainStore.delete(account: key.account)
                }
            }
        }
    }
}
