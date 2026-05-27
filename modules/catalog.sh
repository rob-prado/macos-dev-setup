#!/usr/bin/env bash

migrate_catalog() {
	[[ ! -f "$CATALOG_FILE" ]] && return 0
	local current
	current=$(jq -r '.schema_version // 1' "$CATALOG_FILE" 2>/dev/null || echo 1)
	if [[ "$current" -lt 2 ]]; then
		msg "$C_C" "🔄 Migrando catálogo v$current → v$CATALOG_SCHEMA_VERSION..."
		local tmp
		tmp=$(mktemp)
		TMP_FILES+=("$tmp")
		if jq \
			--argjson sv "$CATALOG_SCHEMA_VERSION" \
			'. + {schema_version: $sv}
			| if .tools.cocoapods == null
				then .tools.cocoapods = {"type":"gem","version":""}
				else .
			end' \
			"$CATALOG_FILE" >"$tmp"; then
			mv "$tmp" "$CATALOG_FILE"
		else
			rm -f "$tmp"
		fi
		msg "$C_G" "✅ Migração concluída."
	fi
}

catalog_init() {
	[[ -f "$CATALOG_FILE" ]] && return 0
	cat <<EOF >"$CATALOG_FILE"
{"schema_version":$CATALOG_SCHEMA_VERSION,"tools":{"watchman":{"type":"formula","version":""},"xcbeautify":{"type":"formula","version":""},"cocoapods":{"type":"gem","version":"","dependencies":["ruby"]},"node":{"type":"managed","manager":"fnm","versions":[]},"yarn":{"type":"managed","manager":"corepack","versions":[],"dependencies":["node"]},"java":{"type":"managed","manager":"sdkman","versions":[]},"ruby":{"type":"managed","manager":"chruby","versions":[]},"xcode":{"type":"managed","manager":"xcodes","versions":[]},"visual-studio-code":{"type":"cask","version":""},"reactotron":{"type":"cask","version":""},"android-studio":{"type":"cask","version":""}}}
EOF
}

validate_catalog_schema() {
	local schema='.tools | type == "object" and all(.[]; has("type") and (.type | test("^(formula|cask|managed|gem)$")) and if .type == "managed" then has("manager") else true end)'
	jq -e "$schema" "$CATALOG_FILE" >/dev/null 2>&1 || err "Catálogo inválido. Schema não respeitado."
}

_jq_update() {
	local f="$1"
	local tmp lock_dir retries=50
	tmp=$(mktemp)
	lock_dir="${CATALOG_FILE}.lock.d"
	TMP_FILES+=("$tmp")
	cp "$CATALOG_FILE" "${CATALOG_FILE}.bak" 2>/dev/null || true
	while ! mkdir "$lock_dir" 2>/dev/null; do
		((retries-- <= 0)) && {
			rm -f "$tmp"
			return 1
		}
		sleep 0.1
	done
	echo $$ >"$lock_dir/pid"
	if jq "$f" "$CATALOG_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$CATALOG_FILE"
	else
		rm -f "$tmp"
	fi
	rm -rf "$lock_dir"
}

c_get() {
	jq -r ".tools[\"$1\"].$2 // empty" "$CATALOG_FILE" 2>/dev/null || true
}

c_get_versions() {
	jq -r ".tools[\"$1\"].versions[]?" "$CATALOG_FILE" 2>/dev/null || true
}

c_add_version() {
	_jq_update ".tools[\"$1\"].versions = ((.tools[\"$1\"].versions // []) + [\"$2\"] | unique)"
}

c_set_version() {
	local t
	t=$(c_get "$1" "type")
	if [[ "$t" == "managed" ]]; then
		_jq_update "del(.tools[\"$1\"].version)"
	else
		_jq_update ".tools[\"$1\"].version = \"$2\""
	fi
}

c_clear_versions() {
	local t
	t=$(c_get "$1" "type")
	if [[ "$t" == "managed" ]]; then
		_jq_update "del(.tools[\"$1\"].version) | .tools[\"$1\"].versions = []"
	else
		_jq_update ".tools[\"$1\"].version = \"\""
	fi
}

register_tool_state() {
	local tool="$1" version="$2" state="$3"
	local type
	type=$(c_get "$tool" "type")
	if [[ "$type" == "managed" ]]; then
		c_add_version "$tool" "$version"
	else
		c_set_version "$tool" "$version"
	fi
	update_lock_entry "$tool" "$version" "$state"
}

catalog_reconcile() {
	local -a current
	readarray -t current < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)
	for t in "${current[@]}"; do
		[[ -z "${t:-}" ]] && continue
		local type
		type=$(c_get "$t" "type")
		if [[ "$type" == "formula" || "$type" == "cask" ]]; then
			if brew list "${type:+--$type}" "$t" &>/dev/null; then
				local ver
				ver=$(brew list "${type:+--$type}" --versions "$t" 2>/dev/null | awk '{print $NF}' || true)
				if [[ -n "$ver" ]]; then
					_jq_update ".tools[\"$t\"].version = \"$ver\""
					update_lock_entry "$t" "$ver" "installed"
				fi
			else
				_jq_update ".tools[\"$t\"].version = \"\""
				update_lock_entry "$t" "" "removed"
			fi
		elif [[ "$type" == "gem" ]]; then
			if command -v gem &>/dev/null && run_in_ruby_env "gem list -i '${t}' &>/dev/null" 2>/dev/null; then
				local ver
				ver=$(run_in_ruby_env "gem list -e '${t}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>/dev/null || true)
				if [[ -n "$ver" ]]; then
					_jq_update ".tools[\"$t\"].version = \"$ver\""
					update_lock_entry "$t" "$ver" "installed"
				fi
			else
				_jq_update ".tools[\"$t\"].version = \"\""
				update_lock_entry "$t" "" "removed"
			fi
		elif [[ "$type" == "managed" ]]; then
			local mgr
			local is_installed=false
			mgr=$(c_get "$t" "manager")
			local -a vers=()
			case "$mgr" in
			fnm)
				if command -v fnm &>/dev/null; then
					is_installed=true
					readarray -t vers < <(fnm list 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' || true)
				fi
				;;
			sdkman)
				if [[ -d "$SDKMAN_DIR/candidates/java" ]]; then
					is_installed=true
					readarray -t vers < <(ls -1 "$SDKMAN_DIR/candidates/java" 2>/dev/null | grep -v 'current' || true)
				fi
				;;
			chruby)
				if [[ -d "$HOME/.rubies" ]]; then
					is_installed=true
					readarray -t vers < <(ls -1 "$HOME/.rubies" 2>/dev/null | sed 's/ruby-//' || true)
				fi
				;;
			corepack)
				local yv
				yv=$(yarn -v 2>/dev/null || true)
				if [[ -n "$yv" ]]; then
					is_installed=true
					vers=("$yv")
				fi
				;;
			xcodes)
				if command -v xcodes &>/dev/null; then
					is_installed=true
					readarray -t vers < <(xcodes installed 2>/dev/null | awk '{print $1}' || true)
				fi
				;;
			esac

			local -a clean_vers=()
			for v in "${vers[@]}"; do
				[[ -n "${v:-}" ]] && clean_vers+=("$v")
			done

			if [[ "$is_installed" == "true" && ${#clean_vers[@]} -gt 0 ]]; then
				local v_json
				v_json=$(printf '%s\n' "${clean_vers[@]}" | jq -R . | jq -s -c .)
				_jq_update ".tools[\"$t\"].versions = $v_json"
				update_lock_entry "$t" "" "installed"
			else
				_jq_update ".tools[\"$t\"].versions = []"
				update_lock_entry "$t" "" "removed"
			fi
		fi
	done
}
