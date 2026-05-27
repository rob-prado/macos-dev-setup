# macOS Development Setup

This repository contains a single script `setup.sh` that automates the installation and configuration of development tools on macOS.

## Features
- Installs SDKMAN, Java, Android SDK, Xcode tools, watchman, reactotron, etc., depending on the project type.
- Automatically switches tool versions when entering a project directory.
- Silent environment handling to avoid conflicts with instant prompts.

## Usage
```bash
# Clone the repo
git clone https://github.com/<your-username>/<repo>.git
cd <repo>

# Run the setup script (you may need to make it executable first)
chmod +x setup.sh
./setup.sh
```

The script will detect the presence of `ios`/`android` folders, a `react-native` project, and install only the required tools.

## Contributing
Feel free to open issues or submit pull requests. Please keep the repository clean – do not commit user‑specific configuration files.

## License
See the `LICENSE` file for details.
