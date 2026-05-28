#!/usr/bin/env bash

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
	mise)
		command -v mise &>/dev/null || retry 3 brew install mise
		grep -q 'mise activate' "$ENV_FILE" 2>/dev/null || \
			pf_add "eval \"\$(mise activate \${SHELL##*/})\""
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
		mise)
			if [[ "$tool" == "java" ]]; then
				lv=$(mise ls-remote java 2>/dev/null | grep -i zulu | grep -vE '(ea|fx)' | grep -oE 'zulu-[0-9.]+' | sed 's/^zulu-//' | sort -Vru | head -1 || true)
			else
				lv=$(mise ls-remote "$tool" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -Vr | head -1 || true)
			fi
			;;
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
	mise)
		for v in "${uv[@]}"; do
			local success=false iv
			local mise_ver="$v"
			if [[ "$tool" == "java" ]]; then
				mise_ver="zulu-$v"
				if ! mise ls-remote java 2>/dev/null | grep -q "$mise_ver"; then
					mise_ver="zulu-${v%%.*}"
				fi
			fi
			
			iv=$(mise ls "$tool" 2>/dev/null | awk '$1=="'"$tool"'" && $2=="'"$mise_ver"'" && !/\(missing\)/ {print $2}' || true)
			if [[ -n "$iv" ]]; then
				printf '
%s✓ %s %s ok%s
' "${C_D}" "${tool^}" "$v" "${C_RESET}"
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "${tool^} $v"
				else
					audit_log skipped "${tool^} $v"
				fi
				success=true
			else
				if run_step "Instalando" "${tool^} $v" "${tool^} $v" "${tool^} $v" "installed" mise install -y "$tool@$mise_ver"; then
					success=true
				fi
			fi
			if [[ "$success" == "true" ]]; then
				mise use -g "$tool@$mise_ver" >/dev/null 2>&1 || true
				[[ "$tool" == "java" ]] && c_add_version "$tool" "$v"
				register_tool_state "$tool" "$v" "installed"
			fi
		done
		;;
	xcodes)
		for v in "${uv[@]}"; do
			local ins success=false
			ins=$(xcodes installed 2>/dev/null | grep -E "^$v" || true)
			if [[ -n "${ins:-}" ]]; then
				printf '
%s✓ Xcode %s ok%s
' "${C_D}" "$v" "${C_RESET}"
				run_bg "Select" "Xcode $v" sudo xcodes select "$v" &>/dev/null || true
				if [[ "$mode" == "update" ]]; then
					audit_log uptodate "Xcode $v"
				else
					audit_log skipped "Xcode $v"
				fi
				success=true
			else
				msg "$C_Y" "⚠️ Xcode $v requer Apple ID (senha + 2FA)"
				printf '  %b📲 A instalação será interativa — insira suas credenciais Apple quando solicitado.%b

' "$C_W" "$C_RESET"
				if [[ "$DRY_RUN" == "1" ]]; then
					printf '+ xcodes install %q --experimental-unxip --no-superuser
' "$v"
					printf '+ sudo xcode-select -s /Applications/Xcode*.app/Contents/Developer
'
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
	mise)
		if command -v mise &>/dev/null; then
			readarray -t inst_versions < <(mise ls "$tool" 2>/dev/null | awk '$1=="'"$tool"'" && !/\(missing\)/ {print $2}' | sed 's/^zulu-//' || true)
		fi
		;;
	xcodes)
		if command -v xcodes &>/dev/null; then
			readarray -t inst_versions < <(xcodes installed 2>/dev/null | awk '{print $1}' || true)
		fi
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
		mise)
			local mise_ver="$v"
			if [[ "$tool" == "java" ]]; then
				mise_ver="zulu-$v"
				if ! mise ls-remote java 2>/dev/null | grep -q "$mise_ver"; then
					mise_ver="zulu-${v%%.*}"
				fi
			fi
			run_step "Removendo" "${tool^} $v" "${tool^} $v" "${tool^} $v" "removed" mise uninstall "$tool@$mise_ver"
			;;
		xcodes)
			run_step "Removendo" "Xcode $v" "Xcode $v" "Xcode $v" "removed" sudo xcodes uninstall "$v"
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
			mise)
				run_step "Removendo" "$tool" "versões do ${tool^}" "versões do ${tool^}" "removed" mise uninstall --all "$tool" || audit_log missing "$tool"
				brew list "$tool" &>/dev/null && run_bg "Limpando" "$tool" brew uninstall --force "$tool" || true
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
		mise)
			readarray -t inst < <(
				mise ls "$tool" 2>/dev/null | awk '$1=="'"$tool"'" && !/\(missing\)/ {print $2}' | sed 's/^zulu-//' || true
			)
			;;
		xcodes)
			readarray -t inst < <(
				xcodes installed 2>/dev/null | awk '{print $1}' || true
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
				mise)
					local mise_ver="$iv"
					[[ "$tool" == "java" ]] && mise_ver="zulu-$iv"
					run_bg "RM ${tool^}" "$iv" mise uninstall "$tool@$mise_ver" || true
					;;
				xcodes)
					run_bg "RM Xcode" "$iv" xcodes uninstall "$iv" || true
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
