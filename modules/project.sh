#!/usr/bin/env bash

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
	[[ -z "${preset_tools:-}" ]] && err "Unknown preset: $preset"
	confirm_destructive "Replace catalog with preset '$preset'?" || return 0
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
	msg "$C_G" "✅ Catalog updated with preset '$preset'."
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
		mise)
			if command -v mise &>/dev/null; then
				local mise_ver="$ver"
				[[ "$tool" == "java" ]] && mise_ver="zulu-$ver"
				mise ls "$tool" 2>/dev/null | awk '$1=="'"$tool"'" && !/\(missing\)/ {print $2}' | grep -qE "^$mise_ver(\.|$)" && return 0
			fi
			;;
		xcodes)
			if command -v xcodes &>/dev/null; then
				xcodes installed 2>/dev/null | awk '{print $1}' | grep -qE "^$ver(\.|$)" && return 0
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
			msg "$C_G" "📝 .node-version → $node_v${current_nv:+ (was $current_nv)}"
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
		[[ -f ".java-version" ]] && current_jv=$(cat .java-version 2>/dev/null | tr -d '[:space:]' || true)

		local resolved_java="$java_v"
		# Let mise install and use the passed version
		
		if [[ ! -f ".java-version" ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				printf '%s
' "$resolved_java" >".java-version"
			fi
			msg "$C_G" "📝 .java-version → $resolved_java"
			any_created=true
		elif [[ "$current_jv" != "$resolved_java" ]]; then
			if [[ "$DRY_RUN" != "1" ]]; then
				printf '%s
' "$resolved_java" >".java-version"
			fi
			msg "$C_G" "📝 .java-version → $resolved_java (updated from $current_jv)"
			any_created=true
		fi
	fi

	return 0
}

print_version_activation_hint() {
	printf '\n  %b💡 To activate project versions in this shell:%b\n' "$C_Y" "$C_RESET"
	printf '     %bcd .%b  %b# triggers mise auto-switch%b\n\n' "$C_BOLD$C_W" "$C_RESET" "$C_D" "$C_RESET"
}

ensure_corepack_project_yarn() {
	local yarn_v="${1:-}"
	[[ -z "$yarn_v" || ! -f "package.json" ]] && return 0

	# Only for yarn v2+ (v1 uses npm global install)
	local major="${yarn_v%%.*}"
	[[ "$major" -lt 2 ]] 2>/dev/null && return 0

	if [[ "$DRY_RUN" == "1" ]]; then
		msg "$C_G" "📦 corepack → yarn@$yarn_v (simulated)"
		return 0
	fi

	if ! command -v corepack &>/dev/null; then
		command -v npm &>/dev/null && npm install -g corepack@latest &>/dev/null || return 0
	fi

	# Remove npm-installed global yarn — it shadows corepack shims
	if npm list -g --depth=0 yarn 2>/dev/null | grep -q 'yarn@'; then
		msg "$C_C" "🔄 Removing global yarn (npm) to prioritize corepack..."
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
	if [[ -f "package.json" || -f ".nvmrc" || -f ".node-version" || -f ".ruby-version" || -f ".java-version" || -f ".sdkmanrc" || -f "Gemfile" || -d "android" || -d "ios" || -f "ReactotronConfig.js" || -f "reactotron.config.js" ]]; then
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
	[[ -f ".java-version" || -f ".sdkmanrc" ]] && detected+=("java")

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
	if [[ -f ".java-version" ]]; then
		detected+=("java:$(cat .java-version | tr -d '[:space:]' || echo "")")
	elif [[ -f ".sdkmanrc" ]]; then
		detected+=("java:$(grep 'java=' .sdkmanrc | cut -d= -f2 | tr -d '[:space:]' || echo "")")
	fi

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
				msg "$C_G" "📝 .nvmrc → $max_node (updated from $nvmrc_v)"
			fi
		fi
		if [[ -f ".node-version" ]]; then
			local nv_v
			nv_v=$(tr -d '[:space:]' <".node-version" 2>/dev/null || echo "")
			if is_smaller_version "$nv_v" "$max_node"; then
				if [[ "$DRY_RUN" != "1" ]]; then
					echo "$max_node" >".node-version"
				fi
				msg "$C_G" "📝 .node-version → $max_node (updated from $nv_v)"
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
					msg "$C_G" "📝 package.json (.engines.node) → $max_node (updated from $pkg_node)"
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
				msg "$C_G" "📝 .ruby-version → $max_ruby (updated from $rv_v)"
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
					msg "$C_G" "📝 package.json (.rubyVersion) → $max_ruby (updated from $pkg_ruby)"
				else
					rm -f "$tmp"
				fi
			fi
		fi
	fi

	if [[ -n "${max_versions[java]:-}" ]]; then
		local max_java="${max_versions[java]}"
		if [[ -f ".java-version" ]]; then
			local jv_v
			jv_v=$(cat .java-version 2>/dev/null | tr -d '[:space:]' || echo "")
			local jv_major max_java_major
			jv_major=$(echo "$jv_v" | grep -oE '^[0-9]+' || echo "")
			max_java_major=$(echo "$max_java" | grep -oE '^[0-9]+' || echo "")
			if is_smaller_version "$jv_major" "$max_java_major"; then
				if [[ "$DRY_RUN" != "1" ]]; then
					echo "$max_java" >".java-version"
				fi
				msg "$C_G" "📝 .java-version → $max_java (updated from $jv_v)"
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
					msg "$C_G" "📝 package.json (.javaVersion) → $max_java (updated from $pkg_java)"
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
					msg "$C_G" "📝 package.json (.packageManager) → yarn@$max_yarn (updated from yarn@$pkg_yarn)"
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
		printf '\n  %b╭─ 🔍 New requirements in %b%s%b ─╮%b\n' "$C_C" "$C_BOLD$C_W" "$(basename "$PWD")" "$C_RESET$C_C" "$C_RESET"
		printf '\n'
		for item in "${to_merge[@]}"; do
			_print_req_item "$item"
		done
		[[ "$needs_bundle" == "true" ]] && printf '     %b▸%b  %b%-18s%b %b→  Gemfile%b\n' "$C_C" "$C_RESET" "$C_W" "bundler" "$C_RESET" "$C_Y" "$C_RESET"
		printf '\n'
		if tui_confirm "Merge into global catalog and install?"; then
			merge_stack_into_catalog "${to_merge[@]}"
			should_install=true
		fi
	else
		printf '\n  %b╭─ 🔍 Uninstalled project requirements ─╮%b\n' "$C_C" "$C_RESET"
		printf '\n'
		for item in "${to_install[@]}"; do
			_print_req_item "$item"
		done
		[[ "$needs_bundle" == "true" ]] && printf '     %b▸%b  %b%-18s%b %b→  Gemfile%b\n' "$C_C" "$C_RESET" "$C_W" "bundler" "$C_RESET" "$C_Y" "$C_RESET"
		printf '\n'
		if tui_confirm "Install now?"; then
			should_install=true
		fi
	fi

	if [[ "$should_install" == "true" ]]; then
		msg "$C_C" "🚀 Installing project tools..."
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
			msg "$C_C" "💎 Installing Ruby dependencies via Bundler..."
			run_step "Installing" "Gemfile gems" "Gemfile gems" "Gemfile gems" "installed" run_in_ruby_env "gem install bundler --no-document && bundle install" || true
		fi

		rm -f "$LOCK_FILE"
		ensure_lockfile
		msg "$C_G" "✅ Installation completed successfully!"
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
	msg "$C_G" "✅ Global catalog updated (Merge)."
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
			msg "$C_C" "📥 Snapshot detected: $snap"
			tui_confirm "Import automatically?" && {
				snapshot_import "$snap"
				return 0
			}
		fi
	done

	if tui_confirm "Empty catalog. Load a base preset?"; then
		load_preset
	fi
}

# ==============================================================================
