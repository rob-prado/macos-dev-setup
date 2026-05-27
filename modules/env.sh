#!/usr/bin/env bash

get_target_rc() {
	local s="${SHELL##*/}"
	case "$s" in
	zsh)
		echo "$HOME/.zshrc"
		;;
	bash)
		if [[ -f "$HOME/.bash_profile" ]]; then
			echo "$HOME/.bash_profile"
		else
			echo "$HOME/.bashrc"
		fi
		;;
	fish)
		echo "$HOME/.config/fish/config.fish"
		;;
	*)
		echo "$HOME/.profile"
		;;
	esac
}

ensure_env_sudo_wrapper() {
	if ! grep -q "sudo() {" "$ENV_FILE" 2>/dev/null; then
		cat <<'EOF' >>"$ENV_FILE"

# Custom sudo wrapper to show password prompts cleanly on the line below
sudo() {
	local has_n=false
	for arg in "$@"; do
		if [[ "$arg" == "-n" ]]; then
			has_n=true
			break
		fi
	done
	if [[ "$has_n" == "false" && -t 0 && -t 2 ]]; then
		local c_y=$'\033[1;33m' c_c=$'\033[1;36m' c_w=$'\033[1;37m' c_reset=$'\033[0m'
		local prompt
		prompt=$'\n'"${c_y}┌────────────────────────────────────────┐${c_reset}"$'\n'
		prompt+="${c_y}│  🔑 [SUDO] PRIVILÉGIOS REQUERIDOS       │${c_reset}"$'\n'
		prompt+="${c_y}└────────────────────────────────────────┘${c_reset}"$'\n'
		prompt+="${c_w}Digite a senha para o usuário ${c_c}%u${c_w}:${c_reset}"$'\n❯ '
		command sudo -p "$prompt" "$@"
	else
		command sudo "$@"
	fi
}
EOF
	fi
}

pf_init() {
	mkdir -p "$ENV_DIR"
	if [[ ! -f "$ENV_FILE" ]]; then
		touch "$ENV_FILE"
		cat <<'EOF' >"$ENV_FILE"
if [[ -d "/opt/homebrew/bin" && ! "$PATH" =~ "/opt/homebrew/bin" ]]; then
	export PATH="/opt/homebrew/bin:$PATH"
fi
EOF
	elif ! grep -q "/opt/homebrew/bin" "$ENV_FILE" 2>/dev/null; then
		local tmp
		tmp=$(mktemp)
		cat <<'EOF' >"$tmp"
if [[ -d "/opt/homebrew/bin" && ! "$PATH" =~ "/opt/homebrew/bin" ]]; then
	export PATH="/opt/homebrew/bin:$PATH"
fi
EOF
		cat "$ENV_FILE" >>"$tmp"
		mv "$tmp" "$ENV_FILE"
	fi
	ensure_env_sudo_wrapper
}

pf_reconcile_order() {
	[[ -f "$ENV_FILE" ]] || return 0

	local android_home="" sdkman_dir="" java_home="" default_ruby=""
	local -a misc_lines=()
	local in_sudo=false in_sdkman_silencer=false

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\n'}"
		line="${line%$'\r'}"

		if [[ "$line" == "sudo() {"* ]]; then
			in_sudo=true
			continue
		fi
		if [[ "$in_sudo" == "true" ]]; then
			if [[ "$line" == "}"* ]]; then
				in_sudo=false
			fi
			continue
		fi

		if [[ "$line" == "if declare -f sdkman_auto_env"* || "$line" == "# Custom silent SDKMAN auto-env implementation"* ]]; then
			in_sdkman_silencer=true
			continue
		fi
		if [[ "$in_sdkman_silencer" == "true" ]]; then
			if [[ "$line" == "fi"* && "$line" == "fi" || "$line" == "# End custom silent SDKMAN auto-env implementation"* ]]; then
				in_sdkman_silencer=false
			fi
			continue
		fi

		if [[ "$line" == *"if [[ -d \"/opt/homebrew/bin\""* || "$line" == *"export PATH=\"/opt/homebrew/bin"* || "$line" == "fi" || "$line" == "# Custom sudo wrapper"* ]]; then
			continue
		fi

		if [[ "$line" == "export ANDROID_HOME="* ]]; then
			android_home=$(echo "$line" | sed -E 's/^export ANDROID_HOME="?([^"]*)"?/\1/')
		elif [[ "$line" == "export SDKMAN_DIR="* ]]; then
			sdkman_dir=$(echo "$line" | sed -E 's/^export SDKMAN_DIR="?([^"]*)"?/\1/')
		elif [[ "$line" == "export JAVA_HOME="* ]]; then
			java_home=$(echo "$line" | sed -E 's/^export JAVA_HOME="?([^"]*)"?/\1/')
		elif [[ "$line" == "chruby ruby-"* ]]; then
			default_ruby="$line"
		elif [[ "$line" == "source "* && "$line" == *"chruby.sh" ]]; then
			continue
		elif [[ "$line" == "source "* && "$line" == *"auto.sh" ]]; then
			continue
		elif [[ "$line" == *"sdkman-init.sh"* ]]; then
			continue
		elif [[ "$line" == *"fnm env"* ]]; then
			continue
		elif [[ "$line" == "export PATH="* && "$line" == *"\$ANDROID_HOME"* ]]; then
			continue
		elif [[ -n "${line//[[:space:]]/}" ]]; then
			misc_lines+=("$line")
		fi
	done <"$ENV_FILE"

	[[ -z "$sdkman_dir" ]] && sdkman_dir="\$HOME/.sdkman"
	[[ -z "$java_home" ]] && java_home="\$HOME/.sdkman/candidates/java/current"
	[[ -z "$android_home" && -d "$HOME/Library/Android/Sdk" ]] && android_home="\$HOME/Library/Android/Sdk"

	if [[ -f "$HOME/.sdkman/etc/config" ]]; then
		sed -i '' 's/sdkman_auto_env=true/sdkman_auto_env=false/g' "$HOME/.sdkman/etc/config" 2>/dev/null || true
	fi

	local tmp
	tmp=$(mktemp)

	cat <<'EOF' >"$tmp"
if [[ -d "/opt/homebrew/bin" && ! "$PATH" =~ "/opt/homebrew/bin" ]]; then
	export PATH="/opt/homebrew/bin:$PATH"
fi
EOF

	cat <<'EOF' >>"$tmp"

# Custom sudo wrapper to show password prompts cleanly on the line below
sudo() {
	local has_n=false
	for arg in "$@"; do
		if [[ "$arg" == "-n" ]]; then
			has_n=true
			break
		fi
	done
	if [[ "$has_n" == "false" && -t 0 && -t 2 ]]; then
		local c_y=$'\033[1;33m' c_c=$'\033[1;36m' c_w=$'\033[1;37m' c_reset=$'\033[0m'
		local prompt
		prompt=$'\n'"${c_y}┌────────────────────────────────────────┐${c_reset}"$'\n'
		prompt+="${c_y}│  🔑 [SUDO] PRIVILÉGIOS REQUERIDOS       │${c_reset}"$'\n'
		prompt+="${c_y}└────────────────────────────────────────┘${c_reset}"$'\n'
		prompt+="${c_w}Digite a senha para o usuário ${c_c}%u${c_w}:${c_reset}"$'\n❯ '
		command sudo -p "$prompt" "$@"
	else
		command sudo "$@"
	fi
}
EOF

	echo "" >>"$tmp"
	[[ -n "$android_home" ]] && echo "export ANDROID_HOME=\"$android_home\"" >>"$tmp"
	echo "export SDKMAN_DIR=\"$sdkman_dir\"" >>"$tmp"
	echo "export JAVA_HOME=\"$java_home\"" >>"$tmp"

	echo "" >>"$tmp"
	echo "source $BREW_PREFIX/opt/chruby/share/chruby/chruby.sh" >>"$tmp"
	echo "source $BREW_PREFIX/opt/chruby/share/chruby/auto.sh" >>"$tmp"
	echo "[[ -s \"\$SDKMAN_DIR/bin/sdkman-init.sh\" ]] && source \"\$SDKMAN_DIR/bin/sdkman-init.sh\" >/dev/null" >>"$tmp"
	cat <<'EOF' >>"$tmp"
# Custom silent SDKMAN auto-env implementation
sdkman_auto_env() {
	if [[ -n $SDKMAN_ENV ]] && [[ ! $PWD =~ ^$SDKMAN_ENV ]]; then
		sdk env clear >/dev/null 2>&1
	fi
	if [[ -f .sdkmanrc ]]; then
		sdk env >/dev/null 2>&1
	fi
}

if [[ -n "$ZSH_VERSION" ]]; then
	if [[ ! " ${chpwd_functions[@]} " =~ " sdkman_auto_env " ]]; then
		chpwd_functions+=(sdkman_auto_env)
	fi
elif [[ -n "$BASH_VERSION" ]]; then
	if [[ ! "$PROMPT_COMMAND" =~ "sdkman_auto_env" ]]; then
		trimmed_prompt_command="${PROMPT_COMMAND%"${PROMPT_COMMAND##*[![:space:]]}"}"
		[[ -z "$trimmed_prompt_command" ]] && PROMPT_COMMAND="sdkman_auto_env" || PROMPT_COMMAND="${trimmed_prompt_command%\;};sdkman_auto_env"
	fi
fi

# Run once at startup silently
sdkman_auto_env
# End custom silent SDKMAN auto-env implementation
EOF
	echo "if command -v fnm &>/dev/null; then eval \"\$(fnm env --use-on-cd --log-level=quiet)\"; fi" >>"$tmp"

	echo "" >>"$tmp"
	echo "export PATH=\"\$ANDROID_HOME/emulator:\$ANDROID_HOME/platform-tools:\$PATH\"" >>"$tmp"
	[[ -n "$default_ruby" ]] && echo "$default_ruby" >>"$tmp"

	if [[ ${#misc_lines[@]} -gt 0 ]]; then
		echo "" >>"$tmp"
		for ml in "${misc_lines[@]}"; do
			echo "$ml" >>"$tmp"
		done
	fi

	mv "$tmp" "$ENV_FILE"
}

pf_add() {
	local l="$1"
	pf_init
	grep -qxF "$l" "$ENV_FILE" 2>/dev/null || echo "$l" >>"$ENV_FILE"
	pf_reconcile_order
	local sl="[[ -f $ENV_FILE ]] && source $ENV_FILE" tr
	tr=$(get_target_rc)
	if [[ -f "$tr" || "$tr" == *".zshrc" || "$tr" == *".bash_profile" ]]; then
		grep -qxF "$sl" "$tr" 2>/dev/null || echo "$sl" >>"$tr"
	fi
	if [[ "$tr" != "$HOME/.profile" && -f "$HOME/.profile" ]]; then
		grep -qxF "$sl" "$HOME/.profile" 2>/dev/null || echo "$sl" >>"$HOME/.profile"
	fi
}

pf_set_env() {
	local k="$1" v="$2"
	pf_init
	sed -i '' "/^export ${k}=/d" "$ENV_FILE" 2>/dev/null || true
	echo "export ${k}=\"${v}\"" >>"$ENV_FILE"
	pf_reconcile_order
}

pf_rm_pat() {
	local p="$1"
	[[ -f "$ENV_FILE" ]] && sed -i '' "/${p}/d" "$ENV_FILE" 2>/dev/null || true
	pf_reconcile_order
}

_scrub_profile_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	local -a patterns=(
		'fnm env --use-on-cd'
		'chruby\.sh'
		'chruby\/auto\.sh'
		'SDKMAN_DIR'
		'sdkman-init\.sh'
		'JAVA_HOME'
		'ANDROID_HOME'
		'chruby ruby-'
	)
	for pat in "${patterns[@]}"; do
		sed -i '' "/${pat}/d" "$file" 2>/dev/null || true
	done
}
