#!/usr/bin/env bash
# Reproducible validation. GODOT=/path/to/godot may override the executable.
set -euo pipefail
cd "$(dirname "$0")/.."
export GODOT="${GODOT:-godot}"
# Writable scratch directories avoid changing a cloud machine's home directory.
task_xdg="$(mktemp -d /tmp/bean-check-XXXXXX)"
trap 'rm -rf "$task_xdg"' EXIT
export XDG_DATA_HOME="$task_xdg/data"
export XDG_CONFIG_HOME="$task_xdg/config"
export XDG_CACHE_HOME="$task_xdg/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# Godot can exit 0 after a script parse error: inspect output as well as status.
check_godot() {
    local result=0
    "$GODOT" --headless --path . "$@" > "$task_xdg/godot.log" 2>&1 || result=$?
    cat "$task_xdg/godot.log"
    if (( result != 0 )); then
        return "$result"
    fi
    if rg -q 'SCRIPT ERROR:|ERROR:' "$task_xdg/godot.log"; then
        return 1
    fi
}
check_godot --editor --import --quit
check_godot --quit-after 5
check_godot --script res://tests/model_test.gd
check_godot --script res://tests/scene_test.gd
python3 tests/network_smoke.py
