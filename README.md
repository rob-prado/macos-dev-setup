# macOS Development Setup

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)
![Shell: Bash 4+](https://img.shields.io/badge/Shell-Bash%204%2B-green.svg)

This repository provides a powerful, modular, and context-aware system for automating the installation and configuration of development tools on macOS. Originally a single script, it has evolved into a robust catalog-driven orchestrator.

## 🌟 Key Features

### 🧩 Modular Architecture
The core `setup.sh` acts as an entrypoint, orchestrating 15 discrete modules (UI, TUI, Logging, Project Context, Core Runners, Health Checks, etc.) located in the `modules/` directory. This ensures high maintainability and isolated logic.

### 📦 Catalog & Lockfile Driven
- **JSON Catalog (`.mac-dev-catalog.json`)**: Defines tools, their types (`formula`, `cask`, `managed`, `gem`), and dependencies.
- **Lockfile State (`.mac-dev-catalog.lock`)**: Tracks the actual installed status versus the desired state to provide deterministic execution.
- **Dependency Engine**: Automatically resolves nested tool dependencies (e.g., asking for `yarn` automatically prepares `node`).

### 🛠 Advanced Version Managers
Seamless integration with **mise** (formerly rtx), the blazingly fast polyglot version manager:
- Replaces legacy managers (fnm, sdkman, chruby, nvm, asdf).
- Manages Node, Java, Ruby, Yarn, and many more.
- Centralized global configuration with project-level overrides.
- Integrates seamlessly with Xcode via `xcodes`.

### 🌍 Context-Aware (Global vs. Local)
The system adapts its behavior based on where it is executed:
- **Global Execution**: Applies your base catalog configuration.
- **Project Execution**: When run inside a project folder (e.g., React Native), it auto-detects files like `.node-version`, `.ruby-version`, `package.json`, and `.java-version`. It dynamically overrides the global catalog to install and lock the precise tool versions your local project demands.

### ⚡️ Auto-Env & Seamless Legacy Support
Generates a highly optimized `~/.config/mac-dev/env.sh` loaded by your shell (`zsh`, `bash`).
- Features a custom intelligent shell hook that guarantees 100% compatibility with legacy version files (`.nvmrc`, `.node-version`, `.ruby-version`, `.java-version`). 
- Translates formats (e.g., `21.0.11-zulu` to `zulu-21`) automatically, ensuring `mise` respects your project versions without fighting global defaults.
- Includes a custom-styled `sudo` wrapper.

### 🏥 Health Checks & Drift Detection
Automatically detects "drift" — e.g., if a tool was uninstalled externally or if a symlink broke. The engine marks the tool state as dirty and reconciles it on the next run.

### 🔍 Tool Search & Discovery
Search for any tool available on Homebrew directly from the interactive menu. The script searches, lets you pick a result, auto-detects if it's a formula or cask, and installs it — all in one flow.

### 🎨 Beautiful TUI
Uses `gum` (if installed) to provide a rich, interactive terminal UI for selecting actions like "Update/Remove Tool". Gracefully falls back to standard text inputs if `gum` is missing.

### 🧹 Deep Cache Purging & Uninstall
Includes robust cleanup jobs that clear heavy caches from Gradle, CocoaPods, Xcode DerivedData, and Homebrew. The complete uninstaller safely wipes out the entire generated environment.

### 📸 Snapshot Management
Automatically exports JSON snapshots of your current environment state to `~/.mac-dev-snapshots/` after operations. You can import snapshots to reliably clone your setup across machines.

## 📋 Requirements

- **macOS** (Ventura 13+, Sonoma 14, Sequoia 15)
- **Homebrew** — will be installed automatically if missing
- **Bash 4+** — the script auto-installs it via Homebrew if only macOS's native Bash 3.2 is available
- **Internet connection** — required for downloading tools and checking connectivity
- Native tools (included with macOS): `git`, `curl`, `awk`, `grep`, `sed`, `find`, `xargs`
- Optional: [`gum`](https://github.com/charmbracelet/gum) for the rich interactive TUI

## 🚀 Usage

### Installation

#### Option A — Clone with Git (recommended)
```bash
git clone https://github.com/rob-prado/macos-dev-setup.git ~/MacOS_Setup
cd ~/MacOS_Setup
chmod +x setup.sh
```

> Cloning with Git keeps the history and lets you update easily with `git pull`.

#### Option B — Download as ZIP
If you downloaded the project as a `.zip` file, move it out of `Downloads` to keep things organized:
```bash
mv ~/Downloads/MacOS_Setup-main ~/MacOS_Setup
cd ~/MacOS_Setup
chmod +x setup.sh
```

### Creating a Global Alias
To run the setup script from anywhere without navigating to its folder:
```bash
echo 'alias setup="~/MacOS_Setup/setup.sh"' >> ~/.zshrc
source ~/.zshrc
```
Now you can simply type `setup` in any terminal window to launch the orchestrator!

### Running the Script
```bash
setup
```

Or, to configure the tools for a specific project:
```bash
cd ~/path/to/project
setup
```

After running the script, you can reload your shell profile by running `source ~/.zshrc`, restart your terminal, or open a new terminal window, or simply type `cd .` in the current directory to apply the changes.

### Interactive Menu

When you run the script, you'll be presented with an interactive menu:

| Option | Description |
|--------|-------------|
| **Instalar Tudo** | Install all tools defined in your catalog |
| **Atualizar Tudo** | Update every installed tool to its latest version |
| **Atualizar Ferramenta** | Selectively update specific tools |
| **Adicionar Ferramenta** | Search Homebrew and add a new tool to your catalog |
| **Remover Ferramenta** | Selectively uninstall specific tools |
| **Desinstalar Tudo** | Complete uninstall — removes all tools, configs, and SDKs |

### Advanced Flags
- `--dry-run`: Simulates the entire dependency resolution and project context merge without touching the system.
- `--yes`: Auto-confirms all prompts (useful for CI or non-interactive setups).
- `--verbose`: Enables verbose debug logging.
- `--relock`: Regenerates the lockfile without installing anything.

## 🚑 Troubleshooting

- **`Permission denied` error when trying to run `./setup.sh`:**
  - The script lacks execution permission. Run `chmod +x setup.sh` in the project folder.
- **`mise WARN missing: java@zulu-21` or similar warning when entering a project folder:**
  - This is perfectly normal! It means the intelligent hook detected your project's version files and forced `mise` to use them, but the exact version is not yet installed on your machine. Simply run `mise install` inside that folder to download the local dependencies.
- **Tools do not update their versions when running `cd .` or entering a folder:**
  - Ensure your terminal was restarted, or run `source ~/.config/mac-dev/env.sh` to load the updated shell hook.
- **Tools failing during the health check or mysterious error logs:**
  - Execute the setup script and select "Update All", or run it with the `--verbose` flag (`./setup.sh --verbose`) to deeply inspect where the command failed.

## 🏗 Project Structure

```
├── setup.sh              # Main entrypoint and CLI controller
├── modules/
│   ├── utils.sh          # Utility & system helpers (retry, curl, notify)
│   ├── ui.sh             # Printing & UI styling
│   ├── logging.sh        # Logging, auditing & metrics
│   ├── tui.sh            # Interactive terminal UI (gum integration)
│   ├── env.sh            # Shell profile & sudo wrapper generation
│   ├── catalog.sh        # JSON catalog state management
│   ├── lock.sh           # Lockfile state tracking
│   ├── metadata.sh       # Resolution & dependency engine
│   ├── health.sh         # Conflicts, drift & health checks
│   ├── snapshot.sh        # Snapshot export/import
│   ├── core.sh           # Process runners & job controllers
│   ├── brew.sh           # Brewfile bundle generator
│   ├── features.sh       # Feature operations (install, update, uninstall)
│   ├── cleanup.sh        # Cache purging & system cleanup
│   └── project.sh        # Local project context & sync
├── CONTRIBUTING.md       # Contribution guidelines
└── LICENSE               # MIT License
```

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on how to fork, branch, and submit pull requests.

## 📄 License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.
