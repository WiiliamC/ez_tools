#!/usr/bin/env bash

# Reusable terminal-tab spinner helpers. This file is intended to be sourced.

TERMINAL_TAB_SPINNER_PID=""
TERMINAL_TAB_SPINNER_PROJECT=""
TERMINAL_TAB_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

terminal_tab_spinner_supported() {
    if [ "${TERMINAL_TAB_SPINNER_FORCE:-0}" = "1" ]; then
        return 0
    fi
    [ -t 1 ] && [ "${TERM:-}" != "dumb" ]
}

terminal_tab_spinner_set_title() {
    local title="${1//[[:cntrl:]]/}"

    terminal_tab_spinner_supported || return 0
    printf '\033]0;%s\007' "${title}"
}

terminal_tab_spinner_stop() {
    if [ -n "${TERMINAL_TAB_SPINNER_PID}" ]; then
        kill "${TERMINAL_TAB_SPINNER_PID}" 2>/dev/null || true
        wait "${TERMINAL_TAB_SPINNER_PID}" 2>/dev/null || true
        TERMINAL_TAB_SPINNER_PID=""
    fi

    if [ -n "${TERMINAL_TAB_SPINNER_PROJECT}" ]; then
        terminal_tab_spinner_set_title "${TERMINAL_TAB_SPINNER_PROJECT}"
    fi
}

terminal_tab_spinner_start() {
    local project="$1"
    local status="$2"

    terminal_tab_spinner_stop
    TERMINAL_TAB_SPINNER_PROJECT="${project}"
    terminal_tab_spinner_supported || return 0

    terminal_tab_spinner_set_title "${TERMINAL_TAB_SPINNER_FRAMES[0]} ${project} · ${status}"
    (
        # A background subshell inherits the caller's traps. In particular, an
        # inherited EXIT trap could run the parent script's cleanup when this
        # spinner is stopped.
        trap - EXIT INT TERM
        local index=1
        while true; do
            sleep 0.1
            terminal_tab_spinner_set_title \
                "${TERMINAL_TAB_SPINNER_FRAMES[index]} ${project} · ${status}"
            index=$(((index + 1) % ${#TERMINAL_TAB_SPINNER_FRAMES[@]}))
        done
    ) &
    TERMINAL_TAB_SPINNER_PID=$!
}

terminal_tab_spinner_finish() {
    local project="$1"

    terminal_tab_spinner_stop
    TERMINAL_TAB_SPINNER_PROJECT="${project}"
    terminal_tab_spinner_set_title "! ${project}"
}
