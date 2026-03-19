# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
cat <<EOF
$(_bold "cac") — Claude Anti-fingerprint Cloak

$(_bold "用法：")
  cac setup                         首次安装
  cac add <名字> <host:port:u:p>    添加新环境（需要 yes 确认）
  cac <名字>                        切换到指定环境
  cac ls                            列出所有环境
  cac check                         核查当前环境（代理 + 出口 IP）
  cac stop                          临时停用，claude 裸跑
  cac -c                            恢复停用

$(_bold "代理格式：")
  host:port:user:pass    带认证的 SOCKS5
  host:port              无认证的 SOCKS5

$(_bold "示例：")
  cac add us1 1.2.3.4:1080:username:password
  cac us1
  cac check
  cac stop

$(_bold "文件目录：")
  ~/.cac/bin/claude       wrapper（拦截所有 claude 调用）
  ~/.cac/shim-bin/ioreg   ioreg shim（返回独立 machine UUID）
  ~/.cac/current          当前激活的环境名
  ~/.cac/envs/<name>/     各环境：proxy / uuid / stable_id
EOF
}
