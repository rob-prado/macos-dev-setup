# TUI module extracted from setup.sh

# Interactive terminal UI functions used throughout the setup script.
# These functions rely on "gum" for rich TUI components and fall back to plain
# Bash prompts when gum is unavailable.

tui_choose() {
    local prompt="$1"
    shift
    if [[ "$HAS_GUM" == "true" ]]; then
        local err_fd=2
        { true >&4; } 2>/dev/null && err_fd=4
        local tmp
        tmp=$(mktemp)
        gum choose --header "$prompt" \
            --height=12 \
            --cursor="> " \
            --cursor.foreground="#FFD700" \
            --selected.background="#3B82F6" \
            --selected.foreground="#FFFFFF" \
            --item.foreground="#E9E9E9" \
            --header.foreground="#56B9F8" \
            "$@" >"$tmp" 2>&$err_fd
        local status=$?
        local val
        val=$(cat "$tmp")
        rm -f "$tmp"
        if [[ $status -eq 0 && -n "${val:-}" ]]; then
            echo "$val"
            return 0
        else
            return 1
        fi
    else
        printf "\n%b%s%b\n" "$C_Y" "$prompt" "$C_RESET"
        local i=1
        for opt in "$@"; do
            printf "  %b%2d)%b %s\n" "$C_C" "$i" "$C_RESET" "$opt"
            ((i++))
        done
        printf "\n%bChoose [1-%d]:%b " "$C_D" "$#" "$C_RESET"
        read -r sel
        [[ -n "${sel:-}" && "$sel" -ge 1 && "$sel" -le $# ]] && echo "${!sel}" || return 1
    fi
}


tui_multi_choose() {
    local prompt="$1"
    shift
    if [[ "$HAS_GUM" == "true" ]]; then
        local err_fd=2
        { true >&4; } 2>/dev/null && err_fd=4
        local tmp
        tmp=$(mktemp)
        gum choose --no-limit --show-help --header "$prompt" \
            --height=12 \
            --cursor="> " \
            --cursor.foreground="#FFD700" \
            --selected.background="#3B82F6" \
            --selected.foreground="#FFFFFF" \
            --item.foreground="#E9E9E9" \
            --header.foreground="#56B9F8" \
            "$@" >"$tmp" 2>&$err_fd
        local status=$?
        cat "$tmp"
        rm -f "$tmp"
        return $status
    else
        printf "\n%b%s%b\n" "$C_Y" "$prompt" "$C_RESET"
        local i=1
        for opt in "$@"; do
            printf "  %b%2d)%b %s\n" "$C_C" "$i" "$C_RESET" "$opt"
            ((i++))
        done
        printf "\n%bSelect (numbers separated by spaces):%b " "$C_D" "$C_RESET"
        read -r -a sel_arr
        for s in "${sel_arr[@]}"; do
            local idx=$((s - 1))
            [[ $idx -ge 0 && $idx -lt $# ]] && echo "${!s}"
        done
    fi
}


tui_filter() {
    local prompt="$1"
    shift
    local err_fd=2
    { true >&4; } 2>/dev/null && err_fd=4
    if [[ "$HAS_GUM" == "true" && "${TERM_PROGRAM:-}" != "Apple_Terminal" ]]; then
        local tmp
        tmp=$(mktemp)
        printf '%s\n' "$@" | gum filter \
            --height=10 \
            --placeholder="$prompt" \
            --indicator="❯ " \
            --indicator.foreground="#FFD700" \
            --match.foreground="#6AAF50" \
            --prompt.foreground="#56B9F8" >"$tmp" 2>&$err_fd
        local status=$?
        local val
        val=$(cat "$tmp")
        rm -f "$tmp"
        if [[ $status -eq 0 && -n "${val:-}" ]]; then
            echo "$val"
            return 0
        else
            return 1
        fi
    else
        printf "\n  %b%s%b\n" "$C_Y" "$prompt" "$C_RESET"
        local i=1
        for r in "$@"; do
            printf "  %b%2d)%b %s\n" "$C_C" "$i" "$C_RESET" "$r"
            ((i++))
        done
        printf "\n%bChoose [1-%d]:%b " "$C_D" "$#" "$C_RESET"
        local sel
        read -r sel < /dev/tty
        if [[ -n "${sel:-}" && "$sel" -ge 1 && "$sel" -le $# ]]; then
            local -a items=("$@")
            echo "${items[$((sel - 1))]}"
        else
            return 1
        fi
    fi
}


tui_confirm() {
    local prompt="$1" danger="${2:-false}"
    [[ "$AUTO_YES" == "true" || "$DRY_RUN" == "1" ]] && return 0
    if [[ "$HAS_GUM" == "true" ]]; then
        local pf="#56B9F8" sb="#6AAF50"
        local err_fd=2
        { true >&4; } 2>/dev/null && err_fd=4
        [[ "$danger" == "true" ]] && {
            pf="#EF4444"
            sb="#EF4444"
        }
        gum confirm "$prompt" \
            --affirmative "Yes" \
            --negative "No" \
            --prompt.foreground="$pf" \
            --selected.background="$sb" \
            --selected.foreground="#000000" \
            --unselected.background="#343746" \
            --unselected.foreground="#F8F8F2" 2>&$err_fd
    else
        printf "\n%b⚠️  %s%b\n" "$C_Y" "$prompt" "$C_RESET"
        printf "%bContinue? [y/N]:%b " "$C_Y" "$C_RESET"
        read -r ans
        [[ "${ans,,}" =~ ^(y|yes)$ ]]
    fi
}


tui_input() {
    local prompt="$1" placeholder="${2:-}"
    local err_fd=2
    { true >&4; } 2>/dev/null && err_fd=4
    if [[ "$HAS_GUM" == "true" && "${TERM_PROGRAM:-}" != "Apple_Terminal" ]]; then
        local tmp
        tmp=$(mktemp)
        gum input --placeholder "$placeholder" \
            --prompt "$prompt" \
            --prompt.foreground="#56B9F8" \
            --placeholder.foreground="#9E9E9E" \
            --cursor.foreground="#FFD700" >"$tmp" 2>&$err_fd
        local status=$?
        local val
        val=$(cat "$tmp")
        rm -f "$tmp"
        if [[ $status -eq 0 ]]; then
            echo "$val"
            return 0
        else
            return 1
        fi
    else
        printf "\n  %b%s%b " "$C_C" "$prompt" "$C_RESET"
        local val
        read -r val < /dev/tty
        echo "$val"
    fi
}

confirm_destructive() {
    tui_confirm "$1" true
}
