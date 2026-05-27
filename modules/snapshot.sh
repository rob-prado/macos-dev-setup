#!/usr/bin/env bash

snapshot_export() {
	local output="${1:-$HOME/mac-dev-snapshot.json}"
	local snapshot first=true
	snapshot='{"generated_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","arch":"'$(uname -m)'","tools":{'
	local -a tools
	readarray -t tools < <(get_managed_tools_list)
	for t in "${tools[@]}"; do
		local type resolved=""
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" ]]; then
			local mgr
			mgr=$(c_get "$t" "manager")
			case "$mgr" in
			fnm)
				resolved=$(fnm default 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
				;;
			sdkman)
				resolved=$(readlink "$SDKMAN_DIR/candidates/java/current" 2>/dev/null | xargs basename 2>/dev/null || true)
				;;
			chruby)
				resolved=$(grep -oE 'chruby ruby-[0-9.]+' "$ENV_FILE" 2>/dev/null | sed 's/chruby ruby-//' || true)
				;;
			corepack)
				resolved=$(yarn -v 2>/dev/null || true)
				;;
			xcodes)
				resolved=$(xcodebuild -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
				;;
			esac
		elif [[ "$type" == "gem" ]]; then
			resolved=$(run_in_ruby_env "gem list -e '${t}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>/dev/null || true)
		else
			resolved=$(brew list --versions "$t" 2>/dev/null | awk '{print $NF}' | head -1 || true)
		fi

		if [[ -z "${resolved:-}" ]]; then
			continue
		fi

		if [[ "$first" == "true" ]]; then
			first=false
		else
			snapshot+=","
		fi
		snapshot+="\"$t\":\"$resolved\""
	done
	snapshot+='}}'
	echo "$snapshot" | jq '.' >"$output"
	msg "$C_G" "✅ Snapshot: $output"
}

snapshot_import() {
	local input="${1:-}"
	[[ -z "${input:-}" || ! -f "$input" ]] && err "Snapshot não encontrado"
	jq -e '.tools | type == "object"' "$input" >/dev/null 2>&1 || err "Snapshot inválido"
	local -a snap_tools
	readarray -t snap_tools < <(jq -r '.tools | keys[]' "$input" 2>/dev/null || true)
	for t in "${snap_tools[@]}"; do
		local ver
		ver=$(jq -r ".tools[\"$t\"]" "$input" 2>/dev/null || true)
		[[ -z "${ver:-}" || "$ver" == "null" ]] && continue
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "managed" ]]; then
			_jq_update "del(.tools[\"$t\"].version) | .tools[\"$t\"].versions = [\"$ver\"]"
		else
			_jq_update ".tools[\"$t\"].version = \"$ver\""
		fi
	done
	msg "$C_G" "✅ Snapshot importado."
}
