#!/usr/bin/env bash

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
			mise)
				if command -v mise &>/dev/null; then
					local -a installed wanted
					readarray -t installed < <(mise ls "$t" 2>/dev/null | awk '$1=="'"$t"'"{print $2}' | sed 's/^zulu-//' || true)
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
				fi
				;;
			*)
				;;
			esac
		elif [[ "$type" == "formula" || "$type" == "cask" || "$type" == "gem" ]]; then
			if ! health_check "$t" "$type" &>/dev/null; then
				update_lock_entry "$t" "" "removed"
			fi
		fi
	done
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
			mise exec node -- node -e 'process.exit(0)' 2>/dev/null || return 1
			;;
		yarn)
			[[ "$(mise exec yarn -- yarn -v 2>/dev/null)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
			;;
		java)
			mise exec java -- command -v java &>/dev/null && mise exec java -- java -version 2>&1 | grep -qi 'openjdk' || return 1
			;;
		ruby)
			mise exec ruby -- command -v ruby &>/dev/null || return 1
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
