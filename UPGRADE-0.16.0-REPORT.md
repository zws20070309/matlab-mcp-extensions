# 0.16.0 升级适配报告（2026-11-04）

## 结论

官方 0.16.0 与本仓库扩展层**接口零破坏**：37 个工具的 tools/list 定义（含 5 个内置 +
32 个扩展）与 0.15.0 **逐字节一致**。但在更严格的参数校验下暴露了 1 个真 P1 与 1 个
诊断缺陷，均已修复并回归。

| 项 | 0.15.0 | 0.16.0 | 结论 |
|---|---|---|---|
| 工具数 | 37 | 37 | 一致 |
| 工具定义 | — | — | 逐字节相同（27 项白名单比对 0 差异） |
| 参数类型校验 | 宽松 | 严格（number 拒绝字符串） | **触发 P1** |
| oneOf/联合类型 | 未测 | 拒绝（require 'type'） | 措辞明确，可绕 |
| 错误语义 | 内置工具错误返回文本 | nodesktop 下返回 isError+identifier | 更严格，扩展层无依赖破坏 |

## 修复清单

### P1 `enable_checkpoint.periodSeconds` 在 0.16.0 下彻底不可用

0.15.0 把 `periodSeconds` 声明为 `"type":"number"`，但客户端（DSH/Claude）一律把
参数以字符串发送。0.15.0 的校验宽松，`mcp_num("60")` 能解析；0.16.0 的校验严格：

```
invalid params: validating /properties/periodSeconds: type: 10 has type "string", want "number"
```

即**开启检查点、修改周期、关闭检查点三个动作全部失败**（实测 2 次调用 4ms/1ms 即拒）。

修复：schema 改为 `"type":"string"`（与其余 32 个工具的约定一致），并在函数内用
`mcp_num` 解析；同时修掉「非法值静默回退 60s」的旧行为 —— 现在 `"abc"` / `""`
明确报 `enable_checkpoint:badPeriod`，不再假成功。

### P2 图形工具在 nodesktop 模式下的误导性报错

0.16.0 默认 `--matlab-display-mode=nodesktop`。实测该模式下**图形不跨调用存活**
（调用 1 建图 children=1，调用 2 children=0，gcf 返回失效句柄），于是
`list_ui` / `capture_app` / `capture_figure` 全部报 `noFigures`，而真实原因是模式。

修复：新增 `mcp_no_figures_error.m`，用 `usejava('desktop')` 区分三种「没有图」的情形
（nodesktop / 桌面模式确实没图 / 连到了别的会话），错误消息直接给出两条出路
（改 desktop 模式，或同一次调用内 exportgraphics）。

## 实测覆盖（0.16.0）

- 全工具暴力测试 35 用例（nodesktop）：32/35 通过，3 个为预期失败（错误路径用例）
- desktop 模式全量回归 35 用例：同结果
- 图形跨调用在 desktop 模式下验证通过（截图已目视审查）
- Node 代理回归 26 + 17 + 15 = 58 项全绿
- 代理 `--probe` 对真实 0.16.0 exe：37 工具、schema 修复 1 处、幂等、exit 0

## GitHub issues 实测结论

| Issue | 0.16.0 状态 | 证据 |
|---|---|---|
| #123 不完整语法卡死整会话 | **已修** | `for k=1:3, disp(k)` 现返回 `缺 END` 错误，后续调用正常（AFTER_WEDGE_999 / RECOVERED_111） |
| #68 dbstop if error 锁死 | **未复现** | 触发错误后 `dbquit` 被拒但会话仍可用（AFTER_DBSTOP_222） |
| #88 --initialize-matlab-on-startup=false 被忽略 | **已修** | 9 个服务器实例日志均 `InitializeMATLABOnStartup:false`，启动后 MATLAB 进程数 = 0 |
| #126 取消后服务器重启杀会话 | **仍存在（官方 exe 行为）** | 实测 watchdog `Adding process to kill` → 重启后 MARKER_LOST；对照实验证明代理延迟退出救不了（watchdog 在服务器 close 时杀子进程） |
| #63 让 agent 看到图 | 本仓库**已覆盖** | `capture_app`/`capture_figure`/`list_ui`（desktop 模式实测出图） |
| #23 命令历史 | 本仓库**已覆盖** | `extensions/logs/tools.log` 审计流水 + `evaluate_logged` 全量日志 |

### #126 为什么不在本仓库「修」

根因在官方 exe 的 watchdog：服务器退出 → 杀掉它拉起的 MATLAB。代理层能延迟自己的
退出，但 watchdog 挂在服务器 close 上，与代理无关；客户端 SIGKILL 整棵进程树时更无解。
可落地的缓解是**避免触发重启**：本仓库的引擎占用守卫（55s 快失败 + 诊断）已经让
「超时 → 重启」这条链在第一步就得到秒回诊断而不是盲等。要根治需官方改 watchdog 或
提供 `--keep-matlab-on-exit` 开关，已作为上游 issue 记录。

## 升级操作

1. 备份：`backup/v015/matlab-mcp-server-windows-x64_v0.15.0.exe`（0.15 验证通过后删除）
2. 现役：`matlab-mcp-server-windows-x64.exe` = 0.16.0（sha256 `7c70fdc6...`）
3. 命令行参数无需改动：`--matlab-root` / `--initialize-matlab-on-startup=false` /
   `--disable-telemetry=true` / 两个 `--extension-file` 全部兼容
4. `--matlab-display-mode` 默认由 `desktop` 切到 `nodesktop`，**图形类工具需要显式
   `--matlab-display-mode=desktop`**（本机 DSH 配置已是 desktop）
