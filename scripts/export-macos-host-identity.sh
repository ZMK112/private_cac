#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${HOME}/.cac"
FORCE=false
PRINT_ONLY=false

usage() {
    cat <<'EOF'
Usage: export-macos-host-identity.sh [--target-dir DIR] [--force] [--print-only]

Capture host identity fields from the current macOS machine and write them to:
  host_serial_number
  host_model
  host_manufacturer

Options:
  --target-dir DIR  Directory to write files into (default: ~/.cac)
  --force           Overwrite existing files
  --print-only      Print detected values without writing files
  -h, --help        Show this help

The generated files are plain text and can be edited manually later.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir)
            [[ $# -ge 2 ]] || { echo "error: --target-dir requires a value" >&2; exit 1; }
            TARGET_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --print-only)
            PRINT_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "error: this script currently supports macOS only" >&2
    exit 1
}

hw="$(system_profiler SPHardwareDataType 2>/dev/null || true)"
[[ -n "$hw" ]] || {
    echo "error: failed to read hardware info from system_profiler" >&2
    exit 1
}

model="$(printf '%s\n' "$hw" | sed -n 's/^ *Model Identifier: //p' | head -1)"
serial="$(printf '%s\n' "$hw" | sed -n 's/^ *Serial Number (system): //p' | head -1)"
manufacturer="Apple Inc."

[[ -n "$model" ]] || {
    echo "error: failed to detect Model Identifier" >&2
    exit 1
}
[[ -n "$serial" ]] || {
    echo "error: failed to detect Serial Number (system)" >&2
    exit 1
}

printf 'model=%s\nserial=%s\nmanufacturer=%s\n' "$model" "$serial" "$manufacturer"

if [[ "$PRINT_ONLY" == "true" ]]; then
    exit 0
fi

mkdir -p "$TARGET_DIR"

write_value() {
    local path="$1"
    local value="$2"

    if [[ -f "$path" && "$FORCE" != "true" ]]; then
        printf 'skip: %s already exists\n' "$path"
        return 0
    fi

    printf '%s\n' "$value" > "$path"
    printf 'wrote: %s\n' "$path"
}

write_value "$TARGET_DIR/host_model" "$model"
write_value "$TARGET_DIR/host_serial_number" "$serial"
write_value "$TARGET_DIR/host_manufacturer" "$manufacturer"

cat <<EOF

Done.
The files in ${TARGET_DIR} are plain text and can be edited manually:
  ${TARGET_DIR}/host_model
  ${TARGET_DIR}/host_serial_number
  ${TARGET_DIR}/host_manufacturer
EOF
