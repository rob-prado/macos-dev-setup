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

### 🎨 Beautiful TUI
Uses `gum` (if installed) to provide a rich, interactive terminal UI for selecting actions like "Update/Remove Tool". Gracefully falls back to standard text inputs if `gum` is missing.

### 🧹 Deep Cache Purging & Uninstall
Includes robust cleanup jobs that clear heavy caches from Gradle, CocoaPods, Xcode DerivedData, and Homebrew. The complete uninstaller safely wipes out the entire generated environment.

### 📸 Snapshot Management
Automatically exports JSON snapshots of your current environment state to `~/.mac-dev-snapshots/` after operations. You can import snapshots to reliably clone your setup across machines.

## 🚀 Usage

### How to run the script after downloading on Mac
If you downloaded the project as a `.zip` file, it is highly recommended to move it out of your `Downloads` folder to your Home directory to keep your setup persistent and organized.

Open your Terminal and follow these steps:

```bash
# 1. Move the extracted folder to your Home directory and navigate to it
mv ~/Downloads/MacOS_Setup-main ~/MacOS_Setup
cd ~/MacOS_Setup

# 2. Grant execution permission to the main script
chmod +x setup.sh

# 3. Execute the setup script
./setup.sh
```

### Creating a Global Alias (Optional)
To run the setup script from anywhere without navigating to its folder, you can add an alias to your shell profile.

Open your terminal and run the following command:
```bash
echo 'alias mac-setup="~/MacOS_Setup/setup.sh"' >> ~/.zshrc
source ~/.zshrc
```
Now you can simply type `mac-setup` in any terminal window to launch the orchestrator!


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
