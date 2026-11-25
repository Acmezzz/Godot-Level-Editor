# 开发用 Node 验证工具

这里的 Node 服务器用于维护编辑器源码。Windows 编辑器 EXE 自己运行的内容制作 MCP 见 [EDITOR_MCP.md](../docs/EDITOR_MCP.md)。

把本项目的日常验证操作封装成结构化 MCP 工具，供 ZCode 会话直接调用。零依赖 Node stdio server（JSON-RPC 按行分帧），不装任何包。

## 工具

| 工具 | 作用 | 返回 |
| --- | --- | --- |
| `check_scripts` | 批量 headless `--check-only` parse 检查 | `{ok, results:[{path, ok, errors[]}]}` |
| `run_tests` | 跑 `tests/run_tests.gd` 全套 | `{passed, failed, failures[], output_tail}` |
| `warn_scan` | 跑 `tools/warn_scan.gd` 静态警告扫描 | `{files, fails, lines}` |
| `headless_script` | 跑任意 `res://` .gd 脚本（screenshot/migrate 等） | `{exit, output_tail}` |

## 注册

`C:/Users/admin/.zcode/cli/config.json` → `mcp.servers.bird-editor`（stdio，`node mcp/server.mjs --project <项目路径>`）。已注册（2026-11-21），新会话生效。

## 自测

`node mcp/_drive.mjs`：真实 stdio 握手 + 四工具全调用（当前全绿 ≈1.8s）。
