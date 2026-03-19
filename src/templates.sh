# ── templates: 写入 wrapper 和 ioreg shim ──────────────────────

_write_wrapper() {
    mkdir -p "$CAC_DIR/bin"
    cat > "$CAC_DIR/bin/claude" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

CAC_DIR="$HOME/.cac"
ENVS_DIR="$CAC_DIR/envs"

# cacstop 状态：直接透传
if [[ -f "$CAC_DIR/stopped" ]]; then
    _real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude" 2>/dev/null || true)
    [[ -x "$_real" ]] && exec "$_real" "$@"
    echo "[cac] 错误：找不到真实 claude，运行 'cac setup'" >&2; exit 1
fi

# 读取当前环境
if [[ ! -f "$CAC_DIR/current" ]]; then
    echo "[cac] 错误：未激活任何环境，运行 'cac <name>'" >&2; exit 1
fi
_name=$(tr -d '[:space:]' < "$CAC_DIR/current")
_env_dir="$ENVS_DIR/$_name"
[[ -d "$_env_dir" ]] || { echo "[cac] 错误：环境 '$_name' 不存在" >&2; exit 1; }

PROXY=$(tr -d '[:space:]' < "$_env_dir/proxy")

# pre-flight：代理连通性
_hp=$(echo "$PROXY" | sed 's|.*@||' | sed 's|.*://||')
_host=$(echo "$_hp" | cut -d: -f1)
_port=$(echo "$_hp" | cut -d: -f2)
if ! (echo >/dev/tcp/"$_host"/"$_port") 2>/dev/null; then
    echo "[cac] 错误：[$_name] 代理 $_hp 不通，拒绝启动。" >&2
    echo "[cac] 提示：运行 'cac check' 排查，或 'cacstop' 临时停用" >&2
    exit 1
fi

# 注入 statsig stable_id
if [[ -f "$_env_dir/stable_id" ]]; then
    _sid=$(tr -d '[:space:]' < "$_env_dir/stable_id")
    for _f in "$HOME/.claude/statsig"/statsig.stable_id.*; do
        [[ -f "$_f" ]] && printf '"%s"' "$_sid" > "$_f"
    done
fi

# 注入环境变量
export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" ALL_PROXY="$PROXY"
export NO_PROXY="localhost,127.0.0.1"
export PATH="$CAC_DIR/shim-bin:$PATH"
# OTel 遥测默认 off，显式置空防止外层误开
export CLAUDE_CODE_ENABLE_TELEMETRY=
# 清除第三方 API 配置，强制走 OAuth 官方端点
unset ANTHROPIC_BASE_URL
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_API_KEY

[[ -f "$_env_dir/tz" ]]   && export TZ=$(tr -d '[:space:]' < "$_env_dir/tz")
[[ -f "$_env_dir/lang" ]] && export LANG=$(tr -d '[:space:]' < "$_env_dir/lang")

# 执行真实 claude
_real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude")
[[ -x "$_real" ]] || { echo "[cac] 错误：$_real 不可执行，运行 'cac setup'" >&2; exit 1; }
exec "$_real" "$@"
WRAPPER_EOF
    chmod +x "$CAC_DIR/bin/claude"
}

_write_ioreg_shim() {
    mkdir -p "$CAC_DIR/shim-bin"
    cat > "$CAC_DIR/shim-bin/ioreg" << 'IOREG_EOF'
#!/usr/bin/env bash
CAC_DIR="$HOME/.cac"

# 非目标调用：透传真实 ioreg
if ! echo "$*" | grep -q "IOPlatformExpertDevice"; then
    _real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
            command -v ioreg 2>/dev/null || true)
    [[ -n "$_real" ]] && exec "$_real" "$@"
    exit 0
fi

# 读取当前环境的 UUID
_uuid_file="$CAC_DIR/envs/$(tr -d '[:space:]' < "$CAC_DIR/current" 2>/dev/null)/uuid"
if [[ ! -f "$_uuid_file" ]]; then
    _real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
            command -v ioreg 2>/dev/null || true)
    [[ -n "$_real" ]] && exec "$_real" "$@"
    exit 0
fi
FAKE_UUID=$(tr -d '[:space:]' < "$_uuid_file")

cat <<EOF
+-o Root  <class IORegistryEntry, id 0x100000100, retain 11>
  +-o J314sAP  <class IOPlatformExpertDevice, id 0x100000101, registered, matched, active, busy 0 (0 ms), retain 28>
    {
      "IOPlatformUUID" = "$FAKE_UUID"
      "IOPlatformSerialNumber" = "C02FAKE000001"
      "manufacturer" = "Apple Inc."
      "model" = "Mac14,5"
    }
EOF
IOREG_EOF
    chmod +x "$CAC_DIR/shim-bin/ioreg"
}
