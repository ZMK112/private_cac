# cac 真实验证指南

旧版文档中的 `cac setup`、`cac add`、`cac relay on/off` 等命令路径已经不再适合作为当前基线。

请改用以下入口：

## 1. 本地自动验证

```bash
bash scripts/validate.sh
```

这个脚本会自动完成：

- `build.sh` 构建
- JS hook 语法检查
- 隔离 `HOME` 下的 CLI 冒烟
- 本地 Docker bridge 模式校验
- `cac docker create/start/status/check/stop`
- 子容器 Docker wrapper 校验
- `cac docker port` 转发校验
- fail-closed 网络校验

更多说明见：

- `TESTING.md`
- `docs/guides/validation.mdx`
- `docs/zh/guides/validation.mdx`

## 2. 真实 Claude / 真实代理人工验证

自动脚本之外，仍建议补跑以下人工验证：

1. 真实上游代理下执行 `cac docker start`
2. 执行 `cac docker check`
3. 进入容器执行真实 `claude` 登录与交互
4. 验证代理停止后容器 fail-closed，不回退宿主直连
5. 在远程 Linux 主机补跑 `macvlan` 模式

## 3. 建议记录项

每次真实环境验证建议记录：

- 提交哈希
- 代理类型与出口区域
- `docker/.env` 关键字段
- `cac docker check` 输出
- fail-closed 验证结果
- 子容器 bind mount / proxy 注入结果
