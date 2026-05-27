# Contributing Guidelines

Thank you for considering contributing to **macOS Development Setup**!

## How to Contribute

1. **Fork the repository**
   - Click the **Fork** button on GitHub to create your own copy.
2. **Clone your fork**
   ```bash
   git clone https://github.com/rob-prado/macos-dev-setup.git
   cd macos-dev-setup
   ```
3. **Create a new branch** for your changes.
   ```bash
   git checkout -b my-feature
   ```
4. **Make your changes**
   - Follow the existing coding style (bash scripts, indentation, comments).
   - Keep the repository clean – do **not** commit generated files such as `*.log`, `*.lock`, `env.sh`, or any files under `~/.sdkman`.
5. **Run the script locally** to ensure it still works.
   ```bash
   chmod +x setup.sh
   ./setup.sh
   ```
6. **Commit and push** your changes.
   ```bash
   git add <changed files>
   git commit -m "Short description of the change"
   git push origin my-feature
   ```
7. **Open a Pull Request**
   - Navigate to your fork on GitHub and click **New Pull Request**.
   - Provide a clear description of what your PR does and why it is needed.

## Code Style
- Use **bash** best‑practice guidelines (set `-euo pipefail`, quote variables, etc.).
- Add comments explaining non‑obvious logic.
- Keep line lengths under 100 characters when possible.

## Reporting Issues
- Open an **issue** on GitHub with a descriptive title.
- Include steps to reproduce, expected behavior, and actual behavior.
- Attach logs only if they are not sensitive; remember `.gitignore` will exclude them.

## License
By contributing, you agree that your contributions will be licensed under the same **MIT License** as the project.

---

*Happy hacking!*
