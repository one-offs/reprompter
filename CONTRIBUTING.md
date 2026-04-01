# Contributing to Reprompter

Thank you for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repository and clone your fork
2. Open `reprompter.xcodeproj` in Xcode 16+
3. Build and run with **⌘R** to verify everything works

No external dependencies are needed — the project uses only Apple frameworks.

## How to Contribute

### Reporting Bugs

Please [open an issue](../../issues/new) with:
- A clear description of the bug
- Steps to reproduce
- Expected vs actual behavior
- macOS version and which provider you're using

### Suggesting Features

Open an issue with the `enhancement` label. Describe the problem you're solving, not just the solution you have in mind.

### Submitting Pull Requests

1. Create a branch from `main` with a descriptive name (e.g. `fix/anthropic-streaming`, `feature/token-counter`)
2. Make your changes, following the code style guidelines below
3. Build and verify there are no warnings or errors
4. Open a pull request against `main` with a clear description of what changed and why

## Code Style

- **Swift conventions**: PascalCase for types, camelCase for properties/methods
- **SwiftUI**: Prefer `@Observable` and async/await over Combine
- **Avoid force unwraps** (`!`) — use `guard let`, `if let`, or `?? fallback` patterns
- **Logging**: Use `os.Logger` with appropriate privacy labels instead of `print()`
- **No third-party dependencies** — keep the project dependency-free

## Provider Changes

If you're adding or modifying a provider client, follow the `RepromptProviderClient` protocol in `RepromptService.swift`. Implement both `rewrite()` (non-streaming) and `rewriteStream()` where the API supports it.

## Testing

There are currently no automated tests. If you add tests, use:
- **Swift Testing** (`import Testing`) for unit tests
- **XCUITest** for UI tests

We welcome PRs that add test coverage to any part of the codebase.

## Commit Messages

Write short, imperative commit messages:
- `Fix Google streaming chunk parsing`
- `Add connection test for Ollama`
- `Remove force unwraps in RepromptService`

## Questions?

Open an issue or start a discussion — we're happy to help.
