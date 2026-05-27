#!/usr/bin/env bash

ensure_lockfile() {
	[[ -f "$LOCK_FILE" ]] && return 0
	local hash
	hash=$(shasum -a 256 "$CATALOG_FILE" | cut -d' ' -f1)
	printf '{"catalog_hash":"%s","generated_at":"%s","tools":{}}
' "$hash" "$(get_local_timestamp)" >"$LOCK_FILE"
}

update_lock_entry() {
	local tmp lock_dir retries=50
	local tool="$1" val="$2" state="$3"
	local type
	type=$(c_get "$tool" "type")
	tmp=$(mktemp)
	lock_dir="${LOCK_FILE}.lock.d"
	TMP_FILES+=("$tmp")
	while ! mkdir "$lock_dir" 2>/dev/null; do
		((retries-- <= 0)) && {
			rm -f "$tmp"
			return 1
		}
		sleep 0.1
	done
	echo $$ >"$lock_dir/pid"

	local success=false
	if [[ "$type" == "managed" ]]; then
		local -a vers=()
		readarray -t vers < <(c_get_versions "$tool")
		local vers_json
		if [[ ${#vers[@]} -gt 0 ]]; then
			vers_json=$(printf '%s\n' "${vers[@]}" | jq -R . | jq -s -c .)
		else
			vers_json="[]"
		fi
		if jq \
			--arg t "$tool" \
			--argjson v "$vers_json" \
			--arg s "$state" \
			--arg ts "$(get_local_timestamp)" \
			'.tools[$t]={versions:$v,status:$s} | .generated_at=$ts' \
			"$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
			success=true
		fi
	else
		if jq \
			--arg t "$tool" \
			--arg v "${val:-}" \
			--arg s "$state" \
			--arg ts "$(get_local_timestamp)" \
			'.tools[$t]={version:$v,status:$s} | .generated_at=$ts' \
			"$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
			success=true
		fi
	fi

	if [[ "$success" == "false" ]]; then
		rm -f "$tmp"
	fi
	rm -rf "$lock_dir"
}

validate_lock_consistency() {
	[[ ! -f "$LOCK_FILE" ]] && return 0
	local ch lh
	ch=$(shasum -a 256 "$CATALOG_FILE" | cut -d' ' -f1)
	lh=$(jq -r '.catalog_hash' "$LOCK_FILE" 2>/dev/null || true)
	if [[ "$ch" != "$lh" ]]; then
		local tmp lock_dir retries=50
		tmp=$(mktemp)
		lock_dir="${LOCK_FILE}.lock.d"
		TMP_FILES+=("$tmp")
		while ! mkdir "$lock_dir" 2>/dev/null; do
			((retries-- <= 0)) && {
				rm -f "$tmp"
				return 0
			}
			sleep 0.1
		done
		echo $$ >"$lock_dir/pid"
		if jq --arg h "$ch" --arg ts "$(get_local_timestamp)" '.catalog_hash = $h | .generated_at = $ts' "$LOCK_FILE" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$LOCK_FILE"
		else
			rm -f "$tmp"
		fi
		rm -rf "$lock_dir"
	fi
	return 0
}

