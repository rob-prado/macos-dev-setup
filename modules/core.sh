#!/usr/bin/env bash

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
	mise)
		if [[ "$tool" == "java" ]]; then
			mise ls-remote java 2>/dev/null | grep -i zulu | grep -vE '(ea|fx)' | grep -oE 'zulu-[0-9.]+' | sed 's/^zulu-//' | sort -Vru || true
		else
			mise ls-remote "$tool" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -Vru || true
		fi
		;;
	xcodes)
		xcodes list 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]' | sort -Vru
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
	msg "$C_Y" "🔑 Privileges required:"
	sudo -v
	while true; do
		sudo -n true
		sleep 60
		kill -0 "$$" || exit
	done 2>/dev/null &
}
