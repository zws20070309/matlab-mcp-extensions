# 0.16.0 升级适配报告（2026-11-04 / 修订 2026-11-05）

## 结论

官方 0.16.0 与本仓库扩展层**接口零破坏**：37 个工具的 `tools/list` 定义（5 个内置 + 32 个扩展）
与 0.15.0 **逐字节一致**（27 项白名单比对，0 差异）。风险因此全部落在**行为**而非接口上。

但在 0.16.0 更严格的参数校验与更严格的错误语义下，实测暴露出 1 个 P1 与 1 个诊断缺陷；
随后的完整工具链实测又抓出 5 处独立缺陷。全部已修复并逐条回归。

| 项 | 0.15.0 | 0.16.0 | 结论 |
|---|---|---|---|
| 工具数 | 37 | 37 | 一致 |
| 工具定义 | — | — | 逐字节相同（27 项白名单比对 0 差异） |
| 参数类型校验 | 宽松 | 严格（`number` 拒绝字符串） | **触发 P1** |
| `oneOf` / 联合类型 | 未测 | 拒绝（要求 `type` 字段） | 措辞明确，可绕开 |
| 错误语义 | 内置工具错误返回文本 | 返回 `isError` + `identifier` | 更严格，扩展层无依赖破坏 |
| 默认显示模式 | `desktop` | `nodesktop` | **图形类工具需显式指定** |

## 修复清单

### P1 `enable_checkpoint.periodSeconds` 在 0.16.0 下彻底不可用

0.15.0 把 `periodSeconds` 声明为 `"type":"number"`，但客户端一律把参数以字符串发送。
0.15.0 校验宽松，`mcp_num("60")` 能解析；0.16.0 校验严格：

```
invalid params: validating /properties/periodSeconds: type: 10 has type "string", want "number"
```

即**开启检查点、修改周期、关闭检查点三个动作全部失败**（实测两次调用分别在 4 ms / 1 ms 内被拒）。

修复：schema 改为 `"type":"string"`（与其余 32 个工具的约定一致），函数内继续用 `mcp_num` 解析；
同时修掉"非法值静默回退 60 s"的旧行为——现在 `"abc"` / `""` 明确报 `enable_checkpoint:badPeriod`，
不再假成功。

> 注：先尝试过 `oneOf` 联合类型，0.16.0 直接拒绝（`property "v" must have a 'type' field`），
> 且该错误会让**整个服务器启动失败**。此路不通，已放弃。

### P2 图形工具在 `nodesktop` 模式下的误导性报错

0.16.0 默认 `--matlab-display-mode=nodesktop`。实测该模式下**图形不跨调用存活**
（调用 1 建图 `children=1`，调用 2 读回 `children=0`，`gcf` 返回失效句柄），于是
`list_ui` / `capture_app` / `capture_figure` 全部报 `noFigures`，而真实原因是显示模式。

修复：新增 `mcp_no_figures_error.m`，用 `usejava('desktop')` 区分三种"没有图"的情形
（nodesktop / 桌面模式下确实没图 / 连到了别的会话），错误消息直接给出两条出路
（改用 `desktop` 模式，或在同一次调用内 `exportgraphics`）。

## 第二轮：全工具真实链路实测抓出的 5 处缺陷（2026-11-05）

37 个工具逐一在真实 MCP 链路上调用（含数值核对与方法级验证），发现并修复：

### 1. `check_code_tree` 把真 error 报成"没有 error"（P1）

原实现按消息关键词猜严重级别，注释里甚至写明"checkcode 结构体没有 severity 字段"。
该结论只对默认调用形式成立：`checkcode(f,'-severity')` 会返回 `severity` 字段。

实测刻度（R2025a）：**0=info，1=warning，3=error**（真实解析错误得 3）。

后果：一个缺 `end` 的文件（`ENDCT2`，MATLAB 判 error、文件根本无法运行）被归为 warning，
整棵树输出 `VERDICT: no errors`。在"跑测试前先全树 lint"这种门禁用法里，这是**假绿**。

修复：改用 `checkcode(f,'-severity')`，按官方刻度分级；若某版本不支持该选项，降级为关键词分级
并在输出里打印 `NOTE` 说明依据已降级。实测同一棵树从 `error=0` 变为
`error=2 - fix before running anything`。

### 2. `get_variable` 的 `json` 模式遇混合类型表直接失败（P1）

`table2array` 对混合类型表抛异常：

```
MATLAB:table:ExtractDataIncompatibleTypeError: 无法串联表变量 'n' 和 's'，因为这两个变量的类型为 double 和 cell
```

`json` 模式是唯一能完整输出 struct / table / timeseries 的模式（`csv` 拒绝它们，
`summary` / `head` 会把 agent 真正需要的值抹平），所以这条路径不可用等于丢掉一项能力。

修复：逐列序列化，每列按自己的类型选 JSON 形式（`datetime` / `categorical` / 对象列转文本，
复数拆 real/imag）。编写过程中自查又踩到一个坑并当场修掉：`isreal()` 只看虚部存储标志，
对 cell 数组返回 **true**，于是 `real({'a'})` 被调用并抛
`mustBeNumericCharOrLogical`——复数分支现在额外要求 `isnumeric`。

### 3. `file_op` 的 `startLine` 文档里有、代码里没有（P2）

文档从一开始就列出 `startLine`，实现里从未读取：传了就**静默忽略**，返回的是文件尾部而非指定行。
在"读大日志的某一段"这种用法下，静默返回错内容比报错更危险。

修复：实现该选项（按行首定位、窗口保留前 N 行、超界时报真实行数而非回落到文件开头）。
实现过程中自查又抓到两个自己的 bug：`fseek` 的 bof 偏移是 0-based 而行索引是 1-based（差一），
以及"丢弃半行"的旧逻辑会把 `startLine` 指定的那一行整行吞掉。

### 4. `gpu_mc` 的样本数参数 `n` 被静默忽略（P1）

schema 文档写 `{"n":...}`，代码只读 `totalN`；传 `{"n":1000}` 实际按默认
**10,000,000** 跑——不容易被发现，因为输出看起来完全正常，只是慢了一万倍。

修复：`n` 作为 `totalN` 的别名在填默认值**之前**生效；schema 描述同步为
`{"totalN": samples (alias "n"), ...}`。实测 `{"n":1000}` → `N=1000`，
旧写法 `{"totalN":50000}` 仍兼容。

### 5. `steps_run` 传 `logDir:""` 触发告警且日志丢失（P2）

空字符串被当成"目录名为空"传给 `mkdir`，MATLAB 打警告且该次运行日志无处落盘。

修复：空串视为"用默认目录"。

## 实测覆盖（0.16.0）

- 全工具暴力测试 35 用例（nodesktop）：32/35 通过，3 个为预期失败（错误路径用例）
- desktop 模式全量回归 35 用例：同结果
- 图形跨调用在 desktop 模式下验证通过（截图目视审查）
- 代理回归 26 + 17 + 15 = **58 项全绿**
- 代理 `--probe` 对真实 0.16.0 exe：37 工具、修补 1 处、幂等、exit 0
- 37 个工具在真实客户端链路上逐一调用，含数值核对：
  `sl_sim` 的 `max=0.958851` = 2·sin(0.5)（Gain=2 生效）、`gpu_mc` 均值 0.3332 ≈ 1/3（u² 期望）、
  扫描三例 param² 分别为 1/4/9、真实运行中 `cancel_job` 成功落 `cancelled`
- 扩展层 60 个 `.m` 全树 lint：**0 error**

## GitHub issues 实测结论

| Issue | 0.16.0 状态 | 证据 |
|---|---|---|
| #123 不完整语法卡死整会话 | **已修** | `for k=1:3, disp(k)` 现返回缺 `END` 错误，后续调用正常（AFTER_WEDGE_999 / RECOVERED_111） |
| #68 `dbstop if error` 锁死 | **未复现** | 触发错误后 `dbquit` 被拒但会话仍可用（AFTER_DBSTOP_222） |
| #88 `--initialize-matlab-on-startup=false` 被忽略 | **已修** | 9 个服务器实例日志均 `InitializeMATLABOnStartup:false`，启动后 MATLAB 进程数 = 0 |
| #126 取消后服务器重启杀会话 | **仍存在（官方 exe 行为）** | 实测 watchdog `Adding process to kill` → 重启后 MARKER_LOST；对照实验证明代理延迟退出救不了 |
| #63 让 agent 看到图 | 本仓库**已覆盖** | `capture_app` / `capture_figure` / `list_ui`（desktop 模式实测出图） |
| #23 命令历史 | 本仓库**已覆盖** | `extensions/logs/tools.log` 审计流水 + `evaluate_logged` 全量日志 |

### #126 为什么不在本仓库"修"

根因在官方 exe 的 watchdog：服务器退出 → 杀掉它拉起的 MATLAB。代理层能延迟自己的退出，
但 watchdog 挂在服务器 close 上，与代理无关；客户端强杀整棵进程树时更无解。

**实测反证**：实现过"代理延迟退出"并在 A/B 对照中测量——延迟退出反而让 MATLAB 存活时间
更短（+9 s vs +21 s），因为 `stdin.end()` 加速了服务器侧的收尾，watchdog 反而更早触发。
该改动已**诚实回滚**，不作为修复交付。

可落地的缓解是**避免触发重启**：代理的引擎占用守卫让"超时 → 重启"这条链在第一步就得到秒回
诊断而不是盲等。要根治需官方改 watchdog 或提供 `--keep-matlab-on-exit` 开关。

## 升级操作

1. 备份：`backup/v015/…_v0.15.0.exe`（0.16.0 验证通过后已删除）
2. 现役：`matlab-mcp-server-windows-x64.exe` = 0.16.0
   （SHA-256 `7c70fdc69e7e7d4762732fede64f348b18ecbc89c3de705f9dde89a86d1883ea`）
3. 命令行参数无需改动：`--matlab-root` / `--initialize-matlab-on-startup=false` /
   `--disable-telemetry=true` / 两个 `--extension-file` 全部兼容
4. `--matlab-display-mode` 默认由 `desktop` 切到 `nodesktop`，**图形类工具需要显式
   `--matlab-display-mode=desktop`**
5. 若使用代理，把 `MC_WEDGE_AFTER_MS` 设为"客户端调用超时略低"的值
   （60 s 超时用默认 55 s，120 s 超时用 110 s）
