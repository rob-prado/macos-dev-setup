#!/usr/bin/env bash
set -euo pipefail

# UI functions extracted from original setup.sh

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
		prompt=$'\n'${C_Y}┌────────────────────────────────────────┐${C_RESET}$'\n'
		prompt+=${C_Y}│  🔑 [SUDO] PRIVILÉGIOS REQUERIDOS       │${C_RESET}$'\n'
		prompt+=${C_Y}└────────────────────────────────────────┘${C_RESET}$'\n'
		prompt+=${C_BOLD}${C_W}Digite a senha para o usuário ${C_C}%u${C_W}:${C_RESET}$'\n❯ '
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
		"$(repeat_char \"$lp\" ' ')" "${C_BOLD}${C_W}" "$t" "${C_RESET}" "$(repeat_char \"$rp\" ' ')" \
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
	printf '\n%s%s[%02d/%02d]%s %b%-15s%b %s%s%s%s%s\\n' \
		"$C_BOLD" "$C_C" "$c" "$t" "$C_RESET" \
		"$C_BOLD" "${l:0:15}" "$C_RESET" \
		"$C_G" "$(repeat_char \"$f\" '■')" \
		"$C_D" "$(repeat_char \"$e\" '·')" "$C_RESET"
}

render_markdown() {
	local content="$1"
	if [[ "$HAS_GLOW" == "true" ]]; then
		echo "$content" | glow -w "$TERM_WIDTH" -s dark 2>/dev/null || echo "$content"
	else
		echo "$content"
	fi
}
