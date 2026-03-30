#!/usr/bin/env bash
# install.sh — cac installer
set -euo pipefail

REPO_BASE_URL="https://raw.githubusercontent.com/nmhjklnm/cac/master"
BIN_DIR="${HOME}/bin"
DIST_DIR="${HOME}/.cac-dist"
CAC_HOME="${HOME}/.cac"

INSTALL_MODE="auto"
AUTO_YES=false
SKIP_IDENTITY=false
FORCE_IDENTITY=false
NO_BUILD=false

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

usage() {
    cat <<'EOF'
Usage: bash install.sh [options]

Install cac either from the current local repo (preferred when this script is
run inside a synced/customized repo) or from GitHub raw files.

Options:
  --local           Force install from the current local repo
  --remote          Force install from GitHub raw files
  --yes             Non-interactive install; accept defaults
  --skip-identity   Skip macOS host identity scan/review
  --force-identity  Overwrite existing macOS host identity files
  --no-build        Skip running build.sh in local mode
  -h, --help        Show this help

Local install layout:
  ~/.cac-dist/cac
  ~/.cac-dist/relay.js
  ~/.cac-dist/fingerprint-hook.js
  ~/bin/cac -> ~/.cac-dist/cac

The macOS identity step writes plain-text files under ~/.cac/ and they remain
editable after install:
  ~/.cac/host_model
  ~/.cac/host_serial_number
  ~/.cac/host_manufacturer
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local) INSTALL_MODE="local"; shift ;;
            --remote) INSTALL_MODE="remote"; shift ;;
            --yes) AUTO_YES=true; shift ;;
            --skip-identity) SKIP_IDENTITY=true; shift ;;
            --force-identity) FORCE_IDENTITY=true; shift ;;
            --no-build) NO_BUILD=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                red "error: unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

is_local_repo() {
    [[ -f "${SCRIPT_DIR}/build.sh" ]] &&
    [[ -f "${SCRIPT_DIR}/cac" ]] &&
    [[ -f "${SCRIPT_DIR}/relay.js" ]] &&
    [[ -f "${SCRIPT_DIR}/fingerprint-hook.js" ]] &&
    [[ -d "${SCRIPT_DIR}/src" ]]
}

resolve_install_mode() {
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        if is_local_repo; then
            INSTALL_MODE="local"
        else
            INSTALL_MODE="remote"
        fi
    fi

    if [[ "$INSTALL_MODE" == "local" ]] && ! is_local_repo; then
        red "error: --local was requested but this script is not running inside a valid cac repo"
        exit 1
    fi
}

check_existing_install() {
    if command -v cac >/dev/null 2>&1; then
        local local_cac
        local_cac="$(command -v cac)"
        if [[ "$local_cac" == *"node_modules"* ]] || [[ -f "$(dirname "$local_cac" 2>/dev/null)/package.json" ]]; then
            red "⚠ detected an npm-installed claude-cac; do not mix npm and bash installs"
            printf '  uninstall first:\n    npm uninstall -g claude-cac\n'
            exit 1
        fi
    fi
}

run_local_build() {
    [[ "$INSTALL_MODE" == "local" ]] || return 0
    [[ "$NO_BUILD" == "true" ]] && return 0

    printf 'Building local cac ... '
    (
        cd "$SCRIPT_DIR"
        bash build.sh >/dev/null
    )
    green "✓"
}

download_remote_asset() {
    local name="$1"
    curl -fsSL "${REPO_BASE_URL}/${name}" -o "${DIST_DIR}/${name}"
}

install_assets() {
    mkdir -p "$DIST_DIR"

    if [[ "$INSTALL_MODE" == "local" ]]; then
        printf 'Installing from local repo ... '
        cp "${SCRIPT_DIR}/cac" "${DIST_DIR}/cac"
        cp "${SCRIPT_DIR}/relay.js" "${DIST_DIR}/relay.js"
        cp "${SCRIPT_DIR}/fingerprint-hook.js" "${DIST_DIR}/fingerprint-hook.js"
        if [[ -f "${SCRIPT_DIR}/cac-dns-guard.js" ]]; then
            cp "${SCRIPT_DIR}/cac-dns-guard.js" "${DIST_DIR}/cac-dns-guard.js"
        fi
        green "✓"
    else
        printf 'Downloading cac assets ... '
        download_remote_asset "cac"
        download_remote_asset "relay.js"
        download_remote_asset "fingerprint-hook.js"
        download_remote_asset "cac-dns-guard.js"
        green "✓"
    fi

    chmod +x "${DIST_DIR}/cac"
}

link_entrypoint() {
    mkdir -p "$BIN_DIR"
    ln -sfn "${DIST_DIR}/cac" "${BIN_DIR}/cac"
}

detect_rc_file() {
    if [[ -f "${HOME}/.zshrc" ]]; then
        printf '%s\n' "${HOME}/.zshrc"
    elif [[ -f "${HOME}/.bashrc" ]]; then
        printf '%s\n' "${HOME}/.bashrc"
    elif [[ -f "${HOME}/.bash_profile" ]]; then
        printf '%s\n' "${HOME}/.bash_profile"
    else
        printf '%s\n' ""
    fi
}

write_identity_files() {
    mkdir -p "$CAC_HOME"
    printf '%s\n' "$IDENTITY_MODEL" > "${CAC_HOME}/host_model"
    printf '%s\n' "$IDENTITY_SERIAL" > "${CAC_HOME}/host_serial_number"
    printf '%s\n' "$IDENTITY_MANUFACTURER" > "${CAC_HOME}/host_manufacturer"
}

load_existing_identity() {
    EXISTING_MODEL=""
    EXISTING_SERIAL=""
    EXISTING_MANUFACTURER=""
    if [[ -f "${CAC_HOME}/host_model" ]]; then
        EXISTING_MODEL="$(tr -d '\r\n' < "${CAC_HOME}/host_model")"
    fi
    if [[ -f "${CAC_HOME}/host_serial_number" ]]; then
        EXISTING_SERIAL="$(tr -d '\r\n' < "${CAC_HOME}/host_serial_number")"
    fi
    if [[ -f "${CAC_HOME}/host_manufacturer" ]]; then
        EXISTING_MANUFACTURER="$(tr -d '\r\n' < "${CAC_HOME}/host_manufacturer")"
    fi
}

show_identity_values() {
    printf '  model: %s\n' "${IDENTITY_MODEL:-—}"
    printf '  serial: %s\n' "${IDENTITY_SERIAL:-—}"
    printf '  manufacturer: %s\n' "${IDENTITY_MANUFACTURER:-—}"
}

prompt_identity_field() {
    local field_key="$1"
    local field_label="$2"
    local detected_value="$3"
    local existing_value="$4"
    local current_value="$5"
    local choice prompt default_choice entered_value next_value

    while true; do
        printf '\n%s:\n' "$field_label"
        printf '  detected: %s\n' "${detected_value:-—}"
        printf '  existing: %s\n' "${existing_value:-—}"
        printf '  current:  %s\n' "${current_value:-—}"

        if [[ -n "$existing_value" ]]; then
            prompt='Choose [k]eep existing, [d]etected, or [e]nter custom'
            default_choice="k"
        else
            prompt='Choose [d]etected or [e]nter custom'
            default_choice="d"
        fi

        printf '%s [%s]: ' "$prompt" "$default_choice"
        read -r choice
        case "${choice:-$default_choice}" in
            k|K)
                if [[ -n "$existing_value" ]]; then
                    next_value="$existing_value"
                    break
                fi
                yellow "No existing value is available for ${field_label}."
                ;;
            d|D)
                next_value="$detected_value"
                break
                ;;
            e|E)
                printf 'Enter %s: ' "$field_label"
                read -r entered_value
                next_value="$entered_value"
                break
                ;;
            *)
                yellow "Please choose a valid option."
                ;;
        esac
    done

    case "$field_key" in
        model) IDENTITY_MODEL="$next_value" ;;
        serial) IDENTITY_SERIAL="$next_value" ;;
        manufacturer) IDENTITY_MANUFACTURER="$next_value" ;;
    esac
}

review_identity_fields() {
    while true; do
        prompt_identity_field "model" "Model" "$DETECTED_MODEL" "$EXISTING_MODEL" "${IDENTITY_MODEL:-$DETECTED_MODEL}"
        prompt_identity_field "serial" "Serial Number" "$DETECTED_SERIAL" "$EXISTING_SERIAL" "${IDENTITY_SERIAL:-$DETECTED_SERIAL}"
        prompt_identity_field "manufacturer" "Manufacturer" "$DETECTED_MANUFACTURER" "$EXISTING_MANUFACTURER" "${IDENTITY_MANUFACTURER:-$DETECTED_MANUFACTURER}"

        printf '\nFinal macOS host identity values:\n'
        show_identity_values
        printf '\nWrite these values to ~/.cac? [Y/n]: '
        read -r answer
        case "${answer:-y}" in
            y|Y|yes|YES|"")
                write_identity_files
                return 0
                ;;
            n|N|no|NO)
                yellow "Restarting field-by-field review."
                ;;
            *)
                yellow "Please answer y or n."
                ;;
        esac
    done
}

scan_macos_identity() {
    local hw
    hw="$(system_profiler SPHardwareDataType 2>/dev/null || true)"
    [[ -n "$hw" ]] || {
        yellow "Skipping macOS host identity scan: system_profiler returned no hardware data"
        return 1
    }

    DETECTED_MODEL="$(printf '%s\n' "$hw" | sed -n 's/^ *Model Identifier: //p' | head -1)"
    DETECTED_SERIAL="$(printf '%s\n' "$hw" | sed -n 's/^ *Serial Number (system): //p' | head -1)"
    DETECTED_MANUFACTURER="Apple Inc."

    [[ -n "$DETECTED_MODEL" && -n "$DETECTED_SERIAL" ]] || {
        yellow "Skipping macOS host identity scan: failed to parse model/serial"
        return 1
    }
    return 0
}

setup_identity() {
    [[ "$SKIP_IDENTITY" == "true" ]] && return 0
    [[ "$(uname -s)" == "Darwin" ]] || return 0

    mkdir -p "$CAC_HOME"
    load_existing_identity

    if ! scan_macos_identity; then
        return 0
    fi

    IDENTITY_MODEL="$DETECTED_MODEL"
    IDENTITY_SERIAL="$DETECTED_SERIAL"
    IDENTITY_MANUFACTURER="$DETECTED_MANUFACTURER"

    printf 'Detected macOS host identity:\n'
    show_identity_values
    printf '\n'

    if [[ "$AUTO_YES" == "true" ]]; then
        if [[ "$FORCE_IDENTITY" == "true" || -z "$EXISTING_MODEL$EXISTING_SERIAL$EXISTING_MANUFACTURER" ]]; then
            write_identity_files
            green "✓ wrote macOS host identity files"
        else
            yellow "Keeping existing macOS host identity files (use --force-identity to overwrite)"
        fi
        return 0
    fi

    if [[ "$FORCE_IDENTITY" == "true" ]]; then
        write_identity_files
        green "✓ wrote detected macOS host identity files"
        return 0
    fi

    if [[ -n "$EXISTING_MODEL$EXISTING_SERIAL$EXISTING_MANUFACTURER" ]]; then
        printf 'Existing ~/.cac host identity files found:\n'
        printf '  model: %s\n' "${EXISTING_MODEL:-—}"
        printf '  serial: %s\n' "${EXISTING_SERIAL:-—}"
        printf '  manufacturer: %s\n' "${EXISTING_MANUFACTURER:-—}"
        printf '\n'
    fi

    review_identity_fields
    green "✓ saved macOS host identity files"
    return 0
}

initialize_cac() {
    export PATH="${BIN_DIR}:$PATH"
    "${BIN_DIR}/cac" env ls >/dev/null
}

print_completion() {
    local rc_file
    rc_file="$(detect_rc_file)"

    echo
    green "✓ 安装完成"
    echo
    printf '安装模式: %s\n' "$INSTALL_MODE"
    printf '入口: %s\n' "${BIN_DIR}/cac"
    printf '运行时文件: %s\n' "$DIST_DIR"
    echo

    if [[ -n "$rc_file" ]]; then
        echo "执行以下命令使 PATH 立即生效（或重开终端）："
        echo "  source $rc_file"
        echo
    fi

    if [[ "$(uname -s)" == "Darwin" ]] && [[ "$SKIP_IDENTITY" != "true" ]]; then
        echo "如需手动调整 macOS ioreg shim 使用的值，可直接编辑："
        echo "  ${CAC_HOME}/host_model"
        echo "  ${CAC_HOME}/host_serial_number"
        echo "  ${CAC_HOME}/host_manufacturer"
        echo
    fi

    echo "然后创建第一个环境："
    echo "  cac env create <名字> -p <host:port:user:pass>"
}

main() {
    parse_args "$@"

    echo "=== cac — Claude Code Cloak 安装 ==="
    echo

    resolve_install_mode
    check_existing_install
    run_local_build
    setup_identity
    install_assets
    link_entrypoint
    initialize_cac
    print_completion
}

main "$@"
