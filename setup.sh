#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
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
readonly CATALOG_SCHEMA_VERSION=3

HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true
HAS_GLOW=false
command -v glow >/dev/null 2>&1 && HAS_GLOW=true

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

source "$SCRIPT_DIR/modules/utils.sh"

# ==============================================================================
# 02. PRINTING & UI STYLING
# ==============================================================================

source "$SCRIPT_DIR/modules/ui.sh"

# ==============================================================================
# 03. LOGGING, AUDITING & METRICS
# ==============================================================================

source "$SCRIPT_DIR/modules/logging.sh"

# ==============================================================================
# 04. INTERACTIVE TERMINAL UI (TUI)
# ==============================================================================

source "$SCRIPT_DIR/modules/tui.sh"

# ==============================================================================
# 05. SHELL ENVIRONMENT CONFIGURATION (RC PROFILES)
# ==============================================================================

source "$SCRIPT_DIR/modules/env.sh"

# ==============================================================================
# 06. STATE DATABASE (JSON CATALOG & LOCKFILE)
# ==============================================================================

source "$SCRIPT_DIR/modules/catalog.sh"
source "$SCRIPT_DIR/modules/lock.sh"

# ==============================================================================
# 07. RESOLUTION & METADATA (DEPENDENCY ENGINE)
# ==============================================================================

source "$SCRIPT_DIR/modules/metadata.sh"

# ==============================================================================
# 08. CONFLICTS, DRIFT & HEALTH CHECKS
# ==============================================================================

source "$SCRIPT_DIR/modules/health.sh"

# ==============================================================================
# 09. SNAPSHOT MANAGEMENT
# ==============================================================================

source "$SCRIPT_DIR/modules/snapshot.sh"

# ==============================================================================
# 10. PROCESS RUNNERS & JOB CONTROLLERS
# ==============================================================================

source "$SCRIPT_DIR/modules/core.sh"

# ==============================================================================
# 11. PACKAGING SYSTEMS (BREW ENGINE)
# ==============================================================================

source "$SCRIPT_DIR/modules/brew.sh"

# ==============================================================================
# 12. FEATURE OPERATIONS (INSTALL, UPDATE, UNINSTALL)
# ==============================================================================

source "$SCRIPT_DIR/modules/features.sh"

# ==============================================================================
# 13. CACHE PURGING & SYSTEM CLEANUP
# ==============================================================================

source "$SCRIPT_DIR/modules/cleanup.sh"

# ==============================================================================
# 14. LOCAL PROJECT CONTEXT & SYNC
# ==============================================================================

source "$SCRIPT_DIR/modules/project.sh"

# ==============================================================================
# 15. CLI FLOW CONTROLLER & ENTRYPOINT
# ==============================================================================

pre_flight_checks() {
	safe_curl -s --head --request GET https://www.apple.com/library/test/success.html >/dev/null 2>&1 || err "No internet connection."
	for d in git curl awk grep sed find xargs; do command -v "$d" >/dev/null 2>&1 || err "Missing native dependency: $d"; done
	[[ -w "$HOME" ]] || err "No write permission to \$HOME"
}

full_uninstall() {
	confirm_destructive "DELETE EVERYTHING (SDKs, Rubies, Xcodes, Configs)?" || return 0
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	TOTAL_TOOLS=${#tools[@]}
	CURRENT_TOOL_INDEX=0
	for t in "${tools[@]}"; do process_tool "$t" "uninstall" || true; done
	run_bg "Purge" "folders" clean_folders_job || true
	run_bg "Profiles" "shell rc" clean_profiles_job || true
	rm -f "$ENV_FILE"
	local tr
	tr=$(get_target_rc)
	[[ -f "$tr" ]] && sed -i '' "/\.config\/mac-dev\/env\.sh/d" "$tr" 2>/dev/null || true
	rn_cleanup
	audit_report
	notify "mac-dev-setup" "Full uninstall complete"
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
		lock_status=$(jq -r ".tools["$t"].status // empty" "$LOCK_FILE" 2>/dev/null || true)
		if [[ "$mode" == "install" || "$lock_status" != "removed" ]]; then
			tools_to_process+=("$t")
		fi
	done

	if [[ ${#tools_to_process[@]} -eq 0 ]]; then
		msg "$C_G" "✅ No active tools to install or update."
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
	msg "$C_G" "✅ Done. Restart your terminal."
	notify "mac-dev-setup" "Setup completed successfully"
	[[ "$mode" == "install" || "$mode" == "update" ]] && audit_report
}

do_selective() {
	local action="$1"
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

	if [[ -z "${action:-}" ]]; then
		if [[ "$HAS_GUM" == "true" ]]; then
			local -a actions=()
			actions+=("install")
			if [[ $installed_count -ge 1 ]]; then
				actions+=("update" "uninstall")
			fi
			action=$(tui_choose "⚙️ Action:" "${actions[@]}") || return 0
			printf "⚙️ Action: %b%s%b\n" "$C_C" "$action" "$C_RESET"
		else
			if [[ $installed_count -ge 1 ]]; then
				action=$(tui_input "Action (install/update/uninstall): " "install")
			else
				action="install"
				printf "⚙️ Action: %b%s%b\n" "$C_C" "install" "$C_RESET"
			fi
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
			warn "No installed tools to uninstall."
		elif [[ "$action" == "update" ]]; then
			warn "No installed tools to update."
		else
			warn "No tools available."
		fi
		return 0
	fi

	local -a selected=()
	if [[ "$HAS_GUM" == "true" ]]; then
		local choice_output
		choice_output=$(tui_multi_choose "🔧 Select with [Space] and confirm with [Enter]:" "${display_tools[@]}") || return 0
		while IFS= read -r line; do
			if [[ -n "${line:-}" ]]; then
				selected+=("$line")
			fi
		done <<<"$choice_output"
	fi

	if [[ ${#selected[@]} -eq 0 ]]; then
		if [[ "$HAS_GUM" == "true" ]]; then
			warn "No tools selected via graphical interface."
			printf "%bSwitching to manual number selection:%b\n" "$C_Y" "$C_RESET"
		fi
		for i in "${!display_tools[@]}"; do
			printf '  %d) %s\n' "$((i + 1))" "${display_tools[$i]}"
		done
		printf '%s' "${C_DIM}Enter tool numbers (separated by spaces): ${C_RESET}"
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
		warn "Nothing selected."
		return 0
	}
	printf "🔧 Selected tools: %b%s%b\n" "$C_C" "${selected[*]}" "$C_RESET"
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
		query=$(tui_input "🔍 Search:" "node")
	else
		query=$(tui_input "Tool: " "node")
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
		err "Nothing found."
	fi

	local target
	if [[ "$HAS_GUM" == "true" ]]; then
		target=$(tui_filter "Select:" "${res[@]}") || return 0
		printf "📦 Selected: %b%s%b\n" "$C_C" "$target" "$C_RESET"
	else
		for i in "${!res[@]}"; do
			printf '  %d) %s\n' "$((i + 1))" "${res[$i]}"
		done
		printf '%s' "${C_DIM}Choose: ${C_RESET}"
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
		confirm_destructive "Overwrite $target ($et)?" || return 0
	fi
	if [[ -n "${mgr:-}" ]]; then
		_jq_update ".tools["$target"] = {"type":"managed","manager":"$mgr","versions":[]}"
	else
		local tp="formula"
		brew info --cask "$target" &>/dev/null && tp="cask"
		_jq_update ".tools["$target"] = {"type":"$tp","version":""}"
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
			if [[ "$line" =~ ^brew\ "(.+)"$ ]]; then
				dr_formulas+=("${BASH_REMATCH[1]}")
			elif [[ "$line" =~ ^cask\ "(.+)"$ ]]; then
				dr_casks+=("${BASH_REMATCH[1]}")
			fi
		done <"$bf"
		local dr_total=$((${#dr_formulas[@]} + ${#dr_casks[@]}))
		if [[ $dr_total -gt 0 ]]; then
			printf '\n'
			printf '  %b┌──────────────────────────────────────────────┐%b\n' "$C_C" "$C_RESET"
			printf '  %b│  📦  Brew Bundle — Batch Install               │%b\n' "$C_C" "$C_RESET"
			printf '  %b│  %b%d tool(s)%b will be installed via Brew       %b│%b\n' \
				"$C_C" "$C_W" "$dr_total" "$C_RESET" "$C_C" "$C_RESET"
			printf '  %b└──────────────────────────────────────────────┘%b\n' "$C_C" "$C_RESET"
			if [[ ${#dr_formulas[@]} -gt 0 ]]; then
				printf '\n  %b🍺 Formulas:%b\n' "$C_Y" "$C_RESET"
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
				printf '    └─ Versions: %s
' "$(printf '%s ' "${v[@]}")"
			fi
		fi
	done
	printf '
%s
' "${C_G}✅ Simulation OK.${C_RESET}"
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
			err "Script already running (PID $lock_pid)."
		else
			rm -rf "$LOCK_DIR"
			mkdir "$LOCK_DIR" 2>/dev/null || err "Could not acquire lock."
		fi
	fi
	HAS_LOCK=true
	echo $$ >"$LOCK_DIR/pid"
	mkdir -p "$(dirname "$LOG_FILE")" "$LOG_DIR"
	exec 4>&2
	exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&4)
	draw_box "macOS Dev Setup"

	msg "$C_C" "🔍 Checking connectivity and native dependencies..."
	pre_flight_checks

	msg "$C_C" "📦 Initializing tool catalog..."
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

	msg "$C_C" "⚙️  Loading context and syncing project..."

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

	msg "$C_C" "🔄 Checking integrity and drift..."
	startup_drift_check

	msg "$C_G" "✨ Initialization complete!"

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
		menu_opts+=("Install All")
	fi
	if [[ $installed_count -gt 1 ]]; then
		menu_opts+=("Update All")
	fi
	if [[ $installed_count -ge 1 ]]; then
		menu_opts+=("Update Tool")
	fi
	menu_opts+=("Add Tool")
	if [[ $installed_count -ge 1 ]]; then
		menu_opts+=("Remove Tool")
	fi
	if [[ $installed_count -gt 1 ]]; then
		menu_opts+=("Uninstall All")
	fi
	menu_opts+=("Exit")

	local opt
	opt=$(tui_choose "macOS Dev Setup" "${menu_opts[@]}") || exit 0
	printf "🚀 macOS Dev Setup: %b%s%b\n" "$C_C" "$opt" "$C_RESET"

	case "$opt" in
	*"Install All"*)
		ask_sudo
		do_all "install"
		post_operation_hook "$opt"
		;;
	*"Update All"*)
		ask_sudo
		do_all "update"
		post_operation_hook "$opt"
		;;
	*"Update Tool"*)
		ask_sudo
		do_selective "update"
		post_operation_hook "$opt"
		;;
	*"Add"*)
		ask_sudo
		do_search
		post_operation_hook "$opt"
		;;
	*"Remove Tool"*)
		ask_sudo
		do_selective "uninstall"
		post_operation_hook "$opt"
		;;
	*"Uninstall"*)
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
