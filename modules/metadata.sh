#!/usr/bin/env bash

get_known_managed() {
	case "$1" in
	node) echo "fnm" ;;
	java) echo "sdkman" ;;
	ruby) echo "chruby" ;;
	yarn) echo "corepack" ;;
	xcode) echo "xcodes" ;;
	*) return 1 ;;
	esac
}

get_preset_tools() {
	case "$1" in
	minimal) echo "watchman xcbeautify" ;;
	rn) echo "watchman xcbeautify node yarn java visual-studio-code reactotron android-studio" ;;
	full) echo "watchman xcbeautify node yarn java ruby xcode visual-studio-code reactotron android-studio cocoapods" ;;
	java) echo "watchman java visual-studio-code android-studio" ;;
	*) return 1 ;;
	esac
}

list_presets() {
	echo "minimal"
	echo "rn"
	echo "full"
	echo "java"
}

c_get_dependencies() {
	local tool="$1"
	local deps
	deps=$(jq -r ".tools[\"$tool\"].dependencies[]? // empty" "$CATALOG_FILE" 2>/dev/null || true)
	if [[ -z "${deps:-}" ]]; then
		case "$tool" in
		cocoapods)
			echo "ruby"
			;;
		yarn)
			echo "node"
			;;
		esac
	else
		echo "$deps"
	fi
}

resolve_dependencies_rec() {
	local tool="$1"

	if [[ " $RESOLVED_LIST " == *" $tool "* ]]; then
		return 0
	fi

	if [[ " $VISITING_LIST " == *" $tool "* ]]; then
		err "Erro: Dependência circular detectada envolvendo a ferramenta '$tool'!"
	fi

	VISITING_LIST="${VISITING_LIST} ${tool}"

	local dep
	while IFS= read -r dep; do
		if [[ -n "${dep:-}" ]]; then
			resolve_dependencies_rec "$dep"
		fi
	done < <(c_get_dependencies "$tool")

	VISITING_LIST=" ${VISITING_LIST} "
	VISITING_LIST="${VISITING_LIST/ $tool / }"
	VISITING_LIST=$(echo "$VISITING_LIST" | xargs)

	RESOLVED_LIST="${RESOLVED_LIST} ${tool}"
	RESOLVED_ORDER+=("$tool")
}

get_ordered_tools() {
	local -a current
	readarray -t current < <(jq -r '.tools | if type=="object" then keys[] else empty end' "$CATALOG_FILE" 2>/dev/null || true)

	RESOLVED_ORDER=()
	VISITING_LIST=""
	RESOLVED_LIST=""

	for t in "${current[@]}"; do
		if [[ -n "${t:-}" ]]; then
			resolve_dependencies_rec "$t"
		fi
	done

	printf '%s\n' "${RESOLVED_ORDER[@]}"
}
