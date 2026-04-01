# Reprompter

A macOS menu bar utility that rewrites and refines your prompts using LLMs — instantly, from anywhere on your Mac.

## Features

- **Floating panel** — a lightweight window that stays out of your way until you need it
- **Global hotkey** — toggle the panel from any app with a keyboard shortcut
- **Multi-provider support** — works with six LLM backends out of the box
- **Streaming output** — see the rewrite appear in real time
- **Guide text** — optionally provide rewriting instructions alongside your prompt
- **History & archives** — keeps the last 50 rewrites; pin important ones to archives
- **Customizable system prompts** — tune the rewriting behavior to your workflow
- **Secure credential storage** — API keys stored in macOS Keychain

## Supported Providers

| Provider | Notes |
|----------|-------|
| Apple Foundation Models | On-device, no API key required. Requires macOS 26+ |
| OpenAI | Supports custom base URL (compatible with any OpenAI-API endpoint) |
| Anthropic | Claude models |
| Google Gemini | Gemini models |
| GitHub Copilot | OAuth sign-in; uses your existing Copilot subscription |
| Ollama | Local models via Ollama |

## Requirements

- macOS 15 or later
- Xcode 16 or later (to build from source)

## Building from Source

```bash
git clone https://github.com/karthikkumar/reprompter.git
cd reprompter
open reprompter.xcodeproj
```

Select the **reprompter** scheme and press **⌘R** to build and run.

> **Note:** No third-party dependencies are required. The project uses only Apple frameworks.

## Setup

### 1. Choose a provider

Open **Settings** (menu bar icon → Settings, or **⌘,**) and select a provider on the **Model** tab.

### 2. Add your API key

| Provider | Where to get it |
|----------|----------------|
| OpenAI | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| Anthropic | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| Google Gemini | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| GitHub Copilot | Click **Sign in with GitHub** — no manual key needed |
| Ollama | No key required; just set the base URL (default: `http://localhost:11434`) |
| Apple Foundation Models | No key required |

### 3. Set a global hotkey (optional)

Go to the **Shortcuts** tab in Settings, click the shortcut field, and press your desired key combination. Then enable the toggle and grant **Input Monitoring** permission when prompted.

### 4. Rewrite a prompt

1. Press your hotkey (or click the menu bar icon → **Show**)
2. Paste or type your prompt in the top editor
3. Optionally add rewriting instructions in the **Guide** field (toggle with the icon)
4. Click **Rewrite** or press **⌘↩**

## Privacy

- Reprompter does **not** collect analytics or send telemetry.
- Your prompts are sent directly to the provider you configure. No intermediate server is involved.
- API keys are stored locally, either in macOS Keychain (recommended) or in app preferences.

## Project Structure

```
reprompter/
├── reprompterApp.swift          # App entry point, menu bar extra
├── PanelController.swift        # Floating panel orchestration
├── ContentView.swift            # Main panel UI
├── RepromptService.swift        # Provider abstraction + streaming
├── SettingsStore.swift          # Settings persistence + credentials
├── SettingsView.swift           # Settings UI
├── GitHubCopilotAuthManager.swift  # GitHub OAuth device flow
├── KeychainStore.swift          # Keychain wrapper
├── Models.swift                 # Shared types
└── GlobalHotkeyManager.swift    # Global keyboard event monitoring
```

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT — see [LICENSE](LICENSE) for details.
