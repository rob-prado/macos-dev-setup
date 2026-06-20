#!/usr/bin/env bash

# Utility functions extracted from setup.sh

cleanup() {
	[[ "$HAS_LOCK" == "true" ]] && rm -rf "${LOCK_DIR:-/tmp/mac-dev-setup.lock.d}"
	rm -rf "${CATALOG_FILE}.lock.d" \
		"${LOCK_FILE}.lock.d" \
		"${TMP_FILES[@]:-}" 2>/dev/null || true
}

apply_macos_compat() {
	if [[ $(sw_vers -productVersion 2>/dev/null | awk -F. '{print $1}') -ge 15 ]]; then
		local brew_err
		brew_err=$(brew info git 2>&1 || true)
		if echo "$brew_err" | grep -qE '(unknown or unsupported macOS version|_dunno\.jws\.json)'; then
			local LATEST_MAC_VER
			LATEST_MAC_VER=$(grep -E '^[[:space:]]*[a-z_]+:[[:space:]]+"[0-9]+(\.[0-9]+)*",' "$(brew --repository)/Library/Homebrew/macos_version.rb" 2>/dev/null | grep -Eo '"[0-9]+(\.[0-9]+)*"' | tr -d '"' | sort -V | tail -1)
			export HOMEBREW_FAKE_MACOS="${LATEST_MAC_VER:-14.0}"
		fi
	fi
}

ensure_modern_bash_and_deps() {
	if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
		if [[ ! -x "$BREW_BASH" ]]; then
			apply_macos_compat
			command -v brew >/dev/null 2>&1 || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >/dev/null
			eval "$("$BREW_PREFIX/bin/brew" shellenv)"
			brew install bash jq zip unzip >/dev/null 2>&1 || true
		fi
		exec "$BREW_BASH" "$0" "$@"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		apply_macos_compat
		brew install jq zip unzip >/dev/null 2>&1 || {
			printf '\n%s\n' "${C_R}❌ jq missing${C_RESET}" >/dev/2
			exit 1
		}
	fi
}

safe_curl() {
	curl --connect-timeout 10 --max-time 30 "$@"
}

run_in_ruby_env() {
	local cmd="$1"
	if command -v mise &>/dev/null; then
		env MISE_AUTO_INSTALL=0 mise exec ruby -- bash -c "$cmd"
	else
		bash -c "$cmd"
	fi
}

retry() {
	local attempts="$1"
	shift
	local n=1 delay=2
	until "$@"; do
		((n >= attempts)) && return 1
		sleep $((delay ** n))
		((n++))
	done
}

is_smaller_version() {
	local v1="$1" v2="$2"
	[[ -z "$v1" || -z "$v2" || "$v1" == "$v2" ]] && return 1
	[[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n 1)" == "$v1" ]]
}

notify() {
	local title="$1" message="$2"
	osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}
