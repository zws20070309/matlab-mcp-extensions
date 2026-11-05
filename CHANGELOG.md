# 变更记录

本仓库是对官方 `matlab-mcp-server` 的扩展层，按轮次记录"实测发现 → 修复 → 回归"。
每条都能在 `extensions/docs/` 或代理回归测试里找到对应证据。

版本对应关系：**扩展层第 N 轮** 与官方 exe 版本解耦，官方基线见每轮标题。

---

## 第 5 轮 — 全工具真实链路实测（2026-11-05，官方基线 v0.16.0）

37 个工具（5 内置 + 32 扩展）在真实 MCP 客户端链路上逐一调用，含数值核对与方法级验证。

### 修复

| 级别 | 缺陷 | 修法 |
|---|---|---|
| P1 | `check_code_tree` 按消息关键词猜严重级别，缺 `end` 的**真 error 被算成 warning**，整树输出 `VERDICT: no errors` | 改用 `checkcode(f,'-severity')`（实测刻度 0=info / 1=warning / 3=error）；无该选项的版本降级为关键词分级并打印 `NOTE` |
| P1 | `get_variable` 的 `json` 模式遇混合类型表/时间表直接失败（`table2array` 拒绝 double + cell） | 逐列序列化，每列按自身类型选 JSON 形式；复数分支额外要求 `isnumeric`（`isreal` 对 cell 返回 true） |
| P1 | `gpu_mc` 的 schema 写 `n`、代码只读 `totalN`，`{"n":1000}` 按默认 1e7 跑且无提示 | `n` 作为 `totalN` 别名在填默认值前生效；schema 描述同步 |
| P2 | `file_op` 的 `startLine` 文档里有、代码里没有，传了静默返回文件尾部 | 实现（行首定位 / 窗口保留前 N 行 / 超界报真实行数）；顺带修掉 0-based 偏移差一与行首被吞两个自查 bug |
| P2 | `steps_run` 传 `logDir:""` 触发 `mkdir` 告警且本次日志不落盘 | 空串视为"用默认目录" |

### 回归

- 代理三套件 26 + 17 + 15 = **58/58**
- `--probe` 真实 exe：37 工具、修补 1 处、幂等、exit 0
- 扩展层 60 个 `.m` 全树 lint：**0 error**

---

## 第 4 轮 — 升级官方 0.16.0（2026-11-04，官方基线 v0.16.0）

`tools/list` 定义与 0.15.0 **逐字节一致**（27 项白名单比对 0 差异），风险全在行为侧。

### 修复

| 级别 | 缺陷 | 修法 |
|---|---|---|
| P1 | `enable_checkpoint.periodSeconds` 声明为 `number`，而客户端一律发字符串；0.16.0 严格校验 ⇒ **开/改/关三个动作全部被拒**（4 ms 内失败） | schema 改 `string`（与其余 32 工具一致），函数内 `mcp_num` 解析；非法值不再静默回退 60 s，改报 `enable_checkpoint:badPeriod` |
| P2 | 0.16.0 默认 `nodesktop`，图形不跨调用存活，三个图工具只报 `noFigures` 掩盖真实原因 | 新增 `mcp_no_figures_error.m`：按 `usejava('desktop')` 区分三种情形，给出两条具体补救路径 |

### 上游 issue 实测

#123 已修 · #68 未复现 · #88 已修 · #126 仍存在（官方 watchdog 行为，代理延迟退出经 A/B 对照证明无效，已回滚）
· #63 / #23 本仓库已覆盖。详见 [UPGRADE-0.16.0-REPORT.md](UPGRADE-0.16.0-REPORT.md)。

---

## 第 3 轮 — 队列阻塞根因与占用守卫（2026-11-03，官方基线 v0.15.0）

### 根因（实测证据链）

客户端对每次工具调用超时约 60 s。一次 >60 s 的前台调用（高 DPI `exportgraphics`）被客户端
超时抛弃后，**MATLAB 引擎继续执行它**；引擎串行，其后所有调用——包括"提交即返回"的
`eval_async`——排队到 60 s 后同样超时。表现为"MCP 完全无响应"，实测持续约 12 分钟。

### 修复

代理层新增**引擎占用守卫**：

- **秒回诊断**：上一调用在途超过 `MC_WEDGE_AFTER_MS`（越过客户端超时点）时，新调用不再转发
  （转发也必超时），立即返回带占用时长、CPU 探测命令（涨=在干活、平=已僵死）、恢复路径的结果
- **慢调用台账** `extensions/logs/proxy_calls.log`：`CALL` / `SLOW` / `REFUSED` 三类记录
- **僵尸清理**：超过 `MC_WEDGE_STALE_MS`（默认 30 分钟）无应答的条目自动清除
- **开关**：`MC_WEDGE_GUARD=0` 整体关闭，恢复零解析透传

### 回归

守卫 15/15（含真代理进程 × 假慢服务器集成）；旧套件 26/26 + 17/17 零破坏。

### 反证

"代理延迟退出以保住 MATLAB 会话"（对应上游 #126）经 A/B 对照**证伪**：延迟退出让
MATLAB 存活时间更短（+9 s vs +21 s），因为关闭 stdin 加速了服务器收尾，watchdog 更早触发。
该改动已回滚。

---

## 第 2 轮 — 扩展层缺陷集中修复（2026-10-28，官方基线 v0.15.0）

8 类缺陷，全部先复现再修：

- 扫描任务空槽导致崩溃（`submit_sweep` 参数数组含空项）
- `run_tests` 在"扫到 0 个用例"时仍报绿
- 目录树哈希用自造 FNV 冒充 SHA（MATLAB 整数运算**饱和**而非回绕，哈希失去意义）
- `sl_sim` 的 StopTime 覆盖失效
- `.bak` 文件被当作模型/函数加载
- `cancel_sweep` / `list_jobs` 在混合状态下误报
- `session_reset` 的作用域与文档不符
- `steps_run` 的 `sub` 步骤在计数不符时未拒绝

## 第 1 轮 — 基础层与许可收敛（2026-09-19 ～ 2026-10-12，官方基线 v0.14.0）

- 32 个扩展工具 + 2 个注册表 + 共享 helper 成型
- `mcp_hash_file`：int8 → Java byte[] 封送会把 0x80+ 字节损坏为 0x7F（改用 Java 原生 SHA-256）
- `get_variable`：整数精度丢失（int64 > 2^53 经 double 往返失真）、复数变量令整个 json 模式崩溃
- `env_report`：scope 契约与实现对齐
- schema 修复代理：补齐 `detect_matlab_toolboxes` 缺失的 `properties`；给 6 个内置工具描述
  追加实测的 TIMEOUT 语义与续行陷阱说明（只增不改、幂等）
- 许可：LICENSE 收敛为纯 MIT 正文，范围与排除项迁入 NOTICE；官方二进制另立声明
