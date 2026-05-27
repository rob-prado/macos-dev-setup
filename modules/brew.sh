#!/usr/bin/env bash

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
