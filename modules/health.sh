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
