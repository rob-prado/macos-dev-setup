#!/usr/bin/env bash
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

if [[ -d "/opt/homebrew/bin" && ! "$PATH" =~ "/opt/homebrew/bin" ]]; then
	export PATH="/opt/homebrew/bin:$PATH"
fi

# ==========================================
# PALETTE & CONFIG
# ==========================================

readonly C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
if [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]]; then
	readonly C_Y=$'\033[38;2;255;215;0m' C_G=$'\033[38;2;106;175;80m' C_B=$'\033[38;2;59;130;246m'
	readonly C_R=$'\033[38;2;239;68;68m' C_C=$'\033[38;2;56;189;248m' C_W=$'\033[38;2;239;239;239m' C_D=$'\033[38;2;156;163;175m'
else
	readonly C_Y=$'\033[1;33m' C_G=$'\033[1;32m' C_B=$'\033[1;34m'
	readonly C_R=$'\033[1;31m' C_C=$'\033[1;36m' C_W=$'\033[1;37m' C_D=$'\033[2m'
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
readonly BREW_PREFIX
readonly BREW_BASH="$BREW_PREFIX/bin/bash"
readonly SDKMAN_DIR="$HOME/.sdkman"
readonly DEFAULT_CATALOG="$HOME/.mac-dev-catalog.json"
CATALOG_FILE="${MAC_DEV_CATALOG_FILE:-$DEFAULT_CATALOG}"
readonly LOCK_FILE="${CATALOG_FILE%.json}.lock"
readonly ENV_DIR="$HOME/.config/mac-dev"
readonly ENV_FILE="$ENV_DIR/env.sh"
readonly LOG_FILE="$HOME/Library/Logs/mac-dev-setup.log"
readonly LOG_DIR="$HOME/Library/Logs/mac-dev-setup"
readonly VERBOSE="${VERBOSE:-0}"
readonly DRY_RUN="${DRY_RUN:-0}"
[[ ! -t 0 ]] && AUTO_YES=true || AUTO_YES="${AUTO_YES:-false}"
IFS=$' 
\t'
TERM_WIDTH="$(tput cols 2>/dev/null || echo 80)"
readonly CATALOG_SCHEMA_VERSION=2

HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true
HAS_GLOW=false
command -v glow >/dev/null 2>&1 && HAS_GLOW=true

# Globais de Auditoria (Prevenir erro de unbound variable sob set -u)
AUDIT_INSTALLED=()
AUDIT_UPDATED=()
AUDIT_UPTODATE=()
AUDIT_SKIPPED=()
AUDIT_REMOVED=()
AUDIT_MISSING=()
AUDIT_FAILED=()

# ==============================================================================
# 01. UTILITY & SYSTEM HELPERS
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/modules/utils.sh"

# ==============================================================================
# 02. PRINTING & UI STYLING
# ==============================================================================
# Load modular UI functions
source "$(dirname "${BASH_SOURCE[0]}")/modules/ui.sh"

msg() {
	printf "%b[%s]%b %b%s%b\n" "$C_D" "$(date +%H:%M:%S)" "$C_RESET" "$1" "$2" "$C_RESET"
}

warn() {
	printf "%b⚠️  Atenção: %s%b\n" "$C_Y" "$1" "$C_RESET" >&2
}

err() {
	printf "%b❌ Erro: %s%b\n" "$C_R" "$1" "$C_RESET" >&2
	exit 1
}

sudo() {
	local has_n=false
	for arg in "$@"; do
		if [[ "$arg" == "-n" ]]; then
			has_n=true
			break
		fi
	done
	if [[ "$has_n" == "false" && -t 0 && -t 2 ]]; then
		local prompt
		prompt=$'\n'"${C_Y}┌────────────────────────────────────────┐${C_RESET}"$'\n'
		prompt+="${C_Y}│  🔑 [SUDO] PRIVILÉGIOS REQUERIDOS       │${C_RESET}"$'\n'
		prompt+="${C_Y}└────────────────────────────────────────┘${C_RESET}"$'\n'
		prompt+="${C_BOLD}${C_W}Digite a senha para o usuário ${C_C}%u${C_W}:${C_RESET}"$'\n❯ '
		command sudo -p "$prompt" "$@"
	else
		command sudo "$@"
	fi
}

repeat_char() {
	printf '%*s' "$1" '' | tr ' ' "$2"
}

draw_box() {
	local t="  $1  "
	local w="${2:-$TERM_WIDTH}"
	[[ $w -gt 50 ]] && w=50
	[[ $w -lt 20 ]] && w=20
	local total_pad=$((w - ${#t} - 2))
	[[ $total_pad -lt 0 ]] && total_pad=0
	local lp=$((total_pad / 2))
	local rp=$((total_pad - lp))
	printf '\n%s╔%s╗\n║%s%s%s%s%s║\n╚%s╝%s\n' \
		"${C_B}" "$(repeat_char $((w - 2)) '═')" \
		"$(repeat_char "$lp" ' ')" "${C_BOLD}${C_W}" "$t" "${C_RESET}" "$(repeat_char "$rp" ' ')" \
		"${C_B}$(repeat_char $((w - 2)) '═')" "${C_RESET}"
}

print_progress_bar() {
	local c="$1"
	local t="$2"
	local l="$3"
	[[ "$t" -eq 0 ]] && t=1
	local w=$((TERM_WIDTH - 25))
	[[ $w -lt 15 ]] && w=15
	[[ $w -gt 50 ]] && w=50
	local f=$((w * c / t))
	local e=$((w - f))
	printf '\n%s%s[%02d/%02d]%s %b%-15s%b %s%s%s%s%s\n' \
		"$C_BOLD" "$C_C" "$c" "$t" "$C_RESET" \
		"$C_BOLD" "${l:0:15}" "$C_RESET" \
		"$C_G" "$(repeat_char "$f" '■')" \
		"$C_D" "$(repeat_char "$e" '·')" "$C_RESET"
}

render_markdown() {
	local content="$1"
	if [[ "$HAS_GLOW" == "true" ]]; then
		echo "$content" | glow -w "$TERM_WIDTH" -s dark 2>/dev/null || echo "$content"
	else
		echo "$content"
	fi
}

# ==============================================================================
# 03. LOGGING, AUDITING & METRICS
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/modules/logging.sh"

# ==============================================================================
# 04. INTERACTIVE TERMINAL UI (TUI)
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/modules/tui.sh"

# ==============================================================================
# 05. SHELL ENVIRONMENT CONFIGURATION (RC PROFILES)
# ==============================================================================

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

# ==============================================================================
# 06. STATE DATABASE (JSON CATALOG & LOCKFILE)
# ==============================================================================

migrate_catalog() {
	[[ ! -f "$CATALOG_FILE" ]] && return 0
	local current
	current=$(jq -r '.schema_version // 1' "$CATALOG_FILE" 2>/dev/null || echo 1)
	if [[ "$current" -lt 2 ]]; then
		msg "$C_C" "🔄 Migrando catálogo v$current → v$CATALOG_SCHEMA_VERSION..."
		local tmp
		tmp=$(mktemp)
		TMP_FILES+=("$tmp")
		if jq \
			--argjson sv "$CATALOG_SCHEMA_VERSION" \
			'. + {schema_version: $sv}
			| if .tools.cocoapods == null
				then .tools.cocoapods = {"type":"gem","version":""}
				else .
			end' \
			"$CATALOG_FILE" >"$tmp"; then
			mv "$tmp" "$CATALOG_FILE"
		else
			rm -f "$tmp"
		fi
		msg "$C_G" "✅ Migração concluída."
	fi
}

catalog_init() {
	[[ -f "$CATALOG_FILE" ]] && return 0
	cat <<EOF >"$CATALOG_FILE"
{"schema_version":$CATALOG_SCHEMA_VERSION,"tools":{"watchman":{"type":"formula","version":""},"xcbeautify":{"type":"formula","version":""},"cocoapods":{"type":"gem","version":"","dependencies":["ruby"]},"node":{"type":"managed","manager":"fnm","versions":[]},"yarn":{"type":"managed","manager":"corepack","versions":[],"dependencies":["node"]},"java":{"type":"managed","manager":"sdkman","versions":[]},"ruby":{"type":"managed","manager":"chruby","versions":[]},"xcode":{"type":"managed","manager":"xcodes","versions":[]},"visual-studio-code":{"type":"cask","version":""},"reactotron":{"type":"cask","version":""},"android-studio":{"type":"cask","version":""}}}
EOF
}

validate_catalog_schema() {
	local schema='.tools | type == "object" and all(.[]; has("type") and (.type | test("^(formula|cask|managed|gem)$")) and if .type == "managed" then has("manager") else true end)'
	jq -e "$schema" "$CATALOG_FILE" >/dev/null 2>&1 || err "Catálogo inválido. Schema não respeitado."
}

ensure_lockfile() {
	[[ -f "$LOCK_FILE" ]] && return 0
	local hash
	hash=$(shasum -a 256 "$CATALOG_FILE" | cut -d' ' -f1)
	printf '{"catalog_hash":"%s","generated_at":"%s","tools":{}}
' "$hash" "$(get_local_timestamp)" >"$LOCK_FILE"
}

_jq_update() {
	local f="$1"
	local tmp lock_dir retries=50
	tmp=$(mktemp)
	lock_dir="${CATALOG_FILE}.lock.d"
	TMP_FILES+=("$tmp")
	cp "$CATALOG_FILE" "${CATALOG_FILE}.bak" 2>/dev/null || true
	while ! mkdir "$lock_dir" 2>/dev/null; do
		((retries-- <= 0)) && {
			rm -f "$tmp"
			return 1
		}
		sleep 0.1
	done
	echo $$ >"$lock_dir/pid"
	if jq "$f" "$CATALOG_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$CATALOG_FILE"
	else
		rm -f "$tmp"
	fi
	rm -rf "$lock_dir"
}

c_get() {
	jq -r ".tools[\"$1\"].$2 // empty" "$CATALOG_FILE" 2>/dev/null || true
}

c_get_versions() {
	jq -r ".tools[\"$1\"].versions[]?" "$CATALOG_FILE" 2>/dev/null || true
}

c_add_version() {
	_jq_update ".tools[\"$1\"].versions = ((.tools[\"$1\"].versions // []) + [\"$2\"] | unique)"
}

c_set_version() {
	local t
	t=$(c_get "$1" "type")
	if [[ "$t" == "managed" ]]; then
		_jq_update "del(.tools[\"$1\"].version)"
	else
		_jq_update ".tools[\"$1\"].version = \"$2\""
	fi
}

c_clear_versions() {
	local t
	t=$(c_get "$1" "type")
	if [[ "$t" == "managed" ]]; then
		_jq_update "del(.tools[\"$1\"].version) | .tools[\"$1\"].versions = []"
	else
		_jq_update ".tools[\"$1\"].version = \"\""
	fi
}

register_tool_state() {
	local tool="$1" version="$2" state="$3"
	local type
	type=$(c_get "$tool" "type")
	if [[ "$type" == "managed" ]]; then
		c_add_version "$tool" "$version"
	else
		c_set_version "$tool" "$version"
	fi
	update_lock_entry "$tool" "$version" "$state"
}

update_lock_entry() {
	local tmp lock_dir retries=50
	local tool="$1" val="$2" state="$3"
	local type
	type=$(c_get "$tool" "type")
	tmp=$(mktemp)
	lock_dir="${LOCK_FILE}.lock.d"
	TMP_FILES+=("$tmp")
	while ! mkdir "$lock_dir" 2>/dev/null; do
		((retries-- <= 0)) && {
			rm -f "$tmp"
			return 1
		}
		sleep 0.1
	done
	echo $$ >"$lock_dir/pid"

	local success=false
	if [[ "$type" == "managed" ]]; then
		local -a vers=()
		readarray -t vers < <(c_get_versions "$tool")
		local vers_json
		if [[ ${#vers[@]} -gt 0 ]]; then
			vers_json=$(printf '%s\n' "${vers[@]}" | jq -R . | jq -s -c .)
		else
			vers_json="[]"
		fi
		if jq \
			--arg t "$tool" \
			--argjson v "$vers_json" \
			--arg s "$state" \
			--arg ts "$(get_local_timestamp)" \
			'.tools[$t]={versions:$v,status:$s} | .generated_at=$ts' \
			"$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
			success=true
		fi
	else
		if jq \
			--arg t "$tool" \
			--arg v "${val:-}" \
			--arg s "$state" \
			--arg ts "$(get_local_timestamp)" \
			'.tools[$t]={version:$v,status:$s} | .generated_at=$ts' \
			"$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
			success=true
		fi
	fi

	if [[ "$success" == "false" ]]; then
		rm -f "$tmp"
	fi
	rm -rf "$lock_dir"
}

validate_lock_consistency() {
	[[ ! -f "$LOCK_FILE" ]] && return 0
	local ch lh
	ch=$(shasum -a 256 "$CATALOG_FILE" | cut -d' ' -f1)
	lh=$(jq -r '.catalog_hash' "$LOCK_FILE" 2>/dev/null || true)
	if [[ "$ch" != "$lh" ]]; then
		local tmp lock_dir retries=50
		tmp=$(mktemp)
		lock_dir="${LOCK_FILE}.lock.d"
		TMP_FILES+=("$tmp")
		while ! mkdir "$lock_dir" 2>/dev/null; do
			((retries-- <= 0)) && {
				rm -f "$tmp"
				return 0
			}
			sleep 0.1
		done
		echo $$ >"$lock_dir/pid"
		if jq --arg h "$ch" --arg ts "$(get_local_timestamp)" '.catalog_hash = $h | .generated_at = $ts' "$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
		else
			rm -f "$tmp"
		fi
		rm -rf "$lock_dir"
	fi
	return 0
}

catalog_reconcile() {
	local -a current
	readarray -t current < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)
	for t in "${current[@]}"; do
		[[ -z "${t:-}" ]] && continue
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "formula" || "$type" == "cask" ]]; then
			if brew list "${type:+--$type}" "$t" &>/dev/null; then
				local ver
				ver=$(brew list "${type:+--$type}" --versions "$t" 2>/dev/null | awk '{print $NF}' || true)
				if [[ -n "$ver" ]]; then
					_jq_update ".tools[\"$t\"].version = \"$ver\""
					update_lock_entry "$t" "$ver" "installed"
				fi
			else
				_jq_update ".tools[\"$t\"].version = \"\""
				update_lock_entry "$t" "" "removed"
			fi
		elif [[ "$type" == "gem" ]]; then
			if command -v gem &>/dev/null && run_in_ruby_env "gem list -i '${t}' &>/dev/null" 2>/dev/null; then
				local ver
				ver=$(run_in_ruby_env "gem list -e '${t}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>/dev/null || true)
				if [[ -n "$ver" ]]; then
					_jq_update ".tools[\"$t\"].version = \"$ver\""
					update_lock_entry "$t" "$ver" "installed"
				fi
			else
				_jq_update ".tools[\"$t\"].version = \"\""
				update_lock_entry "$t" "" "removed"
			fi
		elif [[ "$type" == "managed" ]]; then
			local mgr
			local is_installed=false
			mgr=$(c_get "$t" "manager")
			local -a vers=()
			case "$mgr" in
			fnm)
				if command -v fnm &>/dev/null; then
					is_installed=true
					readarray -t vers < <(fnm list 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' || true)
				fi
				;;
			sdkman)
				if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
					is_installed=true
					readarray -t vers < <(ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null | grep -v 'current' || true)
				fi
				;;
			chruby)
				if [[ -d "$HOME/.rubies" ]]; then
					is_installed=true
					readarray -t vers < <(ls -1 "$HOME/.rubies" 2>/dev/null | sed 's/ruby-//' || true)
				fi
				;;
			corepack)
				local yv
				yv=$(yarn -v 2>/dev/null || true)
				if [[ -n "$yv" ]]; then
					is_installed=true
					vers=("$yv")
				fi
				;;
			xcodes)
				if command -v xcodes &>/dev/null; then
					is_installed=true
					readarray -t vers < <(xcodes installed 2>/dev/null | awk '{print $1}' || true)
				fi
				;;
			esac

			local -a clean_vers=()
			for v in "${vers[@]}"; do
				[[ -n "${v:-}" ]] && clean_vers+=("$v")
			done

			if [[ "$is_installed" == "true" && ${#clean_vers[@]} -gt 0 ]]; then
				local v_json
				v_json=$(printf '%s\n' "${clean_vers[@]}" | jq -R . | jq -s -c .)
				_jq_update ".tools[\"$t\"].versions = $v_json"
				update_lock_entry "$t" "" "installed"
			else
				_jq_update ".tools[\"$t\"].versions = []"
				update_lock_entry "$t" "" "removed"
			fi
		fi
	done
}

# ==============================================================================
# 07. RESOLUTION & METADATA (DEPENDENCY ENGINE)
# ==============================================================================

get_known_managed() {
	case "$1" in
	node) echo "fnm" ;;
	java) echo "sdkman" ;;
	ruby) echo "chruby" ;;
	yarn) echo "corepack" ;;
	xcode) echo "xcodes" ;;
	*) return 1 ;;
	esac
}

get_preset_tools() {
	case "$1" in
	minimal) echo "watchman xcbeautify" ;;
	rn) echo "watchman xcbeautify node yarn java visual-studio-code reactotron android-studio" ;;
	full) echo "watchman xcbeautify node yarn java ruby xcode visual-studio-code reactotron android-studio cocoapods" ;;
	java) echo "watchman java visual-studio-code android-studio" ;;
	*) return 1 ;;
	esac
}

list_presets() {
	echo "minimal"
	echo "rn"
	echo "full"
	echo "java"
}

c_get_dependencies() {
	local tool="$1"
	local deps
	deps=$(jq -r ".tools[\"$tool\"].dependencies[]? // empty" "$CATALOG_FILE" 2>/dev/null || true)
	if [[ -z "${deps:-}" ]]; then
		case "$tool" in
		cocoapods)
			echo "ruby"
			;;
		yarn)
			echo "node"
			;;
		esac
	else
		echo "$deps"
	fi
}

resolve_dependencies_rec() {
	local tool="$1"

	if [[ " $RESOLVED_LIST " == *" $tool "* ]]; then
		return 0
	fi

	if [[ " $VISITING_LIST " == *" $tool "* ]]; then
		err "Erro: Dependência circular detectada envolvendo a ferramenta '$tool'!"
	fi

	VISITING_LIST="${VISITING_LIST} ${tool}"

	local dep
	while IFS= read -r dep; do
		if [[ -n "${dep:-}" ]]; then
			resolve_dependencies_rec "$dep"
		fi
	done < <(c_get_dependencies "$tool")

	VISITING_LIST=" ${VISITING_LIST} "
	VISITING_LIST="${VISITING_LIST/ $tool / }"
	VISITING_LIST=$(echo "$VISITING_LIST" | xargs)

	RESOLVED_LIST="${RESOLVED_LIST} ${tool}"
	RESOLVED_ORDER+=("$tool")
}

get_ordered_tools() {
	local -a current
	readarray -t current < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)

	RESOLVED_ORDER=()
	VISITING_LIST=""
	RESOLVED_LIST=""

	for t in "${current[@]}"; do
		if [[ -n "${t:-}" ]]; then
			resolve_dependencies_rec "$t"
		fi
	done

	printf '%s\n' "${RESOLVED_ORDER[@]}"
}

# ==============================================================================
# 08. CONFLICTS, DRIFT & HEALTH CHECKS
# ==============================================================================

detect_drift() {
	local -a current
	if is_inside_project; then
		readarray -t current < <(get_managed_tools_list)
	else
		readarray -t current < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)
	fi
	for t in "${current[@]}"; do
		[[ -z "${t:-}" ]] && continue
		local lock_status
		lock_status=$(jq -r ".tools[\"$t\"].status // empty" "$LOCK_FILE" 2>/dev/null || true)
		if [[ "$lock_status" == "removed" || -z "$lock_status" ]]; then
			continue
		fi
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" ]]; then
			local mgr
			mgr=$(c_get "$t" "manager")
			case "$mgr" in
			fnm) if command -v fnm &>/dev/null; then
				local -a installed wanted
				readarray -t installed < <(fnm list 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' || true)
				readarray -t wanted < <(c_get_versions "$t")
				for iv in "${installed[@]}"; do
					local found=false
					for wv in "${wanted[@]}"; do
						if [[ "$iv" == "$wv"* ]]; then
							found=true
							break
						fi
					done
					if [[ "$found" == "false" && -n "${iv:-}" ]]; then
						c_add_version "$t" "$iv"
						update_lock_entry "$t" "$iv" "installed"
					fi
				done
			fi ;;
			sdkman) if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
				local active
				active=$(readlink "$SDKMAN_DIR/candidates/java/current" 2>/dev/null | xargs basename 2>/dev/null || true)
				local -a wanted
				readarray -t wanted < <(c_get_versions "$t")
				local match=false
				for wv in "${wanted[@]}"; do
					if [[ "$active" == "$wv"* ]]; then
						match=true
						break
					fi
				done
				if [[ "$match" == "false" && -n "${active:-}" ]]; then
					c_add_version "$t" "$active"
					update_lock_entry "$t" "$active" "installed"
				fi
			fi ;;
			chruby) if [[ -f "$ENV_FILE" ]]; then
				local env_ruby
				env_ruby=$(grep -oE 'chruby ruby-[0-9.]+' "$ENV_FILE" 2>/dev/null | sed 's/chruby //' || true)
				local -a wanted
				readarray -t wanted < <(c_get_versions "$t")
				local match=false
				for wv in "${wanted[@]}"; do
					if [[ "$env_ruby" == "ruby-$wv" ]]; then
						match=true
						break
					fi
				done
				if [[ "$match" == "false" && -n "${env_ruby:-}" ]]; then
					local active_installed=""
					for wv in "${wanted[@]}"; do
						if [[ -d "$HOME/.rubies/ruby-$wv" ]]; then
							active_installed="$wv"
						fi
					done
					if [[ -z "$active_installed" && ${#wanted[@]} -gt 0 ]]; then
						active_installed="${wanted[-1]}"
					fi
					if [[ -n "$active_installed" ]]; then
						pf_rm_pat "chruby ruby-"
						pf_add "chruby ruby-$active_installed &>/dev/null || true"
					fi
				fi
			fi ;;
			esac
		elif [[ "$type" == "formula" || "$type" == "cask" || "$type" == "gem" ]]; then
			if ! health_check "$t" "$type" &>/dev/null; then
				update_lock_entry "$t" "" "removed"
			fi
		fi
	done
	local java_lock_status
	java_lock_status=$(jq -r '.tools["java"].status // empty' "$LOCK_FILE" 2>/dev/null || true)
	if [[ "$java_lock_status" == "installed" || "$java_lock_status" == "updated" ]]; then
		if [[ -f "$ENV_FILE" ]]; then
			local env_java
			env_java=$(grep -oE 'JAVA_HOME="[^"]+"' "$ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
			env_java="${env_java//\$HOME/$HOME}"
			if [[ -n "${env_java:-}" && -d "$SDKMAN_DIR/candidates/java/current" ]]; then
				local real_env real_cur
				real_env=$(cd "$env_java" 2>/dev/null && pwd -P || true)
				real_cur=$(cd "$SDKMAN_DIR/candidates/java/current" 2>/dev/null && pwd -P || true)
				if [[ -n "${real_env:-}" && -n "${real_cur:-}" && "$real_env" != "$real_cur" ]]; then
					pf_set_env "JAVA_HOME" "\$HOME/.sdkman/candidates/java/current"
				fi
			fi
		fi
	fi
	return 0
}

health_check() {
	local tool="$1"
	local type="$2"
	local bp
	case "$type" in
	formula)
		local cmd="$tool"
		if [[ "$tool" == "rust" ]]; then
			cmd="rustc"
		fi
		bp=$(command -v "$cmd" 2>/dev/null || true)
		if [[ -z "${bp:-}" || ! -x "$bp" ]]; then
			return 1
		fi
		;;
	cask)
		if brew list --cask "$tool" &>/dev/null; then
			return 0
		fi
		local app_name=""
		case "$tool" in
		android-studio)
			app_name="Android Studio.app"
			;;
		visual-studio-code)
			app_name="Visual Studio Code.app"
			;;
		reactotron)
			app_name="Reactotron.app"
			;;
		esac
		if [[ -n "$app_name" ]]; then
			if [[ -d "/Applications/$app_name" || -d "$HOME/Applications/$app_name" ]]; then
				return 0
			fi
		fi
		return 1
		;;
	managed)
		case "$tool" in
		node)
			command -v node &>/dev/null || return 1
			node -e 'process.exit(0)' 2>/dev/null || return 1
			;;
		yarn)
			command -v yarn &>/dev/null || return 1
			[[ "$(yarn -v 2>/dev/null)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
			;;
		java)
			"$BREW_BASH" -c "
				set +u
				[[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null
				command -v java &>/dev/null && java -version 2>&1 | grep -qi 'openjdk'
			" 2>/dev/null || return 1
			;;
		ruby)
			run_in_ruby_env "
				rp=\$(which ruby 2>/dev/null || true)
				[[ -n \"\$rp\" && \"\$rp\" != '/usr/bin/ruby' && \"\$rp\" != /System/Library/Frameworks/Ruby.framework/* ]]
			" 2>/dev/null || return 1
			;;
		xcode)
			xcode-select -p &>/dev/null || return 1
			xcodebuild -version &>/dev/null || return 1
			;;
		*)
			return 0
			;;
		esac
		;;
	gem)
		run_in_ruby_env "
            gem list -i '${tool}' &>/dev/null
        " 2>/dev/null || return 1
		;;
	*)
		return 1
		;;
	esac
}

count_installed_tools() {
	local count=0
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	for t in "${tools[@]}"; do
		local type
		type=$(c_get "$t" "type")
		if [[ -n "${type:-}" ]] && health_check "$t" "$type" &>/dev/null; then
			count=$((count + 1))
		fi
	done
	echo "$count"
}

startup_drift_check() {
	detect_drift || true
}

# ==============================================================================
# 09. SNAPSHOT MANAGEMENT
# ==============================================================================

snapshot_export() {
	local output="${1:-$HOME/mac-dev-snapshot.json}"
	local snapshot first=true
	snapshot='{"generated_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","arch":"'$(uname -m)'","tools":{'
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	for t in "${tools[@]}"; do
		local type resolved=""
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" ]]; then
			local mgr
			mgr=$(c_get "$t" "manager")
			case "$mgr" in
			fnm)
				resolved=$(fnm default 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
				;;
			sdkman)
				resolved=$(readlink "$SDKMAN_DIR/candidates/java/current" 2>/dev/null | xargs basename 2>/dev/null || true)
				;;
			chruby)
				resolved=$(grep -oE 'chruby ruby-[0-9.]+' "$ENV_FILE" 2>/dev/null | sed 's/chruby ruby-//' || true)
				;;
			corepack)
				resolved=$(yarn -v 2>/dev/null || true)
				;;
			xcodes)
				resolved=$(xcodebuild -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
				;;
			esac
		elif [[ "$type" == "gem" ]]; then
			resolved=$(run_in_ruby_env "gem list -e '${t}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>/dev/null || true)
		else
			resolved=$(brew list --versions "$t" 2>/dev/null | awk '{print $NF}' | head -1 || true)
		fi

		if [[ -z "${resolved:-}" ]]; then
			continue
		fi

		if [[ "$first" == "true" ]]; then
			first=false
		else
			snapshot+=","
		fi
		snapshot+="\"$t\":\"$resolved\""
	done
	snapshot+='}}'
	echo "$snapshot" | jq '.' >"$output"
	msg "$C_G" "✅ Snapshot: $output"
}

snapshot_import() {
	local input="${1:-}"
	[[ -z "${input:-}" || ! -f "$input" ]] && err "Snapshot não encontrado"
	jq -e '.tools | type == "object"' "$input" >/dev/null 2>&1 || err "Snapshot inválido"
	local -a snap_tools
	readarray -t snap_tools < <(jq -r '.tools | keys[]' "$input" 2>/dev/null || true)
	for t in "${snap_tools[@]}"; do
		local ver
		ver=$(jq -r ".tools[\"$t\"]" "$input" 2>/dev/null || true)
		[[ -z "${ver:-}" || "$ver" == "null" ]] && continue
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" ]]; then
			_jq_update "del(.tools[\"$t\"].version) | .tools[\"$t\"].versions = [\"$ver\"]"
		else
			_jq_update ".tools[\"$t\"].version = \"$ver\""
		fi
	done
	msg "$C_G" "✅ Snapshot importado."
}

# ==============================================================================
# 10. PROCESS RUNNERS & JOB CONTROLLERS
# ==============================================================================

spin_with_context() {
	local pid=$1 m=$2 out_f=$3 err_f=$4 ctx=$5 s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 status=0
	while kill -0 "$pid" 2>/dev/null; do
		i=$(((i + 1) % 10))
		local max_len=$((TERM_WIDTH - 35))
		[[ $max_len -lt 10 ]] && max_len=10
		local last_line=""
		if [[ -f "$out_f" ]]; then
			last_line=$(tail -n 1 "$out_f" 2>/dev/null | tr -d '\r\n' | cut -c 1-$max_len || true)
		fi
		if [[ -n "${last_line:-}" ]]; then
			printf "\r  %b%s%b  %-12s %b%s%b: %s\033[K" "$C_Y" "${s:$i:1}" "$C_RESET" "$m" "$C_D" "$ctx" "$C_RESET" "$last_line" >&2
		else
			printf "\r  %b%s%b  %-12s %b%s%b\033[K" "$C_Y" "${s:$i:1}" "$C_RESET" "$m" "$C_D" "$ctx" "$C_RESET" >&2
		fi
		sleep 0.1
	done
	wait "$pid" || status=$?
	if [[ $status -eq 0 ]]; then
		printf "\r  %b✔%b  %-12s %b%s%b\033[K\n" "$C_G" "$C_RESET" "$m" "$C_BOLD" "$ctx" "$C_RESET" >&2
		[[ "$VERBOSE" == "1" && -s "$out_f" ]] && cat "$out_f" >&2
	else
		printf "\r  %b✘%b  %-12s %b%s%b\033[K\n" "$C_R" "$C_RESET" "$m" "$C_R" "$ctx" "$C_RESET" >&2
		[[ -s "$err_f" ]] && {
			printf "%b--- STDERR ---%b\n" "$C_D" "$C_RESET" >&2
			cat "$err_f" >&2
			printf "%b--------------%b\n" "$C_D" "$C_RESET" >&2
		}
	fi
	return $status
}

run_bg() {
	local m="$1"
	local ctx="$2"
	shift 2
	local out_f
	local err_f
	out_f=$(mktemp)
	err_f=$(mktemp)
	TMP_FILES+=("$out_f" "$err_f")
	if [[ "$DRY_RUN" == "1" ]]; then
		printf '+ %q
' "$*"
		rm -f "$out_f" "$err_f"
		return 0
	fi
	"$@" >"$out_f" 2>"$err_f" &
	local bg_pid=$!
	local status=0
	spin_with_context "$bg_pid" "$m" "$out_f" "$err_f" "$ctx" || status=$?
	rm -f "$out_f" "$err_f"
	return "$status"
}

run_bg_capture() {
	local m="$1"
	local ctx="$2"
	shift 2
	local out_f
	local err_f
	out_f=$(mktemp)
	err_f=$(mktemp)
	TMP_FILES+=("$out_f" "$err_f")
	"$@" >"$out_f" 2>"$err_f" &
	local bg_pid=$!
	local status=0
	spin_with_context "$bg_pid" "$m" "$out_f" "$err_f" "$ctx" || status=$?
	cat "$out_f"
	rm -f "$out_f" "$err_f"
	return "$status"
}

get_remote_versions() {
	local tool="$1" manager="$2"
	case "$manager" in
	fnm)
		fnm ls-remote 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vru
		;;
	sdkman)
		(
			set +u
			[[ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh" >/dev/null
			sdk list java 2>/dev/null | grep -E '^[[:space:]]*[[:alnum:] .]*\|' | awk -F '|' '{print $6}' | tr -d ' ' | grep -vE '(Identifier|^$)' | sort -Vru || true
		)
		;;
	chruby)
		safe_curl -sL "https://raw.githubusercontent.com/postmodern/ruby-versions/master/ruby/versions.txt" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vru
		;;
	xcodes)
		xcodes list 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]' | sort -Vru
		;;
	corepack)
		safe_curl -sf "https://repo.yarnpkg.com/tags" | jq -r '.tags[]' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vru || true
		;;
	esac
}

run_step() {
	local label="$1" ctx="$2" success_msg="$3" fail_msg="$4" status="$5"
	shift 5
	if [[ "$DRY_RUN" == "1" ]]; then
		printf "+ %q\n" "$*"
		return 0
	fi
	if run_bg "$label" "$ctx" "$@"; then
		audit_log "$status" "$success_msg"
	else
		audit_log failed "$fail_msg"
		return 1
	fi
}

ask_sudo() {
	msg "$C_Y" "🔑 Privilégios necessários:"
	sudo -v
	while true; do
		sudo -n true
		sleep 60
		kill -0 "$$" || exit
	done 2>/dev/null &
}

# ==============================================================================
# 11. PACKAGING SYSTEMS (BREW ENGINE)
# ==============================================================================

generate_brewfile() {
	local mode="${1:-install}"
	local bf="/tmp/mac-dev.Brewfile"
	: >"$bf"
	local -a cur
	if is_inside_project; then
		readarray -t cur < <(get_managed_tools_list)
	else
		readarray -t cur < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)
	fi
	for t in "${cur[@]}"; do
		local lock_status
		lock_status=$(jq -r ".tools[\"$t\"].status // empty" "$LOCK_FILE" 2>/dev/null || true)
		if [[ "$mode" == "update" && "$lock_status" == "removed" ]]; then
			continue
		fi
		local tp
		tp=$(c_get "$t" "type")
		case "$tp" in
		formula)
			echo "brew \"$t\"" >>"$bf"
			;;
		cask)
			echo "cask \"$t\"" >>"$bf"
			;;
		esac
	done
	echo "$bf"
}

run_brew_bundle() {
	local mode="${1:-install}"
	local bf
	bf=$(generate_brewfile "$mode")
	[[ ! -s "$bf" ]] && return 0

	local -a formulas=() casks=() bundled=()
	while IFS= read -r line; do
		[[ -z "${line:-}" ]] && continue
		if [[ "$line" =~ ^brew\ \"(.+)\"$ ]]; then
			formulas+=("${BASH_REMATCH[1]}")
			bundled+=("${BASH_REMATCH[1]}")
		elif [[ "$line" =~ ^cask\ \"(.+)\"$ ]]; then
			casks+=("${BASH_REMATCH[1]}")
			bundled+=("${BASH_REMATCH[1]}")
		fi
	done <"$bf"

	[[ ${#bundled[@]} -eq 0 ]] && {
		rm -f "$bf"
		return 0
	}

	local total=${#bundled[@]}
	printf '\n'
	printf '  %b┌──────────────────────────────────────────────┐%b\n' "$C_C" "$C_RESET"
	printf '  %b│  📦  Brew Bundle — Instalação em lote        │%b\n' "$C_C" "$C_RESET"
	printf '  %b│  %b%d ferramenta(s)%b serão instaladas via Brew  %b│%b\n' \
		"$C_C" "$C_W" "$total" "$C_RESET" "$C_C" "$C_RESET"
	printf '  %b└──────────────────────────────────────────────┘%b\n' "$C_C" "$C_RESET"

	if [[ ${#formulas[@]} -gt 0 ]]; then
		printf '\n  %b🍺 Fórmulas:%b\n' "$C_Y" "$C_RESET"
		for f in "${formulas[@]}"; do
			printf '     %b▸%b %s\n' "$C_C" "$C_RESET" "$f"
		done
	fi
	if [[ ${#casks[@]} -gt 0 ]]; then
		printf '\n  %b🖥  Casks (apps):%b\n' "$C_B" "$C_RESET"
		for c in "${casks[@]}"; do
			printf '     %b▸%b %s\n' "$C_C" "$C_RESET" "$c"
		done
	fi
	printf '\n'

	if [[ "$DRY_RUN" == "1" ]]; then
		cat "$bf"
		rm -f "$bf"
		return 0
	fi

	if run_bg "Brew Bundle" "formulas+casks" brew bundle --file="$bf" --no-upgrade --verbose; then
		for t in "${bundled[@]}"; do
			local bv
			bv=$(brew list --versions "$t" 2>/dev/null | awk '{print $NF}' | head -1 || true)
			if [[ -n "${bv:-}" ]]; then
				c_set_version "$t" "$bv"
			fi
		done
		printf '  %b✅ Brew Bundle concluído com sucesso!%b\n\n' "$C_G" "$C_RESET"
	else
		warn "Bundle falhou. Fallback individual."
		rm -f "$bf"
		return 1
	fi
	rm -f "$bf"
}

# ==============================================================================
# 12. FEATURE OPERATIONS (INSTALL, UPDATE, UNINSTALL)
# ==============================================================================

install_managed() {
	local tool="$1" manager="$2" mode="$3" sel_ver="${4:-}"
	local -a versions
	if [[ -n "${sel_ver:-}" ]]; then
		versions+=("$sel_ver")
	else
		readarray -t versions < <(c_get_versions "$tool")
	fi
	brew list "$tool" &>/dev/null && run_bg "Limpando" "$tool" brew uninstall --force "$tool" || true

	case "$manager" in
	fnm)
		command -v fnm &>/dev/null || retry 3 brew install fnm
		pf_rm_pat "fnm env"
		pf_add "if command -v fnm &>/dev/null; then eval \"\$(fnm env --use-on-cd --log-level=quiet)\"; fi"
		eval "$(fnm env)" || true
		;;
	sdkman)
		[[ -d "$SDKMAN_DIR" ]] || retry 3 "$BREW_BASH" -c "curl -sL 'https://get.sdkman.io?rcupdate=false' | '$BREW_BASH'"
		sed -i '' 's/sdkman_auto_answer=false/sdkman_auto_answer=true/g' "$SDKMAN_DIR/etc/config" 2>/dev/null || true
		sed -i '' 's/sdkman_auto_env=true/sdkman_auto_env=false/g' "$SDKMAN_DIR/etc/config" 2>/dev/null || true
		pf_set_env "SDKMAN_DIR" "\$HOME/.sdkman"
		pf_add "[[ -s \"\$SDKMAN_DIR/bin/sdkman-init.sh\" ]] && source \"\$SDKMAN_DIR/bin/sdkman-init.sh\""
		pf_set_env "JAVA_HOME" "\$HOME/.sdkman/candidates/java/current"
		;;
	chruby)
		command -v chruby-exec &>/dev/null || retry 3 brew install chruby ruby-install
		pf_add "source $BREW_PREFIX/opt/chruby/share/chruby/chruby.sh"
		pf_add "source $BREW_PREFIX/opt/chruby/share/chruby/auto.sh"
		;;
	corepack)
		command -v corepack &>/dev/null || retry 3 npm install -g corepack@latest
		corepack enable &>/dev/null || true
		;;
	xcodes) command -v xcodes &>/dev/null || retry 3 brew install xcodes ;;
	esac

	local fetch_latest=false
	if [[ -z "${sel_ver:-}" ]]; then
		if [[ "$mode" == "update" || ("$mode" == "install" && ${#versions[@]} -eq 0) ]]; then
			fetch_latest=true
		fi
		if [[ -f package.json ]]; then
			local pv=""
			if [[ "$tool" == "node" ]]; then
				pv=$(jq -r '.engines.node | match("[0-9]+").string' package.json 2>/dev/null || true)
			fi
			if [[ "$tool" == "yarn" ]]; then
				pv=$(jq -r '.packageManager | capture("yarn@\\^?(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)").v' package.json 2>/dev/null || true)
			fi
			if [[ -n "${pv:-}" && "$pv" != "null" ]]; then
				versions+=("$pv")
			fi
		fi
	fi
	if [[ "$fetch_latest" == "true" ]]; then
		local lv=""
		case "$manager" in
		fnm) lv=$(fnm ls-remote --lts 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/v//' || echo "") ;;
		sdkman) lv=$("$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null && sdk list java 2>/dev/null | grep -i 'zulu' | grep -vE '(ea|fx)' | awk '{print \$NF}' | sort -V | tail -1 | grep -oE '^[0-9]+'" 2>/dev/null || echo "") ;;
		chruby) lv=$(safe_curl -sL "https://raw.githubusercontent.com/postmodern/ruby-versions/master/ruby/versions.txt" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 2>/dev/null || echo "3.3.1") ;;
		corepack) lv=$(safe_curl -sf "https://repo.yarnpkg.com/tags" | jq -r '.latest.stable // empty' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' 2>/dev/null || echo "") ;;
		xcodes) lv=$(xcodes list 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)? ' | grep -vE '(Beta|RC)' | sort -Vr | head -1 | awk '{print $1}' 2>/dev/null || echo "") ;;
		esac
		if [[ -n "${lv:-}" && "$lv" != "null" ]]; then
			versions+=("$lv")
		fi
	fi

	local -a uv=()
	if [[ ${#versions[@]} -gt 0 ]]; then
		while IFS= read -r v; do
			if [[ -n "${v:-}" ]]; then
				uv+=("$v")
			fi
		done < <(printf "%s\n" "${versions[@]}" | sort -Vu)
	fi

	case "$manager" in
	fnm)
		for v in "${uv[@]}"; do
			local iv success=false
			iv=$(fnm list 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | grep -E "^v?${v}" | head -1 || true)
			if [[ -n "${iv:-}" ]]; then
				printf '\r%s✓ Node %s ok%s\n' "${C_D}" "$iv" "${C_RESET}"
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "Node $iv"
				else
					audit_log skipped "Node $iv"
				fi
				success=true
			else
				if run_step "Instalando" "Node $v" "Node $v" "Node $v" "installed" fnm install "$v"; then
					success=true
				fi
			fi
			if [[ "$success" == "true" ]]; then
				fnm default "$v" &>/dev/null || true
				register_tool_state "$tool" "$v" "installed"
			fi
		done
		;;
	sdkman)
		for v in "${uv[@]}"; do
			local ex success=false
			ex=$("$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk list java 2>/dev/null | grep -i 'zulu' | grep -vE '(ea|fx)' | awk '{print \$NF}' | grep -E '^${v}(\.|$)' | sort -V | tail -1" || true)
			if [[ -z "${ex:-}" ]]; then
				ex=$("$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk list java 2>/dev/null | grep -vE '(ea|fx)' | awk '{print \$NF}' | grep -E '^${v}(\.|$)' | sort -V | tail -1" 2>/dev/null || echo "")
			fi

			if [[ -n "${ex:-}" ]]; then
				if [[ -d "$SDKMAN_DIR/candidates/java/$ex" ]]; then
					printf '\r%s✓ Java %s ok%s\n' "${C_D}" "$ex" "${C_RESET}"
					if [[ "$mode" == "update" ]]; then
						audit_log uptodate "Java $ex"
					else
						audit_log skipped "Java $ex"
					fi
					success=true
				else
					if run_step "Instalando" "Java $v" "Java $ex" "Java $ex" "installed" "$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk install java '$ex'"; then
						success=true
					fi
				fi
				if [[ "$success" == "true" ]]; then
					"$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk default java '$ex' &>/dev/null" || true
					c_add_version "$tool" "$v"
					update_lock_entry "$tool" "$ex" "installed"
				fi
			else
				warn "Versão $v de Java não foi encontrada no catálogo do SDKMAN."
				audit_log failed "Java $v (não encontrada)"
			fi
		done
		;;
	chruby)
		for v in "${uv[@]}"; do
			local success=false
			if [[ ! -x "$HOME/.rubies/ruby-$v/bin/ruby" ]]; then
				if run_step "Instalando" "Ruby $v" "Ruby $v" "Ruby $v" "installed" "$BREW_BASH" -c "set +u; rm -rf \"\$HOME/src/ruby-\$v\"*; [[ -f '$BREW_PREFIX/opt/chruby/share/chruby/chruby.sh' ]] && source '$BREW_PREFIX/opt/chruby/share/chruby/chruby.sh'; ruby-install ruby '$v'"; then
					success=true
				fi
			else
				printf '\r%s✓ Ruby %s ok%s\n' "${C_D}" "$v" "${C_RESET}"
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "Ruby $v"
				else
					audit_log skipped "Ruby $v"
				fi
				success=true
			fi
			if [[ "$success" == "true" ]]; then
				register_tool_state "$tool" "$v" "installed"
				pf_rm_pat "chruby ruby-"
				pf_add "chruby ruby-$v &>/dev/null || true"
			fi
		done
		;;
	corepack)
		for v in "${uv[@]}"; do
			local cy success=false
			cy=$(yarn -v 2>/dev/null || true)
			if [[ "${cy:-}" == "$v" ]]; then
				printf '\r%s✓ Yarn %s ok%s\n' "${C_D}" "$v" "${C_RESET}"
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "Yarn $v"
				else
					audit_log skipped "Yarn $v"
				fi
				register_tool_state "$tool" "$v" "installed"
				continue
			fi
			if [[ "${v:0:1}" == "1" ]]; then
				if run_step "Instalando" "Yarn $v" "Yarn $v" "Yarn $v" "installed" npm install -g "yarn@$v"; then
					success=true
				fi
			else
				if run_step "Instalando" "Yarn $v" "Yarn $v" "Yarn $v" "installed" corepack prepare "yarn@$v" --activate; then
					success=true
				fi
			fi
			if [[ "$success" == "true" ]]; then
				register_tool_state "$tool" "$v" "installed"
			fi
		done
		;;
	xcodes)
		for v in "${uv[@]}"; do
			local ins success=false
			ins=$(xcodes installed 2>/dev/null | grep -E "^$v" || true)
			if [[ -n "${ins:-}" ]]; then
				printf '\r%s✓ Xcode %s ok%s\n' "${C_D}" "$v" "${C_RESET}"
				run_bg "Select" "Xcode $v" sudo xcodes select "$v" &>/dev/null || true
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "Xcode $v"
				else
					audit_log skipped "Xcode $v"
				fi
				success=true
			else
				msg "$C_Y" "⚠️ Xcode $v requer Apple ID (senha + 2FA)"
				printf '  %b📲 A instalação será interativa — insira suas credenciais Apple quando solicitado.%b\n\n' "$C_W" "$C_RESET"
				if [[ "$DRY_RUN" == "1" ]]; then
					printf '+ xcodes install %q --experimental-unxip --no-superuser\n' "$v"
					printf '+ sudo xcode-select -s /Applications/Xcode*.app/Contents/Developer\n'
					success=true
				else
					if xcodes install "$v" --experimental-unxip --no-superuser \
						</dev/tty >/dev/tty 2>/dev/tty; then
						audit_log installed "Xcode $v"
						success=true
					else
						audit_log failed "Xcode $v"
					fi
				fi
			fi
			if [[ "$success" == "true" ]]; then
				register_tool_state "$tool" "$v" "installed"
			fi
		done
		;;
	esac
}

uninstall_managed_version() {
	local tool="$1" manager="$2"
	local -a inst_versions=()
	case "$manager" in
	fnm)
		if command -v fnm &>/dev/null; then
			readarray -t inst_versions < <(fnm list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
		fi
		;;
	sdkman)
		if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
			readarray -t inst_versions < <(ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null || true)
		fi
		;;
	chruby)
		if [[ -d "$HOME/.rubies" ]]; then
			readarray -t inst_versions < <(ls -1 "$HOME/.rubies" | sed 's/ruby-//' 2>/dev/null || true)
		fi
		;;
	xcodes)
		if command -v xcodes &>/dev/null; then
			readarray -t inst_versions < <(xcodes installed 2>/dev/null | awk '{print $1}' || true)
		fi
		;;
	corepack)
		readarray -t inst_versions < <(c_get_versions "$tool")
		;;
	esac

	if [[ ${#inst_versions[@]} -eq 0 ]]; then
		warn "Nenhuma versão de $tool está instalada."
		return 0
	fi

	local -a sorted_inst_versions=()
	readarray -t sorted_inst_versions < <(printf '%s\n' "${inst_versions[@]}" | sort -Vru)

	local choice_output
	choice_output=$(tui_multi_choose "Selecione as versões de $tool para remover:" "${sorted_inst_versions[@]}") || return 0
	local -a selected_vers=()
	while IFS= read -r line; do
		[[ -n "${line:-}" ]] && selected_vers+=("$line")
	done <<<"$choice_output"

	if [[ ${#selected_vers[@]} -eq 0 ]]; then
		if [[ "$HAS_GUM" == "true" ]]; then
			warn "Nenhuma versão selecionada via interface gráfica."
			printf "%bAlternando para seleção manual por números:%b\n" "$C_Y" "$C_RESET"
		fi
		for i in "${!sorted_inst_versions[@]}"; do
			printf '  %d) %s\n' "$((i + 1))" "${sorted_inst_versions[$i]}"
		done
		printf '%s' "${C_DIM}Digite os números das versões (separados por espaço): ${C_RESET}"
		local -a sn
		read -r -a sn </dev/tty
		for s in "${sn[@]}"; do
			local idx=$((s - 1))
			if [[ $idx -ge 0 && $idx -lt ${#sorted_inst_versions[@]} ]]; then
				local val="${sorted_inst_versions[$idx]}"
				if [[ -n "${val:-}" ]]; then
					selected_vers+=("$val")
				fi
			fi
		done
	fi

	if [[ ${#selected_vers[@]} -eq 0 ]]; then
		warn "Nenhuma versão selecionada."
		return 0
	fi

	for v in "${selected_vers[@]}"; do
		case "$manager" in
		fnm)
			run_step "Removendo" "Node $v" "Node $v" "Node $v" "removed" fnm uninstall "$v"
			;;
		sdkman)
			run_step "Removendo" "Java $v" "Java $v" "Java $v" "removed" "$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk uninstall java '$v'"
			;;
		chruby)
			run_step "Removendo" "Ruby $v" "Ruby $v" "Ruby $v" "removed" rm -rf "$HOME/.rubies/ruby-$v"
			;;
		xcodes)
			run_step "Removendo" "Xcode $v" "Xcode $v" "Xcode $v" "removed" sudo xcodes uninstall "$v"
			;;
		corepack)
			run_step "Removendo" "Yarn $v" "Yarn $v" "Yarn $v" "removed" corepack disable "$tool"
			;;
		esac

		_jq_update "del(.tools[\"$tool\"].version) | .tools[\"$tool\"].versions = (.tools[\"$tool\"].versions - [\"$v\"])"
	done

	local -a rem_versions=()
	readarray -t rem_versions < <(c_get_versions "$tool")
	if [[ ${#rem_versions[@]} -eq 0 ]]; then
		update_lock_entry "$tool" "" "removed"
	else
		update_lock_entry "$tool" "${rem_versions[-1]}" "installed"
	fi
}

process_tool() {
	local tool="$1" mode="$2" type
	local SELECTIVE_MODE="${SELECTIVE_MODE:-false}"
	type=$(c_get "$tool" "type")
	((++CURRENT_TOOL_INDEX))
	print_progress_bar "$CURRENT_TOOL_INDEX" "$TOTAL_TOOLS" "$tool"
	if [[ "$mode" == "uninstall" ]]; then
		if [[ "$SELECTIVE_MODE" == "true" && "$type" == "managed" ]]; then
			uninstall_managed_version "$tool" "$(c_get "$tool" "manager")"
			return 0
		fi
		c_clear_versions "$tool"
		case "$tool" in
		java)
			pf_rm_pat "JAVA_HOME"
			;;
		android-studio)
			pf_rm_pat "ANDROID_HOME"
			;;
		esac
		case "$type" in
		cask)
			run_step "Removendo" "$tool" "$tool" "$tool" "removed" brew uninstall --cask --force "$tool" || audit_log missing "$tool"
			;;
		gem)
			if command -v gem &>/dev/null; then
				run_step "Removendo" "$tool" "$tool" "$tool" "removed" gem uninstall "$tool" -a -x || audit_log missing "$tool"
			else
				printf '\r  %b✔%b  %-12s %b%s%b\n' "$C_G" "$C_RESET" "Removendo" "$C_BOLD" "$tool" "$C_RESET"
				audit_log removed "$tool"
			fi
			;;
		managed)
			local mgr
			mgr=$(c_get "$tool" "manager")
			case "$mgr" in
			sdkman)
				run_step "Removendo" "$tool" "versões do Java" "versões do Java" "removed" rm -rf "$SDKMAN_DIR/candidates/java" || audit_log missing "$tool"
				;;
			fnm)
				run_step "Removendo" "$tool" "versões do Node" "versões do Node" "removed" rm -rf "$HOME/.local/share/fnm/node-versions" "$HOME/.local/share/fnm/aliases" || audit_log missing "$tool"
				;;
			chruby)
				run_step "Removendo" "$tool" "versões do Ruby" "versões do Ruby" "removed" rm -rf "$HOME/.rubies" || audit_log missing "$tool"
				;;
			xcodes)
				local -a x_vers=()
				if command -v xcodes &>/dev/null; then
					readarray -t x_vers < <(xcodes installed 2>/dev/null | awk '{print $1}' || true)
					for xv in "${x_vers[@]}"; do
						if [[ -n "${xv:-}" ]]; then
							run_step "Removendo" "Xcode $xv" "Xcode $xv" "Xcode $xv" "removed" sudo xcodes uninstall "$xv" || true
						fi
					done
				fi
				;;
			corepack)
				run_step "Removendo" "$tool" "Yarn" "Yarn" "removed" rm -rf "$HOME/.yarn" "$HOME/.config/yarn" || audit_log missing "$tool"
				;;
			*)
				run_step "Removendo" "$tool" "$tool" "$tool" "removed" brew uninstall --force "$mgr" || audit_log missing "$tool"
				;;
			esac
			;;
		*)
			run_step "Removendo" "$tool" "$tool" "$tool" "removed" brew uninstall --force "$tool" || audit_log missing "$tool"
			;;
		esac
		update_lock_entry "$tool" "" "removed"
		return 0
	fi
	local fv=""
	if [[ "$type" == "managed" ]]; then
		local target_ver=""
		if [[ "$SELECTIVE_MODE" == "true" ]]; then
			local mgr
			mgr=$(c_get "$tool" "manager")
			local versions_str
			versions_str=$(run_bg_capture "Buscando" "versões remotas de $tool" get_remote_versions "$tool" "$mgr") || true
			local -a rem_versions=()
			if [[ -n "${versions_str:-}" ]]; then
				readarray -t rem_versions <<<"$versions_str"
			fi
			local -a clean_rem_versions=()
			for v in "${rem_versions[@]}"; do
				[[ -n "${v:-}" ]] && clean_rem_versions+=("$v")
			done
			if [[ ${#clean_rem_versions[@]} -gt 0 ]]; then
				local -a choose_opts=("padrão (LTS / mais recente)")
				choose_opts+=("${clean_rem_versions[@]}")
				local selected_choice
				selected_choice=$(tui_choose "Selecione a versão de $tool a instalar/atualizar:" "${choose_opts[@]}") || return 0
				if [[ "$selected_choice" == "padrão (LTS / mais recente)" ]]; then
					target_ver=""
				else
					target_ver="$selected_choice"
				fi
			else
				target_ver=$(tui_input "Falha ao buscar versões. Digite a versão de $tool a instalar/atualizar (deixe em branco para padrão):")
			fi
		fi
		install_managed "$tool" "$(c_get "$tool" "manager")" "$mode" "${target_ver:-}"
		fv=$(c_get_versions "$tool" | tail -1)
	elif [[ "$type" == "gem" ]]; then
		local ce
		ce="set +u; [[ -f '$BREW_PREFIX/opt/chruby/share/chruby/chruby.sh' ]] && source '$BREW_PREFIX/opt/chruby/share/chruby/chruby.sh' && chruby \$(chruby | sed 's/ \*//' | sort -V | tail -1)"
		if ! "$BREW_BASH" -c "${ce}; gem list -i '${tool}' &>/dev/null" 2>/dev/null; then
			run_step \
				"Instalando" \
				"$tool" \
				"Gem $tool" \
				"Gem $tool" \
				"installed" \
				"$BREW_BASH" \
				-c "${ce}; gem install '$tool' --no-document" || true
		else
			printf '\r%s✓ Gem %s ok%s\n' \
				"${C_D}" \
				"$tool" \
				"${C_RESET}"
			if [[ "$mode" != "update" ]]; then
				audit_log skipped "Gem $tool"
			fi
		fi
		if [[ "$mode" == "update" ]]; then
			local bv av
			bv=$(
				"$BREW_BASH" -c "${ce}; gem list '$tool' --exact 2>/dev/null |
				grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
				head -1" || true
			)
			if run_bg "Update" "$tool" "$BREW_BASH" -c "${ce}; gem update '$tool' --no-document"; then
				av=$(
					"$BREW_BASH" -c "${ce}; gem list '$tool' --exact 2>/dev/null |
					grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
					head -1" || true
				)
				if [[ "${bv:-}" != "${av:-}" ]]; then
					audit_log updated "Gem $tool ${bv:-}→${av:-}"
				else
					audit_log uptodate "Gem $tool"
				fi
			else
				audit_log failed "Gem $tool"
			fi
		fi
		fv=$(
			"$BREW_BASH" -c "${ce}; gem list -e '${tool}' |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
			head -1" || true
		)
		[[ -n "${fv:-}" ]] && c_set_version "$tool" "$fv"
	else
		local bh=false
		if [[ "$mode" == "install" ]]; then
			local bvc=""
			if [[ "$type" == "cask" ]]; then
				bvc=$(brew list --cask --versions "$tool" 2>/dev/null | awk '{print $NF}' | head -1 || true)
			else
				bvc=$(brew list --versions "$tool" 2>/dev/null | awk '{print $NF}' | head -1 || true)
			fi
			if [[ -n "${bvc:-}" ]]; then
				bh=true
			fi
		fi
		if [[ "$bh" == "true" ]]; then
			printf '\r%s✓ %s (bundle)%s\n' \
				"${C_D}" \
				"$tool" \
				"${C_RESET}"
			if [[ "${ALREADY_INSTALLED[$tool]:-}" == "true" ]]; then
				audit_log skipped "$tool (bundle)"
			else
				audit_log installed "$tool (bundle)"
			fi
			if [[ "$type" == "cask" ]]; then
				fv=$(brew list --cask --versions "$tool" 2>/dev/null | awk '{print $NF}' | head -1 || true)
			else
				fv=$(brew list --versions "$tool" 2>/dev/null | awk '{print $NF}' | head -1 || true)
			fi
		elif brew list "${type:+--$type}" "$tool" &>/dev/null; then
			if [[ "$mode" == "update" ]]; then
				local bv av
				if [[ "$type" == "cask" ]]; then
					bv=$(brew list --cask --versions "$tool" 2>/dev/null | awk '{print $NF}' 2>/dev/null || echo "")
				else
					bv=$(brew list --versions "$tool" 2>/dev/null | awk '{print $NF}' 2>/dev/null || echo "")
				fi
				if run_bg "Update" "$tool" brew upgrade "${type:+--$type}" "$tool"; then
					if [[ "$type" == "cask" ]]; then
						av=$(brew list --cask --versions "$tool" 2>/dev/null | awk '{print $NF}' 2>/dev/null || echo "")
					else
						av=$(brew list --versions "$tool" 2>/dev/null | awk '{print $NF}' 2>/dev/null || echo "")
					fi
					if [[ "${bv:-}" != "${av:-}" ]]; then
						audit_log updated "$tool ${bv:-}→${av:-}"
					else
						audit_log uptodate "$tool"
					fi
				else
					audit_log failed "$tool"
				fi
			else
				printf '\r%s✓ %s ok%s\n' \
					"${C_D}" \
					"$tool" \
					"${C_RESET}"
				if [[ "${ALREADY_INSTALLED[$tool]:-}" == "true" ]]; then
					audit_log skipped "$tool"
				else
					audit_log installed "$tool"
				fi
			fi
		else
			run_step \
				"Instalando" \
				"$tool" \
				"$tool" \
				"$tool" \
				"installed" \
				brew install "${type:+--$type}" "$tool" || true
		fi
		fv=$(brew list --versions "$tool" 2>/dev/null | awk '{print $NF}' | head -1 || true)
	fi
	if [[ "$type" != "managed" && -n "${fv:-}" ]]; then
		c_set_version "$tool" "$fv"
	fi
	if [[ "$mode" != "uninstall" ]] && ! health_check "$tool" "$type"; then
		audit_log failed "$tool (health)"
		warn "Health check falhou: $tool"
	fi
	local st="installed"
	if [[ "$mode" == "update" ]]; then
		st="updated"
	fi
	update_lock_entry "$tool" "${fv:-}" "$st"
	if [[ "$tool" == "android-studio" ]]; then
		pf_set_env "ANDROID_HOME" "$HOME/Library/Android/Sdk"
		pf_rm_pat "ANDROID_HOME/emulator"
		pf_add "export PATH=\"\$ANDROID_HOME/emulator:\$ANDROID_HOME/platform-tools:\$PATH\""
	fi
	if [[ "$tool" == "xcode" && "$mode" != "uninstall" ]]; then
		run_bg "License" "Xcode" sudo xcodebuild -license accept || true
		local xp
		xp=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)
		[[ -n "${xp:-}" ]] && run_bg "Select" "Xcode" sudo xcode-select -s "$xp/Contents/Developer" || true
	fi
}

remove_untracked_versions() {
	local tool="$1"
	local type
	type=$(c_get "$tool" "type")
	[[ "$type" != "managed" && "$type" != "gem" ]] && return 0
	if [[ "$type" == "managed" ]]; then
		local mgr
		local -a wv
		local -a inst=()
		mgr=$(c_get "$tool" "manager")
		readarray -t wv < <(c_get_versions "$tool")
		case "$mgr" in
		fnm)
			readarray -t inst < <(
				fnm list 2>/dev/null |
					grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
					sed 's/^v//' || true
			)
			;;
		sdkman)
			readarray -t inst < <(
				find "$SDKMAN_DIR/candidates/java" \
					-mindepth 1 \
					-maxdepth 1 \
					-type d \
					! -name 'current' \
					-exec basename {} \; 2>/dev/null || true
			)
			;;
		chruby)
			readarray -t inst < <(
				find "$HOME/.rubies" \
					-mindepth 1 \
					-maxdepth 1 \
					-type d \
					-name 'ruby-*' \
					-exec basename {} \; 2>/dev/null |
					sed 's/ruby-//' || true
			)
			;;
		xcodes)
			readarray -t inst < <(
				xcodes installed 2>/dev/null |
					awk '{print $1}' || true
			)
			;;
		corepack)
			readarray -t inst < <(
				npm ls -g yarn 2>/dev/null |
					grep -oE 'yarn@[0-9]+\.[0-9]+\.[0-9]+' |
					sed 's/yarn@//' || true
			)
			;;
		esac
		for iv in "${inst[@]}"; do
			local keep=false
			for w in "${wv[@]}"; do
				if [[ "$iv" == "$w"* ]]; then
					keep=true
					break
				fi
			done
			if [[ "$keep" == "false" && -n "${iv:-}" ]]; then
				case "$mgr" in
				fnm)
					run_bg "RM Node" "$iv" fnm uninstall "$iv" || true
					;;
				sdkman)
					run_bg \
						"RM Java" \
						"$iv" \
						"$BREW_BASH" \
						-c "
                                set +u
                                [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] &&
                                source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null
                                sdk uninstall java '$iv'
                            " || true
					;;
				chruby)
					run_bg \
						"RM Ruby" \
						"$iv" \
						rm -rf "$HOME/.rubies/ruby-$iv" "$HOME/src/ruby-$iv"* || true
					;;
				xcodes)
					run_bg "RM Xcode" "$iv" xcodes uninstall "$iv" || true
					;;
				corepack)
					if [[ "${iv%%.*}" == "1" ]]; then
						run_bg "RM Yarn" "$iv" npm uninstall -g "yarn" || true
					fi
					;;
				esac
				update_lock_entry "$tool" "" "removed"
			fi
		done
	elif [[ "$type" == "gem" ]]; then
		local wanted
		local -a inst
		wanted=$(c_get "$tool" "version")
		[[ -z "${wanted:-}" ]] && return 0
		readarray -t inst < <(
			run_in_ruby_env "gem list -e '${tool}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'" || true
		)
		for iv in "${inst[@]}"; do
			if [[ -n "${iv:-}" && "$iv" != "$wanted" ]]; then
				run_bg "RM Gem" "$tool $iv" run_in_ruby_env "gem uninstall '$tool' -v '$iv' -x" || true
				update_lock_entry "$tool" "" "removed"
			fi
		done
	fi
}

# ==============================================================================
# 13. CACHE PURGING & SYSTEM CLEANUP
# ==============================================================================

clean_rn_job() {
	rm -rf ~/.gradle/caches/* \
		~/.android/build-cache \
		~/Library/Developer/Xcode/DerivedData/* \
		~/Library/Caches/CocoaPods \
		"$TMPDIR"/metro-* \
		"$TMPDIR"/react-* 2>/dev/null || true
}

clean_install_caches_job() {
	rm -rf ~/Library/Caches/Homebrew/* \
		"$SDKMAN_DIR/archives/"* \
		"$SDKMAN_DIR/tmp/"* \
		~/src/ruby-* \
		~/.cache/ruby-install/* \
		~/Library/Caches/org.xcodes.xcodes/* \
		~/Library/Application\ Support/xcodes/*.xip \
		/tmp/xcodes* 2>/dev/null || true
}

clean_profiles_job() {
	pf_rm_pat "ANDROID_HOME"
	pf_rm_pat "JAVA_HOME"
	pf_rm_pat "fnm"
	pf_rm_pat "chruby"
	pf_rm_pat "sdkman"
	_scrub_profile_file "$(get_target_rc)"
	_scrub_profile_file "$HOME/.profile"
}

clean_folders_job() {
	rm -rf ~/.nvm \
		~/.nodenv \
		"$SDKMAN_DIR" \
		~/.rubies \
		~/.cache/yarn \
		~/.yarn \
		/Applications/Xcode*.app 2>/dev/null || true
}

rn_cleanup() {
	run_bg "Deep Clean" "Caches" clean_rn_job || true
	run_bg "Installer Clean" "Homebrew/SDK" clean_install_caches_job || true
	command -v npm &>/dev/null && run_bg "NPM" "cache" npm cache clean -f || true
	command -v yarn &>/dev/null && run_bg "Yarn" "cache" yarn cache clean --all || true
	command -v watchman &>/dev/null && run_bg "Watchman" "del-all" watchman watch-del-all || true
	run_bg "Gem" "cleanup" run_in_ruby_env "gem cleanup -q &>/dev/null" || true
	command -v brew &>/dev/null && run_bg "Brew" "prune" brew cleanup --prune=all || true
}

# ==============================================================================
# 14. LOCAL PROJECT CONTEXT & SYNC
# ==============================================================================

load_preset() {
	local preset="${1:-}"
	if [[ -z "$preset" ]]; then
		if [[ "$HAS_GUM" == "true" ]]; then
			local -a pn=()
			while IFS= read -r k; do pn+=("$k"); done < <(list_presets)
			preset=$(tui_choose "📦 Preset:" "${pn[@]}") || return 0
			printf "📦 Preset: %b%s%b\n" "$C_C" "$preset" "$C_RESET"
		else
			printf '\n%s\n' "${C_C}Presets:${C_RESET}"
			while IFS= read -r k; do
				local tools_desc
				tools_desc=$(get_preset_tools "$k" 2>/dev/null || true)
				printf '  %s%s%s: %s\n' "${C_W}" "$k" "${C_RESET}" "$tools_desc"
			done < <(list_presets)
			preset=$(tui_input "Preset: " "rn")
		fi
	fi
	local preset_tools
	preset_tools=$(get_preset_tools "$preset" 2>/dev/null || true)
	[[ -z "${preset_tools:-}" ]] && err "Preset desconhecido: $preset"
	confirm_destructive "Substituir catálogo com preset '$preset'?" || return 0
	msg "$C_C" "📦 Loading: $preset"
	local nc="{\"schema_version\":$CATALOG_SCHEMA_VERSION,\"tools\":{" first=true
	for t in $preset_tools; do
		[[ "$first" == "true" ]] && first=false || nc+=","
		local mgr
		mgr=$(get_known_managed "$t" 2>/dev/null || true)
		if [[ -n "${mgr:-}" ]]; then
			nc+="\"$t\":{\"type\":\"managed\",\"manager\":\"$mgr\",\"versions\":[]}"
		else
			case "$t" in
			visual-studio-code | reactotron | android-studio) nc+="\"$t\":{\"type\":\"cask\",\"version\":\"\"}" ;;
			cocoapods) nc+="\"$t\":{\"type\":\"gem\",\"version\":\"\"}" ;;
			*) nc+="\"$t\":{\"type\":\"formula\",\"version\":\"\"}" ;;
			esac
		fi
	done
	nc+="}}"
	echo "$nc" | jq '.' >"$CATALOG_FILE"
	msg "$C_G" "✅ Catálogo atualizado com o preset '$preset'."
}

is_tool_version_installed() {
	local tool="$1" ver="$2"
	local type
	type=$(c_get "$tool" "type")
	[[ -z "$type" ]] && return 1

	if ! health_check "$tool" "$type" &>/dev/null; then
		return 1
	fi

	[[ -z "$ver" ]] && return 0

	if [[ "$type" == "managed" ]]; then
		local mgr
		mgr=$(c_get "$tool" "manager")
		case "$mgr" in
		fnm)
			if command -v fnm &>/dev/null; then
				fnm list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | grep -qE "^$ver(\.|$)" && return 0
			fi
			;;
		sdkman)
			if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
				ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null | grep -qE "^$ver(\.|-|$)" && return 0
			fi
			;;
		chruby)
			if [[ -d "$HOME/.rubies" ]]; then
				ls -1 "$HOME/.rubies" 2>/dev/null | sed 's/ruby-//' | grep -qE "^$ver(\.|$)" && return 0
			fi
			;;
		xcodes)
			if command -v xcodes &>/dev/null; then
				xcodes installed 2>/dev/null | awk '{print $1}' | grep -qE "^$ver(\.|$)" && return 0
			fi
			;;
		corepack)
			if command -v yarn &>/dev/null; then
				yarn -v 2>/dev/null | grep -qE "^$ver(\.|$)" && return 0
			fi
			;;
		esac
		return 1
	fi

	return 0
}

ensure_project_version_files() {
	local node_v="${1:-}" ruby_v="${2:-}" java_v="${3:-}"
	local any_created=false

	if [[ -n "$node_v" ]]; then
		local current_nv=""
		[[ -f ".node-version" ]] && current_nv=$(tr -d '[:space:]' <".node-version" 2>/dev/null)
		if [[ "$current_nv" != "$node_v" ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				echo "$node_v" >".node-version"
			fi
			msg "$C_G" "📝 .node-version → $node_v${current_nv:+ (era $current_nv)}"
			any_created=true
		fi
	fi

	if [[ -n "$ruby_v" && ! -f ".ruby-version" ]]; then
		if [[ "$DRY_RUN" != "1" ]]; then
			echo "$ruby_v" >".ruby-version"
		fi
		msg "$C_G" "📝 .ruby-version → $ruby_v"
		any_created=true
	fi

	if [[ -n "$java_v" ]]; then
		local current_jv=""
		[[ -f ".sdkmanrc" ]] && current_jv=$(grep 'java=' .sdkmanrc 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)

		local resolved_java="$java_v"
		if [[ ! "$java_v" == *-* ]]; then
			local local_ex=""
			if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
				local_ex=$(ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null | grep -E "^${java_v}(\.|$)" | grep -v 'current' | sort -V | tail -1 || echo "")
			fi
			if [[ -n "$local_ex" ]]; then
				resolved_java="$local_ex"
			else
				local ex
				ex=$("$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk list java 2>/dev/null | grep -i 'zulu' | grep -vE '(ea|fx)' | awk '{print \$NF}' | grep -E '^${java_v}(\.|$)' | sort -V | tail -1" || true)
				if [[ -n "$ex" ]]; then
					resolved_java="$ex"
				fi
			fi
		fi

		if [[ ! -f ".sdkmanrc" ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				printf 'java=%s\n' "$resolved_java" >".sdkmanrc"
			fi
			msg "$C_G" "📝 .sdkmanrc → java=$resolved_java"
			any_created=true
		elif [[ "$current_jv" != "$resolved_java" && ("$current_jv" == "$java_v" || ! "$current_jv" == *-*) ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				sed -i '' "s/java=.*/java=$resolved_java/g" .sdkmanrc 2>/dev/null || true
			fi
			msg "$C_G" "📝 .sdkmanrc → java=$resolved_java (atualizado de $current_jv)"
			any_created=true
		fi
		if [[ -f "$SDKMAN_DIR/etc/config" ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				grep -q 'sdkman_auto_env=true' "$SDKMAN_DIR/etc/config" 2>/dev/null ||
					sed -i '' 's/sdkman_auto_env=false/sdkman_auto_env=true/g' "$SDKMAN_DIR/etc/config" 2>/dev/null || true
			fi
		fi
	fi

	return 0
}

print_version_activation_hint() {
	printf '\n  %b💡 Para ativar as versões do projeto neste shell:%b\n' "$C_Y" "$C_RESET"
	printf '     %bcd .%b  %b# dispara auto-switch do fnm, chruby e sdkman%b\n\n' "$C_BOLD$C_W" "$C_RESET" "$C_D" "$C_RESET"
}

ensure_corepack_project_yarn() {
	local yarn_v="${1:-}"
	[[ -z "$yarn_v" || ! -f "package.json" ]] && return 0

	# Only for yarn v2+ (v1 uses npm global install)
	local major="${yarn_v%%.*}"
	[[ "$major" -lt 2 ]] 2>/dev/null && return 0

	if [[ "$DRY_RUN" == "1" ]]; then
		msg "$C_G" "📦 corepack → yarn@$yarn_v (simulado)"
		return 0
	fi

	if ! command -v corepack &>/dev/null; then
		command -v npm &>/dev/null && npm install -g corepack@latest &>/dev/null || return 0
	fi

	# Remove npm-installed global yarn — it shadows corepack shims
	if npm list -g --depth=0 yarn 2>/dev/null | grep -q 'yarn@'; then
		msg "$C_C" "🔄 Removendo yarn global (npm) para priorizar corepack..."
		npm uninstall -g yarn &>/dev/null || true
	fi

	# Re-enable corepack shims (recreates yarn/yarnpkg symlinks)
	corepack enable &>/dev/null || true

	# Pre-download and activate the project's yarn version
	corepack prepare "yarn@$yarn_v" --activate &>/dev/null || true
	msg "$C_G" "📦 corepack → yarn@$yarn_v"
}

is_inside_project() {
	[[ "$PWD" == "$HOME" || "$PWD" == "/" ]] && return 1
	if [[ -f "package.json" || -f ".nvmrc" || -f ".node-version" || -f ".ruby-version" || -f ".sdkmanrc" || -f "Gemfile" || -d "android" || -d "ios" || -f "ReactotronConfig.js" || -f "reactotron.config.js" ]]; then
		return 0
	fi
	return 1
}

detect_project_tools() {
	local -a detected=()
	[[ "$PWD" == "$HOME" || "$PWD" == "/" ]] && return 0

	local node_req="" yarn_req="" java_req="" ruby_req=""
	if [[ -f "package.json" ]]; then
		node_req=$(jq -r '.engines.node // empty' package.json 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
		yarn_req=$(jq -r '.packageManager // empty' package.json 2>/dev/null | grep -oE 'yarn@([0-9.]+)' | sed 's/yarn@//' || echo "")
		java_req=$(jq -r '.javaVersion // empty' package.json 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
		ruby_req=$(jq -r '.rubyVersion // empty' package.json 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

		detected+=("node")
		[[ -n "$yarn_req" ]] && detected+=("yarn")
		[[ -n "$java_req" ]] && detected+=("java")
		[[ -n "$ruby_req" ]] && detected+=("ruby")
	fi

	[[ -f ".nvmrc" ]] && detected+=("node")
	[[ -f ".ruby-version" ]] && detected+=("ruby")
	[[ -f ".sdkmanrc" ]] && detected+=("java")

	if [[ -f "yarn.lock" || -f ".yarnrc.yml" ]]; then
		detected+=("yarn")
	fi

	local is_react_native=false
	if [[ -f "package.json" ]]; then
		if jq -e '.dependencies["react-native"] // .devDependencies["react-native"] // empty' package.json &>/dev/null; then
			is_react_native=true
		fi
	fi
	if [[ -f "ReactotronConfig.js" || -f "reactotron.config.js" ]]; then
		is_react_native=true
	fi

	if [[ -d "ios" && -d "android" ]]; then
		detected+=("android-studio" "xcode")
	else
		[[ -d "android" ]] && detected+=("android-studio")
		[[ -d "ios" ]] && detected+=("xcode")
	fi

	local has_xcode=false
	for d in "${detected[@]}"; do
		[[ "$d" == "xcode" ]] && has_xcode=true
	done
	if [[ "$has_xcode" == "true" ]]; then
		detected+=("xcbeautify")
	fi

	if [[ "$is_react_native" == "true" ]]; then
		detected+=("watchman" "reactotron")
	fi

	[[ -f "Gemfile" ]] && detected+=("cocoapods")

	# Clean out go, rust, shfmt, visual-studio-code, and watchman/reactotron if not react-native
	local -a cleaned=()
	for d in "${detected[@]}"; do
		if [[ "$d" != "go" && "$d" != "rust" && "$d" != "shfmt" && "$d" != "visual-studio-code" ]]; then
			if [[ "$d" != "watchman" && "$d" != "reactotron" ]] || [[ "$is_react_native" == "true" ]]; then
				cleaned+=("$d")
			fi
		fi
	done

	if [[ ${#cleaned[@]} -gt 0 ]]; then
		printf '%s\n' "${cleaned[@]}" | sort -u
	fi
}

get_managed_tools_list() {
	local -a tools
	if is_inside_project; then
		local -a proj_tools all_ordered filtered_ordered=()
		readarray -t proj_tools < <(detect_project_tools)
		readarray -t all_ordered < <(get_ordered_tools)
		for ot in "${all_ordered[@]}"; do
			for pt in "${proj_tools[@]}"; do
				if [[ "$ot" == "$pt" ]]; then
					filtered_ordered+=("$ot")
					break
				fi
			done
		done
		printf '%s\n' "${filtered_ordered[@]}"
	else
		get_ordered_tools
	fi
}

sync_project_context() {
	[[ "$PWD" == "$HOME" || "$PWD" == "/" ]] && return 0
	local -a detected=()
	local -a to_merge=()
	local -a to_install=()

	local node_req="" yarn_req="" java_req="" ruby_req=""
	if [[ -f "package.json" ]]; then
		node_req=$(jq -r '.engines.node // empty' package.json 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
		yarn_req=$(jq -r '.packageManager // empty' package.json 2>/dev/null | grep -oE 'yarn@([0-9.]+)' | sed 's/yarn@//' || echo "")
		java_req=$(jq -r '.javaVersion // empty' package.json 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
		ruby_req=$(jq -r '.rubyVersion // empty' package.json 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

		detected+=("node${node_req:+:$node_req}")
		[[ -n "$yarn_req" ]] && detected+=("yarn:$yarn_req")
		[[ -n "$java_req" ]] && detected+=("java:$java_req")
		[[ -n "$ruby_req" ]] && detected+=("ruby:$ruby_req")
	fi

	[[ -f ".nvmrc" ]] && detected+=("node:$(grep -oE '[0-9.]+' .nvmrc | head -1 || echo "")")
	[[ -f ".ruby-version" ]] && detected+=("ruby:$(sed -E 's/^ruby-//;s/[[:space:]]//g' .ruby-version || echo "")")
	[[ -f ".sdkmanrc" ]] && detected+=("java:$(grep 'java=' .sdkmanrc | cut -d= -f2 | tr -d '[:space:]' || echo "")")

	if [[ -f "yarn.lock" || -f ".yarnrc.yml" ]]; then
		local has_yarn=false
		for item in "${detected[@]}"; do
			[[ "${item%%:*}" == "yarn" ]] && has_yarn=true
		done
		[[ "$has_yarn" == "false" ]] && detected+=("yarn")
	fi

	local is_react_native=false
	if [[ -f "package.json" ]]; then
		if jq -e '.dependencies["react-native"] // .devDependencies["react-native"] // empty' package.json &>/dev/null; then
			is_react_native=true
		fi
	fi
	if [[ -f "ReactotronConfig.js" || -f "reactotron.config.js" ]]; then
		is_react_native=true
	fi

	if [[ -d "ios" && -d "android" ]]; then
		detected+=("android-studio" "xcode")
	else
		[[ -d "android" ]] && detected+=("android-studio")
		[[ -d "ios" ]] && detected+=("xcode")
	fi

	local has_xcode=false
	for item in "${detected[@]}"; do
		local tool="${item%%:*}"
		[[ "$tool" == "xcode" ]] && has_xcode=true
	done
	if [[ "$has_xcode" == "true" ]]; then
		detected+=("xcbeautify")
	fi

	if [[ "$is_react_native" == "true" ]]; then
		detected+=("watchman" "reactotron")
	fi

	[[ -f "Gemfile" ]] && detected+=("cocoapods")

	# Clean out go, rust, shfmt, visual-studio-code, and watchman/reactotron if not react-native
	local -a cleaned=()
	for item in "${detected[@]}"; do
		local tool="${item%%:*}"
		if [[ "$tool" != "go" && "$tool" != "rust" && "$tool" != "shfmt" && "$tool" != "visual-studio-code" ]]; then
			if [[ "$tool" != "watchman" && "$tool" != "reactotron" ]] || [[ "$is_react_native" == "true" ]]; then
				cleaned+=("$item")
			fi
		fi
	done
	detected=("${cleaned[@]}")

	[[ ${#detected[@]} -eq 0 ]] && return 0

	# Filter duplicates and select only the highest version for each tool,
	# rewriting the source files of the lower versions to match.
	declare -A max_versions
	declare -A seen_tools
	for item in "${detected[@]}"; do
		local tool="${item%%:*}"
		local ver=""
		if [[ "$item" == *":"* ]]; then
			ver="${item#*:}"
		fi
		if [[ -n "$ver" ]]; then
			local cur_max="${max_versions[$tool]:-}"
			if [[ -z "$cur_max" ]]; then
				max_versions["$tool"]="$ver"
			else
				if [[ "$(printf '%s\n%s' "$cur_max" "$ver" | sort -V | tail -n 1)" == "$ver" ]]; then
					max_versions["$tool"]="$ver"
				fi
			fi
		fi
	done

	# Perform rewriting of files containing smaller versions
	if [[ -n "${max_versions[node]:-}" ]]; then
		local max_node="${max_versions[node]}"
		if [[ -f ".nvmrc" ]]; then
			local nvmrc_v
			nvmrc_v=$(grep -oE '[0-9.]+' .nvmrc | head -1 || echo "")
			if is_smaller_version "$nvmrc_v" "$max_node"; then
				if [[ "$DRY_RUN" != "1" ]]; then
					echo "$max_node" >".nvmrc"
				fi
				msg "$C_G" "📝 .nvmrc → $max_node (atualizado de $nvmrc_v)"
			fi
		fi
		if [[ -f ".node-version" ]]; then
			local nv_v
			nv_v=$(tr -d '[:space:]' <".node-version" 2>/dev/null || echo "")
			if is_smaller_version "$nv_v" "$max_node"; then
				if [[ "$DRY_RUN" != "1" ]]; then
					echo "$max_node" >".node-version"
				fi
				msg "$C_G" "📝 .node-version → $max_node (atualizado de $nv_v)"
			fi
		fi
		if [[ -f "package.json" ]]; then
			local pkg_node
			pkg_node=$(jq -r '.engines.node // empty' package.json 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "")
			if is_smaller_version "$pkg_node" "$max_node"; then
				local tmp
				tmp=$(mktemp)
				if jq --arg v "$max_node" '.engines.node = $v' package.json >"$tmp" 2>/dev/null; then
					if [[ "$DRY_RUN" != "1" ]]; then
						mv "$tmp" package.json
					else
						rm -f "$tmp"
					fi
					msg "$C_G" "📝 package.json (.engines.node) → $max_node (atualizado de $pkg_node)"
				else
					rm -f "$tmp"
				fi
			fi
		fi
	fi

	if [[ -n "${max_versions[ruby]:-}" ]]; then
		local max_ruby="${max_versions[ruby]}"
		if [[ -f ".ruby-version" ]]; then
			local rv_v
			rv_v=$(sed -E 's/^ruby-//;s/[[:space:]]//g' .ruby-version || echo "")
			if is_smaller_version "$rv_v" "$max_ruby"; then
				if [[ "$DRY_RUN" != "1" ]]; then
					echo "$max_ruby" >".ruby-version"
				fi
				msg "$C_G" "📝 .ruby-version → $max_ruby (atualizado de $rv_v)"
			fi
		fi
		if [[ -f "package.json" ]]; then
			local pkg_ruby
			pkg_ruby=$(jq -r '.rubyVersion // empty' package.json 2>/dev/null || echo "")
			if is_smaller_version "$pkg_ruby" "$max_ruby"; then
				local tmp
				tmp=$(mktemp)
				if jq --arg v "$max_ruby" '.rubyVersion = $v' package.json >"$tmp" 2>/dev/null; then
					if [[ "$DRY_RUN" != "1" ]]; then
						mv "$tmp" package.json
					else
						rm -f "$tmp"
					fi
					msg "$C_G" "📝 package.json (.rubyVersion) → $max_ruby (atualizado de $pkg_ruby)"
				else
					rm -f "$tmp"
				fi
			fi
		fi
	fi

	if [[ -n "${max_versions[java]:-}" ]]; then
		local max_java="${max_versions[java]}"
		if [[ -f ".sdkmanrc" ]]; then
			local sdk_v
			sdk_v=$(grep 'java=' .sdkmanrc 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || echo "")
			local sdk_major max_java_major
			sdk_major=$(echo "$sdk_v" | grep -oE '^[0-9]+' || echo "")
			max_java_major=$(echo "$max_java" | grep -oE '^[0-9]+' || echo "")
			if is_smaller_version "$sdk_major" "$max_java_major" || [[ ! "$sdk_v" == *-* ]]; then
				local resolved_java="$max_java"
				if [[ ! "$max_java" == *-* ]]; then
					local local_ex=""
					if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
						local_ex=$(ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null | grep -E "^${max_java}(\.|$)" | grep -v 'current' | sort -V | tail -1 || echo "")
					fi
					if [[ -n "$local_ex" ]]; then
						resolved_java="$local_ex"
					else
						local ex
						ex=$("$BREW_BASH" -c "set +u; [[ -f '$SDKMAN_DIR/bin/sdkman-init.sh' ]] && source '$SDKMAN_DIR/bin/sdkman-init.sh' >/dev/null; sdk list java 2>/dev/null | grep -i 'zulu' | grep -vE '(ea|fx)' | awk '{print \$NF}' | grep -E '^${max_java}(\.|$)' | sort -V | tail -1" || true)
						if [[ -n "$ex" ]]; then
							resolved_java="$ex"
						fi
					fi
				fi
				if [[ "$DRY_RUN" != "1" ]]; then
					sed -i '' "s/java=.*/java=$resolved_java/g" .sdkmanrc 2>/dev/null || true
				fi
				msg "$C_G" "📝 .sdkmanrc → java=$resolved_java (atualizado de $sdk_v)"
			fi
		fi
		if [[ -f "package.json" ]]; then
			local pkg_java
			pkg_java=$(jq -r '.javaVersion // empty' package.json 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "")
			if is_smaller_version "$pkg_java" "$max_java"; then
				local tmp
				tmp=$(mktemp)
				if jq --arg v "$max_java" '.javaVersion = $v' package.json >"$tmp" 2>/dev/null; then
					if [[ "$DRY_RUN" != "1" ]]; then
						mv "$tmp" package.json
					else
						rm -f "$tmp"
					fi
					msg "$C_G" "📝 package.json (.javaVersion) → $max_java (atualizado de $pkg_java)"
				else
					rm -f "$tmp"
				fi
			fi
		fi
	fi

	if [[ -n "${max_versions[yarn]:-}" ]]; then
		local max_yarn="${max_versions[yarn]}"
		if [[ -f "package.json" ]]; then
			local pkg_yarn
			pkg_yarn=$(jq -r '.packageManager // empty' package.json 2>/dev/null | grep -oE 'yarn@([0-9.]+)' | sed 's/yarn@//' || echo "")
			if is_smaller_version "$pkg_yarn" "$max_yarn"; then
				local tmp
				tmp=$(mktemp)
				if jq --arg v "yarn@$max_yarn" '.packageManager = $v' package.json >"$tmp" 2>/dev/null; then
					if [[ "$DRY_RUN" != "1" ]]; then
						mv "$tmp" package.json
					else
						rm -f "$tmp"
					fi
					msg "$C_G" "📝 package.json (.packageManager) → yarn@$max_yarn (atualizado de yarn@$pkg_yarn)"
				else
					rm -f "$tmp"
				fi
			fi
		fi
	fi

	# Rebuild the detected array with only the highest versions preserving detection order
	local -a filtered_detected=()
	local -a detected_tools_ordered=()
	for item in "${detected[@]}"; do
		local tool="${item%%:*}"
		if [[ -z "${seen_tools[$tool]:-}" ]]; then
			seen_tools["$tool"]=1
			detected_tools_ordered+=("$tool")
		fi
	done
	for tool in "${detected_tools_ordered[@]}"; do
		local ver="${max_versions[$tool]:-}"
		if [[ -n "$ver" ]]; then
			filtered_detected+=("$tool:$ver")
		else
			filtered_detected+=("$tool")
		fi
	done
	detected=("${filtered_detected[@]}")

	# Update the req variables to the maximum values
	node_req="${max_versions[node]:-$node_req}"
	yarn_req="${max_versions[yarn]:-$yarn_req}"
	java_req="${max_versions[java]:-$java_req}"
	ruby_req="${max_versions[ruby]:-$ruby_req}"

	for item in "${detected[@]}"; do
		local tool="${item%%:*}"
		local ver="${item##*:}"
		[[ "$tool" == "$ver" ]] && ver=""

		local exists
		exists=$(c_get "$tool" "type")

		if [[ -z "$exists" ]]; then
			to_merge+=("$item")
		elif [[ -n "$ver" ]]; then
			local has_ver
			has_ver=$(jq -r --arg t "$tool" --arg v "$ver" 'if .tools[$t].versions then .tools[$t].versions[] | select(. == $v) else empty end' "$CATALOG_FILE" 2>/dev/null)
			[[ -z "$has_ver" ]] && to_merge+=("$item")
		fi

		if ! is_tool_version_installed "$tool" "$ver"; then
			to_install+=("$item")
		fi
	done

	local needs_bundle=false
	if [[ -f "Gemfile" ]]; then
		local has_ruby=false
		if [[ -d "$HOME/.rubies" ]] && [[ $(ls -1 "$HOME/.rubies" 2>/dev/null | wc -l) -gt 0 ]]; then
			has_ruby=true
		fi
		if [[ "$has_ruby" == "true" ]]; then
			if ! run_in_ruby_env "bundle check" &>/dev/null; then
				needs_bundle=true
			fi
		else
			needs_bundle=true
		fi
	fi

	ensure_project_version_files "$node_req" "$ruby_req" "$java_req"
	ensure_corepack_project_yarn "$yarn_req"
	if [[ ${#to_install[@]} -eq 0 && "$needs_bundle" == "false" ]]; then
		print_version_activation_hint
		return 0
	fi

	local should_install=false

	# Helper: prints a tool:version item as a formatted line
	_print_req_item() {
		local item="$1"
		local tool="${item%%:*}"
		local ver="${item##*:}"
		if [[ "$tool" == "$ver" ]]; then
			printf '     %b▸%b  %b%-18s%b\n' "$C_C" "$C_RESET" "$C_W" "$tool" "$C_RESET"
		else
			printf '     %b▸%b  %b%-18s%b %b→  %s%b\n' "$C_C" "$C_RESET" "$C_W" "$tool" "$C_RESET" "$C_Y" "$ver" "$C_RESET"
		fi
	}

	if [[ ${#to_merge[@]} -gt 0 ]]; then
		printf '\n  %b╭─ 🔍 Novos requisitos em %b%s%b ─╮%b\n' "$C_C" "$C_BOLD$C_W" "$(basename "$PWD")" "$C_RESET$C_C" "$C_RESET"
		printf '\n'
		for item in "${to_merge[@]}"; do
			_print_req_item "$item"
		done
		[[ "$needs_bundle" == "true" ]] && printf '     %b▸%b  %b%-18s%b %b→  Gemfile%b\n' "$C_C" "$C_RESET" "$C_W" "bundler" "$C_RESET" "$C_Y" "$C_RESET"
		printf '\n'
		if tui_confirm "Mesclar ao catálogo global e instalar?"; then
			merge_stack_into_catalog "${to_merge[@]}"
			should_install=true
		fi
	else
		printf '\n  %b╭─ 🔍 Requisitos do projeto não instalados ─╮%b\n' "$C_C" "$C_RESET"
		printf '\n'
		for item in "${to_install[@]}"; do
			_print_req_item "$item"
		done
		[[ "$needs_bundle" == "true" ]] && printf '     %b▸%b  %b%-18s%b %b→  Gemfile%b\n' "$C_C" "$C_RESET" "$C_W" "bundler" "$C_RESET" "$C_Y" "$C_RESET"
		printf '\n'
		if tui_confirm "Instalar agora?"; then
			should_install=true
		fi
	fi

	if [[ "$should_install" == "true" ]]; then
		msg "$C_C" "🚀 Instalando ferramentas do projeto..."
		ask_sudo
		ensure_project_version_files "$node_req" "$ruby_req" "$java_req"

		local -a install_tools=()
		for item in "${to_install[@]}"; do
			local tool="${item%%:*}"
			install_tools+=("$tool")
		done
		local -a unique_install_tools=()
		readarray -t unique_install_tools < <(printf '%s\n' "${install_tools[@]}" | sort -u)

		declare -g -A ALREADY_INSTALLED
		local -a all_tools
		readarray -t all_tools < <(get_ordered_tools)
		for t in "${all_tools[@]}"; do
			if health_check "$t" "$(c_get "$t" "type")" &>/dev/null; then
				ALREADY_INSTALLED["$t"]=true
			fi
		done

		local -a ordered_install_tools=()
		for t in "${all_tools[@]}"; do
			for it in "${unique_install_tools[@]}"; do
				if [[ "$t" == "$it" ]]; then
					ordered_install_tools+=("$t")
					break
				fi
			done
		done

		TOTAL_TOOLS=${#ordered_install_tools[@]}
		CURRENT_TOOL_INDEX=0
		local -a m_tools=()
		local -a b_tools=()
		for t in "${ordered_install_tools[@]}"; do
			local type
			type=$(c_get "$t" "type")
			if [[ "$type" == "managed" || "$type" == "gem" ]]; then
				m_tools+=("$t")
			else
				b_tools+=("$t")
			fi
		done
		for t in "${m_tools[@]}"; do
			process_tool "$t" "install"
		done
		for t in "${b_tools[@]}"; do
			process_tool "$t" "install"
		done
		if [[ ${#b_tools[@]} -gt 0 ]]; then
			run_brew_bundle "install" || true
		fi

		# Ensure corepack controls yarn for the project
		ensure_corepack_project_yarn "$yarn_req"

		# Install Gemfile dependencies via Bundler if present
		if [[ -f "Gemfile" ]]; then
			msg "$C_C" "💎 Instalando dependências Ruby via Bundler..."
			run_step "Instalando" "Gems do Gemfile" "Gems do Gemfile" "Gems do Gemfile" "installed" run_in_ruby_env "gem install bundler --no-document && bundle install" || true
		fi

		rm -f "$LOCK_FILE"
		ensure_lockfile
		msg "$C_G" "✅ Instalação concluída com sucesso!"
		print_version_activation_hint
		exit 0
	fi
}

merge_stack_into_catalog() {
	local item tool ver mgr exists
	for item in "$@"; do
		tool="${item%%:*}"
		ver="${item##*:}"
		[[ "$tool" == "$ver" ]] && ver=""

		mgr=$(get_known_managed "$tool" 2>/dev/null || true)
		exists=$(c_get "$tool" "type")

		if [[ -n "$mgr" ]]; then
			[[ -z "$exists" ]] && _jq_update ".tools[\"$tool\"] = {\"type\":\"managed\",\"manager\":\"$mgr\",\"versions\":[]}"
			if [[ -n "$ver" ]]; then
				_jq_update ".tools[\"$tool\"].versions = ((.tools[\"$tool\"].versions // []) + [\"$ver\"] | unique)"
			fi
		else
			if [[ -z "$exists" ]]; then
				local tp="formula"
				brew info --cask "$tool" &>/dev/null && tp="cask"
				_jq_update ".tools[\"$tool\"] = {\"type\":\"$tp\",\"version\":\"\"}"
			fi
			[[ -n "$ver" ]] && _jq_update ".tools[\"$tool\"].version = \"$ver\""
		fi
	done
	msg "$C_G" "✅ Catálogo global atualizado (Merge)."
}

first_run_auto_setup() {
	[[ -f "$CATALOG_FILE" && $(jq '.tools | length' "$CATALOG_FILE" 2>/dev/null) -gt 0 ]] && return 0

	local -a candidates=(
		"$HOME/mac-dev-snapshot.json"
		"$HOME/.mac-dev-snapshots/latest.json"
		"$HOME/Dropbox/mac-dev-snapshot.json"
	)

	for snap in "${candidates[@]}"; do
		if [[ -f "$snap" ]]; then
			msg "$C_C" "📥 Snapshot detectado: $snap"
			tui_confirm "Importar automaticamente?" && {
				snapshot_import "$snap"
				return 0
			}
		fi
	done

	if tui_confirm "Catálogo vazio. Carregar um preset base?"; then
		load_preset
	fi
}

# ==============================================================================
# 15. CLI FLOW CONTROLLER & ENTRYPOINT
# ==============================================================================

pre_flight_checks() {
	safe_curl -s --head --request GET https://www.apple.com/library/test/success.html >/dev/null 2>&1 || err "Sem conexão com a internet."
	for d in git curl awk grep sed find xargs; do command -v "$d" >/dev/null 2>&1 || err "Dependência nativa ausente: $d"; done
	[[ -w "$HOME" ]] || err "Sem permissão de escrita em \$HOME"
}

full_uninstall() {
	confirm_destructive "APAGAR TUDO (SDKs, Rubies, Xcodes, Configs)?" || return 0
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	TOTAL_TOOLS=${#tools[@]}
	CURRENT_TOOL_INDEX=0
	for t in "${tools[@]}"; do process_tool "$t" "uninstall" || true; done
	run_bg "Expurgo" "pastas" clean_folders_job || true
	run_bg "Perfis" "shell rc" clean_profiles_job || true
	rm -f "$ENV_FILE"
	local tr
	tr=$(get_target_rc)
	[[ -f "$tr" ]] && sed -i '' "/\.config\/mac-dev\/env\.sh/d" "$tr" 2>/dev/null || true
	rn_cleanup
	audit_report
	notify "mac-dev-setup" "Desinstalação completa"
}

do_all() {
	local mode="$1"
	[[ "$mode" == "uninstall" ]] && {
		full_uninstall
		return 0
	}
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	declare -g -A ALREADY_INSTALLED
	for t in "${tools[@]}"; do
		if health_check "$t" "$(c_get "$t" "type")" &>/dev/null; then
			ALREADY_INSTALLED["$t"]=true
		fi
	done
	local -a tools_to_process=()
	for t in "${tools[@]}"; do
		local lock_status
		lock_status=$(jq -r ".tools[\"$t\"].status // empty" "$LOCK_FILE" 2>/dev/null || true)
		if [[ "$mode" == "install" || "$lock_status" != "removed" ]]; then
			tools_to_process+=("$t")
		fi
	done

	if [[ ${#tools_to_process[@]} -eq 0 ]]; then
		msg "$C_G" "✅ Nenhuma ferramenta ativa para instalar ou atualizar."
		return 0
	fi

	local -a managed_tools=()
	local -a homebrew_tools=()
	for t in "${tools_to_process[@]}"; do
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" || "$type" == "gem" ]]; then
			managed_tools+=("$t")
		else
			homebrew_tools+=("$t")
		fi
	done

	TOTAL_TOOLS=${#tools_to_process[@]}
	CURRENT_TOOL_INDEX=0
	for t in "${managed_tools[@]}"; do process_tool "$t" "$mode"; done
	for t in "${homebrew_tools[@]}"; do process_tool "$t" "$mode"; done
	[[ "$mode" == "install" || "$mode" == "update" ]] && run_brew_bundle "$mode" || true
	for t in "${tools_to_process[@]}"; do remove_untracked_versions "$t"; done
	rn_cleanup
	msg "$C_G" "✅ Concluído. Reinicie o terminal."
	notify "mac-dev-setup" "Setup concluído com sucesso"
	[[ "$mode" == "install" || "$mode" == "update" ]] && audit_report
}

do_selective() {
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	declare -g -A ALREADY_INSTALLED
	for t in "${tools[@]}"; do
		if health_check "$t" "$(c_get "$t" "type")" &>/dev/null; then
			ALREADY_INSTALLED["$t"]=true
		fi
	done
	local -i installed_count
	installed_count=$(count_installed_tools)

	local action
	if [[ "$HAS_GUM" == "true" ]]; then
		local -a actions=()
		actions+=("install")
		if [[ $installed_count -ge 1 ]]; then
			actions+=("update" "uninstall")
		fi
		action=$(tui_choose "⚙️ Ação:" "${actions[@]}") || return 0
		printf "⚙️ Ação: %b%s%b\n" "$C_C" "$action" "$C_RESET"
	else
		if [[ $installed_count -ge 1 ]]; then
			action=$(tui_input "Ação (install/update/uninstall): " "install")
		else
			action="install"
			printf "⚙️ Ação: %b%s%b\n" "$C_C" "install" "$C_RESET"
		fi
	fi
	[[ -z "${action:-}" ]] && return 0

	local -a display_tools=()
	for t in "${tools[@]}"; do
		if [[ "$action" == "uninstall" || "$action" == "update" ]]; then
			if [[ "${ALREADY_INSTALLED[$t]:-}" == "true" ]]; then
				display_tools+=("$t")
			fi
		else
			display_tools+=("$t")
		fi
	done

	if [[ ${#display_tools[@]} -eq 0 ]]; then
		if [[ "$action" == "uninstall" ]]; then
			warn "Nenhuma ferramenta instalada para desinstalar."
		elif [[ "$action" == "update" ]]; then
			warn "Nenhuma ferramenta instalada para atualizar."
		else
			warn "Nenhuma ferramenta disponível."
		fi
		return 0
	fi

	local -a selected=()
	if [[ "$HAS_GUM" == "true" ]]; then
		local choice_output
		choice_output=$(tui_multi_choose "🔧 Selecione com [Espaço] e confirme com [Enter]:" "${display_tools[@]}") || return 0
		while IFS= read -r line; do
			if [[ -n "${line:-}" ]]; then
				selected+=("$line")
			fi
		done <<<"$choice_output"
	fi

	if [[ ${#selected[@]} -eq 0 ]]; then
		if [[ "$HAS_GUM" == "true" ]]; then
			warn "Nenhuma ferramenta selecionada via interface gráfica."
			printf "%bAlternando para seleção manual por números:%b\n" "$C_Y" "$C_RESET"
		fi
		for i in "${!display_tools[@]}"; do
			printf '  %d) %s\n' "$((i + 1))" "${display_tools[$i]}"
		done
		printf '%s' "${C_DIM}Digite os números das ferramentas (separados por espaço): ${C_RESET}"
		local -a sn
		read -r -a sn </dev/tty
		for s in "${sn[@]}"; do
			local idx=$((s - 1))
			if [[ $idx -ge 0 && $idx -lt ${#display_tools[@]} ]]; then
				local val="${display_tools[$idx]}"
				if [[ -n "${val:-}" ]]; then
					selected+=("$val")
				fi
			fi
		done
	fi

	[[ ${#selected[@]} -eq 0 ]] && {
		warn "Nada selecionado."
		return 0
	}
	printf "🔧 Ferramentas selecionadas: %b%s%b\n" "$C_C" "${selected[*]}" "$C_RESET"
	local SELECTIVE_MODE=true
	TOTAL_TOOLS=${#selected[@]}
	CURRENT_TOOL_INDEX=0
	for t in "${selected[@]}"; do process_tool "$t" "$action"; done
	for t in "${selected[@]}"; do remove_untracked_versions "$t"; done
	rn_cleanup
	audit_report
}

post_operation_hook() {
	local op="$1" ts
	mkdir -p "$HOME/.mac-dev-snapshots"
	ts=$(date +%Y%m%d-%H%M%S)
	snapshot_export "$HOME/.mac-dev-snapshots/$ts.json" 2>/dev/null || true
	ln -sf "$ts.json" "$HOME/.mac-dev-snapshots/latest.json"
	log_event "info" "auto_snapshot" "$op" "$ts.json"
}

do_search() {
	local query
	if [[ "$HAS_GUM" == "true" ]]; then
		query=$(tui_input "🔍 Buscar:" "node")
	else
		query=$(tui_input "Ferramenta: " "node")
	fi

	if [[ -z "${query:-}" ]]; then
		return 0
	fi

	local -a raw=() res=()
	while IFS= read -r line; do
		if [[ -n "${line:-}" ]]; then
			raw+=("$line")
		fi
	done < <(brew search "$query" | awk '{print $1}' | grep -vE '(==>|^$)' || true)

	for r in "${raw[@]}"; do
		if [[ "$r" == "$query" ]]; then
			res+=("$r")
		fi
	done

	for r in "${raw[@]}"; do
		if [[ "$r" != "$query" && ${#res[@]} -lt 10 ]]; then
			res+=("$r")
		fi
	done

	if [[ ${#res[@]} -eq 0 ]]; then
		err "Nada encontrado."
	fi

	local target
	if [[ "$HAS_GUM" == "true" ]]; then
		target=$(tui_filter "Selecione:" "${res[@]}") || return 0
		printf "📦 Selecionado: %b%s%b\n" "$C_C" "$target" "$C_RESET"
	else
		for i in "${!res[@]}"; do
			printf '  %d) %s\n' "$((i + 1))" "${res[$i]}"
		done
		printf '%s' "${C_DIM}Escolha: ${C_RESET}"
		read -r sel
		if [[ -z "${sel:-}" || "$sel" -le 0 || "$sel" -gt ${#res[@]} ]]; then
			return 0
		fi
		target="${res[$((sel - 1))]}"
	fi
	local et mgr
	et=$(c_get "$target" "type")
	mgr=$(get_known_managed "$target" 2>/dev/null || true)
	if [[ -n "${et:-}" && -n "${mgr:-}" ]]; then
		confirm_destructive "Sobrescrever $target ($et)?" || return 0
	fi
	if [[ -n "${mgr:-}" ]]; then
		_jq_update ".tools[\"$target\"] = {\"type\":\"managed\",\"manager\":\"$mgr\",\"versions\":[]}"
	else
		local tp="formula"
		brew info --cask "$target" &>/dev/null && tp="cask"
		_jq_update ".tools[\"$target\"] = {\"type\":\"$tp\",\"version\":\"\"}"
	fi
	TOTAL_TOOLS=1
	CURRENT_TOOL_INDEX=0
	process_tool "$target" "install"
}

dry_run() {
	local mode="$1"
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	TOTAL_TOOLS=${#tools[@]}
	CURRENT_TOOL_INDEX=0
	printf '
%s
' "${C_Y}🧪 Dry-run '$mode':${C_RESET}"
	local bf
	bf=$(generate_brewfile)
	if [[ -s "$bf" ]]; then
		local -a dr_formulas=() dr_casks=()
		while IFS= read -r line; do
			[[ -z "${line:-}" ]] && continue
			if [[ "$line" =~ ^brew\ \"(.+)\"$ ]]; then
				dr_formulas+=("${BASH_REMATCH[1]}")
			elif [[ "$line" =~ ^cask\ \"(.+)\"$ ]]; then
				dr_casks+=("${BASH_REMATCH[1]}")
			fi
		done <"$bf"
		local dr_total=$((${#dr_formulas[@]} + ${#dr_casks[@]}))
		if [[ $dr_total -gt 0 ]]; then
			printf '\n'
			printf '  %b┌──────────────────────────────────────────────┐%b\n' "$C_C" "$C_RESET"
			printf '  %b│  📦  Brew Bundle — Instalação em lote        │%b\n' "$C_C" "$C_RESET"
			printf '  %b│  %b%d ferramenta(s)%b serão instaladas via Brew  %b│%b\n' \
				"$C_C" "$C_W" "$dr_total" "$C_RESET" "$C_C" "$C_RESET"
			printf '  %b└──────────────────────────────────────────────┘%b\n' "$C_C" "$C_RESET"
			if [[ ${#dr_formulas[@]} -gt 0 ]]; then
				printf '\n  %b🍺 Fórmulas:%b\n' "$C_Y" "$C_RESET"
				for f in "${dr_formulas[@]}"; do
					printf '     %b▸%b %s\n' "$C_C" "$C_RESET" "$f"
				done
			fi
			if [[ ${#dr_casks[@]} -gt 0 ]]; then
				printf '\n  %b🖥  Casks (apps):%b\n' "$C_B" "$C_RESET"
				for c in "${dr_casks[@]}"; do
					printf '     %b▸%b %s\n' "$C_C" "$C_RESET" "$c"
				done
			fi
			printf '\n'
		fi
	fi
	rm -f "$bf"
	for t in "${tools[@]}"; do
		((++CURRENT_TOOL_INDEX))
		print_progress_bar "$CURRENT_TOOL_INDEX" "$TOTAL_TOOLS" "$t"
		local tp
		tp=$(c_get "$t" "type")
		printf '  %s→ %s (%s)%s
' \
			"${C_W}" \
			"$t" \
			"$tp" \
			"${C_RESET}"
		if [[ "$tp" == "managed" ]]; then
			local mgr
			mgr=$(c_get "$t" "manager")
			printf '    ├─ Manager: %s
' "$mgr"
			local -a v
			readarray -t v < <(c_get_versions "$t")
			if [[ ${#v[@]} -gt 0 ]]; then
				printf '    └─ Versões: %s
' "$(printf '%s ' "${v[@]}")"
			fi
		fi
	done
	printf '
%s
' "${C_G}✅ Simulação OK.${C_RESET}"
}

main() {
	ensure_modern_bash_and_deps "$@"
	local dry_run_mode=false relock=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run_mode=true
			;;
		--relock)
			relock=true
			;;
		--verbose)
			export VERBOSE=1
			;;
		--yes)
			AUTO_YES=true
			;;
		*)
			break
			;;
		esac
		shift
	done

	LOCK_DIR="/tmp/mac-dev-setup.lock.d"
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		local lock_pid=""
		[[ -f "$LOCK_DIR/pid" ]] && lock_pid="$(cat "$LOCK_DIR/pid")"
		if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null && ps -p "$lock_pid" -o comm= | grep -q "bash"; then
			err "Script já em execução (PID $lock_pid)."
		else
			rm -rf "$LOCK_DIR"
			mkdir "$LOCK_DIR" 2>/dev/null || err "Não foi possível adquirir lock."
		fi
	fi
	HAS_LOCK=true
	echo $$ >"$LOCK_DIR/pid"
	mkdir -p "$(dirname "$LOG_FILE")" "$LOG_DIR"
	exec 4>&2
	exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&4)
	draw_box "macOS Dev Setup"

	msg "$C_C" "🔍 Verificando conectividade e dependências nativas..."
	pre_flight_checks

	msg "$C_C" "📦 Inicializando catálogo de ferramentas..."
	catalog_init
	migrate_catalog
	validate_catalog_schema
	[[ "$relock" == true ]] && rm -f "$LOCK_FILE"
	ensure_lockfile
	catalog_reconcile

	[[ "$relock" == true ]] && {
		msg "$C_G" "✅ Lockfile ok."
		exit 0
	}
	validate_lock_consistency || true
	[[ "$dry_run_mode" == true ]] && {
		dry_run "${1:-install}"
		exit 0
	}

	msg "$C_C" "⚙️  Carregando contexto e sincronizando projeto..."

	# Migrate: suppress fnm output during shell init (Powerlevel10k compat)
	if [[ -f "$ENV_FILE" ]] && grep -q 'fnm env --use-on-cd)' "$ENV_FILE" 2>/dev/null && ! grep -q 'log-level' "$ENV_FILE" 2>/dev/null; then
		sed -i '' 's/fnm env --use-on-cd)/fnm env --use-on-cd --log-level=quiet)/g' "$ENV_FILE" 2>/dev/null || true
	fi

	# Migrate: ensure env.sh has the custom sudo wrapper
	if [[ -f "$ENV_FILE" ]]; then
		ensure_env_sudo_wrapper
	fi

	first_run_auto_setup
	sync_project_context

	msg "$C_C" "🔄 Verificando integridade e desvios..."
	startup_drift_check

	msg "$C_G" "✨ Inicialização concluída!"

	local -i installed_count=0
	local -i uninstalled_count=0
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	for t in "${tools[@]}"; do
		local type
		type=$(c_get "$t" "type")
		if [[ -n "${type:-}" ]]; then
			if health_check "$t" "$type" &>/dev/null; then
				installed_count=$((installed_count + 1))
			else
				uninstalled_count=$((uninstalled_count + 1))
			fi
		fi
	done

	local -a menu_opts=()
	if [[ $uninstalled_count -gt 0 ]]; then
		menu_opts+=("Instalar Tudo 📥")
	fi
	if [[ $installed_count -gt 1 ]]; then
		menu_opts+=("Atualizar Tudo 🔄")
	fi
	menu_opts+=("Ação Seletiva ⚙️" "Adicionar Ferramenta 🔍")
	if [[ $installed_count -gt 1 ]]; then
		menu_opts+=("Desinstalar Tudo 🗑️")
	fi
	menu_opts+=("Sair ❌")

	local opt
	opt=$(tui_choose "🚀 macOS Dev Setup" "${menu_opts[@]}") || exit 0
	printf "🚀 macOS Dev Setup: %b%s%b\n" "$C_C" "$opt" "$C_RESET"

	case "$opt" in
	*"Instalar Tudo"*)
		ask_sudo
		do_all "install"
		post_operation_hook "$opt"
		;;
	*"Atualizar Tudo"*)
		ask_sudo
		do_all "update"
		post_operation_hook "$opt"
		;;
	*"Seletiva"*)
		ask_sudo
		do_selective
		post_operation_hook "$opt"
		;;
	*"Adicionar"*)
		ask_sudo
		do_search
		post_operation_hook "$opt"
		;;
	*"Desinstalar"*)
		ask_sudo
		full_uninstall
		post_operation_hook "$opt"
		;;
	*) exit 0 ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
