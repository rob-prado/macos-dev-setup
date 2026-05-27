# macOS Development Setup

This repository provides a powerful, modular, and context-aware system for automating the installation and configuration of development tools on macOS. Originally a single script, it has evolved into a robust catalog-driven orchestrator.

## 🌟 Key Features

### 🧩 Modular Architecture
The core `setup.sh` acts as an entrypoint, orchestrating 10+ discrete modules (UI, Logging, Project Context, Core Runners, Health Checks, etc.) located in the `modules/` directory. This ensures high maintainability and isolated logic.

### 📦 Catalog & Lockfile Driven
- **JSON Catalog (`.mac-dev-catalog.json`)**: Defines tools, their types (`formula`, `cask`, `managed`, `gem`), and dependencies.
- **Lockfile State (`.mac-dev-catalog.lock`)**: Tracks the actual installed status versus the desired state to provide deterministic execution.
- **Dependency Engine**: Automatically resolves nested tool dependencies (e.g., asking for `yarn` automatically prepares `node`).

### 🛠 Advanced Version Managers
Seamless integration with modern version managers without polluting your global system:
- **Node**: `fnm`
- **Java**: `sdkman`
- **Ruby**: `chruby` & `ruby-install`
- **Yarn**: `corepack`
- **Xcode**: `xcodes`

### 🌍 Context-Aware (Global vs. Local)
The system adapts its behavior based on where it is executed:
- **Global Execution**: Applies your base catalog configuration.
- **Project Execution**: When run inside a project folder (e.g., React Native), it auto-detects files like `.node-version`, `.ruby-version`, `package.json`, and `.sdkmanrc`. It dynamically overrides the global catalog to install and lock the precise tool versions your local project demands.

### ⚡️ Auto-Env & Silent Switching
Generates a highly optimized `~/.config/mac-dev/env.sh` loaded by your shell (`zsh`, `bash`, or `fish`).
- Features silent directory auto-switching for `fnm`, `sdkman`, and `chruby` to avoid terminal prompt lag.
- Includes a custom-styled `sudo` wrapper.

### 🏥 Health Checks & Drift Detection
Automatically detects "drift" — e.g., if a tool was uninstalled externally or if a symlink broke. The engine marks the tool state as dirty and reconciles it on the next run.

### 🎨 Beautiful TUI
Uses `gum` (if installed) to provide a rich, interactive terminal UI for selecting presets, choosing tools to install/uninstall, and confirming destructive actions. Gracefully falls back to standard text inputs if `gum` is missing.

### 🧹 Deep Cache Purging & Uninstall
Includes robust cleanup jobs that clear heavy caches from Gradle, CocoaPods, Xcode DerivedData, SDKMAN, and Homebrew. The complete uninstaller safely wipes out the entire generated environment.

### 📸 Snapshot Management
Automatically exports JSON snapshots of your current environment state to `~/.mac-dev-snapshots/` after operations. You can import snapshots to reliably clone your setup across machines.

## 🚀 Usage

```bash
# Clone the repository
git clone https://github.com/<your-username>/<repo>.git
cd <repo>

# Run the setup script in interactive mode
./setup.sh
```

### Advanced Flags
- `--dry-run`: Simulates the entire dependency resolution and project context merge without touching the system.
- `--yes`: Auto-confirms all prompts (useful for CI or non-interactive setups).
- `--verbose`: Enables verbose debug logging.
- `--relock`: Regenerates the lockfile without installing anything.

## 🏗 Project Structure

```
├── setup.sh             # Main entrypoint and CLI controller
├── modules/             # Core logic split by domain
│   ├── env.sh           # Shell profile & sudo wrapper generation
│   ├── catalog.sh       # JSON state management
│   ├── project.sh       # Local project context & sync
│   ├── brew.sh          # Brewfile bundle generator
│   └── ...              # (health, snapshot, features, core, ui, etc.)
└── tests/               # Unit and integration tests
```

## 🤝 Contributing
Feel free to open issues or submit pull requests. Ensure that new logic is placed in the appropriate module and that `bash -n` syntax checks pass.

## 📄 License
See the `LICENSE` file for details.
