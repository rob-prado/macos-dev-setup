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
