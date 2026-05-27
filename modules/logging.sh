#!/usr/bin/env bash

# Logging and auditing utilities extracted from setup.sh

get_local_timestamp() {
	local tz
	tz=$(date +%z)
	printf "%s%s:%s" "$(date +%Y-%m-%dT%H:%M:%S)" "${tz:0:3}" "${tz:3:2}"
}

log_event() {
	local level="$1" message="$2" tool="${3:-}" details="${4:-}"
	mkdir -p "$LOG_DIR"
	local jsonl_file="$LOG_DIR/$(date +%Y%m%d).jsonl"
	local entry
	entry=$(jq -nc --arg ts "$(get_local_timestamp)" --arg level "$level" --arg msg "$message" --arg tool "$tool" --arg details "$details" '{timestamp:$ts,level:$level,message:$msg,tool:$tool,details:$details}' 2>/dev/null) || return 0
	echo "$entry" >>"$jsonl_file"
	[[ "$VERBOSE" == "1" ]] && printf "%s\n" "$entry" || true
}

audit_log() {
	local status="$1" item="$2"
	printf "[%s] %s: %s\n" "$(get_local_timestamp)" "$status" "$item" >>"${CATALOG_FILE%.json}.log"
	log_event "info" "$status" "$item" ""
	case "$status" in
		installed) AUDIT_INSTALLED+=("$item") ;;
		updated)   AUDIT_UPDATED+=("$item")   ;;
		uptodate)  AUDIT_UPTODATE+=("$item") ;;
		skipped)   AUDIT_SKIPPED+=("$item")  ;;
		removed)   AUDIT_REMOVED+=("$item")  ;;
		missing)   AUDIT_MISSING+=("$item")  ;;
		failed)    AUDIT_FAILED+=("$item")   ;;
	esac
}

audit_report() {
	local ti=${#AUDIT_INSTALLED[@]}
	local tu=${#AUDIT_UPDATED[@]}
	local td=${#AUDIT_UPTODATE[@]}
	local ts=${#AUDIT_SKIPPED[@]}
	local tr=${#AUDIT_REMOVED[@]}
	local tm=${#AUDIT_MISSING[@]}
	local tf=${#AUDIT_FAILED[@]}
	local md="# Relatório de Execução\n"
	md+="| Status | Count |\n|---|---|\n"
	md+="| ✅ Instalados | $ti |\n| 🔄 Atualizados | $tu |\n| ✔️ Uptodate | $td |\n| ⏭️ Skipped | $ts |\n| 🗑️ Removidos | $tr |\n| ℹ️ Ausentes | $tm |\n| ❌ Falhas | $tf |\n"
	if [[ $tf -gt 0 ]]; then
		md+="\n"
		for i in "${AUDIT_FAILED[@]}"; do
			md+="- \`$i\`\n"
			done
	fi
	if [[ $ti -gt 0 ]]; then
		md+="\n"
		for i in "${AUDIT_INSTALLED[@]}"; do
			md+="- \`$i\`\n"
			done
	fi
	if [[ $tu -gt 0 ]]; then
		md+="\n"
		for i in "${AUDIT_UPDATED[@]}"; do
			md+="- \`$i\`\n"
			done
	fi
	render_markdown "$md"
}
