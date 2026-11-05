# MATLAB MCP schema 修复代理

## 这是什么

一个 stdio JSON-RPC 代理，夹在 **MCP 客户端的 stdio 子进程调用** 与 **`matlab-mcp-server-windows-x64.exe`** 之间，
在转发 `tools/list` 响应时，给「声明为 object 但缺 `properties` 键」的 schema 补上 `properties: {}`。

## 为什么需要它

### 症状

`/team`（或任何工具数变化后）整轮请求失败，provider 返回：

```
Tool 25 function has invalid 'parameters' schema: None is not of type 'object'
On schema['properties']: None
```

**注意这是整轮失败**，不是「某个工具不能用」——所以看起来像随机故障。

### 根因（完整因果链，全部实测取证）

1. **`matlab-mcp-server` 的内置工具 `detect_matlab_toolboxes` 的 schema 有缺陷**：

   ```json
   {"type":"object","additionalProperties":false}     ← 没有 properties 键
   ```

   （直连 exe 的 `tools/list` 实测确认；它不在任何 `--extension-file` 里，是 exe 硬编码的。）

2. **provider 侧的 schema 校验拒绝「缺 properties 键」的 object schema**。错误原文点名
   `On schema['properties']: None`，即 provider 把「缺键」看成 `None`。

   > ⚠️ **诚实标注**：我**没能定位**「缺键」究竟在客户端的哪一段代码里变成 provider 眼中的
   > `None`。我曾归因于某家 SDK 的 `mcpTool` helper
   > （`properties: tool.inputSchema.properties ?? null`），但**那条归因是错的**：
   > - 它属于某一家 provider 的转换路径，而报错会话用的是另一家 provider；
   > - 逐字复刻 `convertTools` 验证：`schema.properties ?? {}` 在 `undefined` 时给 `{}`，不可能产出 `null`；
   > - 也追了另一家 provider 风格的 `toFunctionTools → getJsonSchemaToolParameters(tool, true)
   >   → makeStrictJsonSchema → makeJsonSchemaNodeStrict`：对「缺 properties」既不抛错也不写 null；
   > - 报错文本来自 provider 的 AJV，**不在客户端安装包内**（搜 `"None is not of type"` 0 命中）；
   > - 我扫了 6 个会话的 `request/header`：**`parameters.properties === null` 出现 0 次**，
   >   只出现「缺 properties 键」。
   >
   > ⇒ null 更可能产生于**发给 provider 之后**的链路（或网关侧归一化），不在客户端落盘的那一层。
   > **这不影响修复有效性**（我修的是已实测确认的上游异常），但若下游还有第二处会产 null 的地方，
   > 本代理覆盖不到。

3. **provider 拒绝后整轮请求失败**（不是「某个工具不能用」）。

4. **工具总数一变（例如 `/team` 多挂 4 个 `ops_*` 工具），索引就漂移** ⇒ 该缺陷时好时坏，看起来像随机故障。
   实测：报错会话 84 个工具，`0-based index 25` 正是 `mcp__matlab__detect_matlab_toolboxes`。

### 为什么不能从源头修

| 方案 | 结果 |
|---|---|
| 改服务器源码重编 | ❌ 仓库 `matlab-mcp-extensions` **只托管 extensions/**（.m + .json），没有 exe 源码 |
| 二进制打补丁 | ❌ exe 是 **Go 编译**（`go:buildid`）；`additionalProperties` 全文件仅 1 处且是 Go 运行时类型元数据，`"properties":{}` 0 处 ⇒ 无字面量可改 |
| 扩展 JSON 覆盖 | ❌ 实测被拒：`conflicts with a built-in tool. Choose a different name.` |

## 怎么用

```console
# 以代理方式运行（客户端配置里就是这么用的）
node mcp-schema-fix-proxy.mjs -- <真实服务器命令> [参数...]

# 真实链路自检：启动服务器、握手、报告修复前后的缺陷数
node mcp-schema-fix-proxy.mjs --probe -- <真实服务器命令> [参数...]

# 帮助
node mcp-schema-fix-proxy.mjs --help
```

在客户端的 MCP 服务器配置里，把 `command` 指向 `node.exe` 的绝对路径，`args` 写成
`[代理脚本, '--', 原exe, ...原参数]`。仓库根目录的 README 给出了完整 JSON 示例。

**推荐再配一个环境变量**：`MC_WEDGE_AFTER_MS` = 客户端单次调用超时略低的值。该阈值表示
"已越过客户端超时点，可判定为卡死"。客户端 60 s 超时用默认 55 s；120 s 超时用 110 s。

## 安全性

代理**只做一件事**：给缺 `properties` 的 object schema 补空对象。

- JSON Schema 里 `{"type":"object"}` 与 `{"type":"object","properties":{}}` **语义完全等价**；
- **只增不改**：不删字段、不改类型、不动 `required`、不动任何工具的调用行为；
- **未修改的帧逐字节原样透传**（含 CRLF）；
- 对不含该缺陷的服务器是**恒等变换** ⇒ 可以安全地长期挂着。

实测对照（37 个工具）：

```
inputSchema 逐字节相同的工具：36 / 37
被改动的工具：1 个（只有 detect_matlab_toolboxes）
  改前: {"type":"object","additionalProperties":false}
  改后: {"type":"object","additionalProperties":false,"properties":{}}
```

## 测试

```console
node proxy.test.mjs                  # 纯逻辑单元测试（26 项）
node proxy-backpressure.test.mjs     # 背压/丢帧/退出竞态回归（17 项）
node proxy-wedgeguard.test.mjs       # 引擎占用守卫：单元 + 真实代理进程集成（15 项）
```

## 第三层功能：引擎占用守卫（2026-11-03 追加）

**事故**（逐条实测取证）：一个 >60s 的前台调用（600-DPI
exportgraphics）被客户端约 60s 超时抛弃后，MATLAB 引擎继续执行它；引擎
串行，之后所有调用——包括「提交即返回」的 eval_async——排队 60s 后同样超时，
表现为「MATLAB MCP 完全无响应」，实测持续 ~12 分钟，agent 每次重试都白付 60s。

**守卫**：client→server 的 `tools/call` 逐帧检查。上一个调用在途超过
55s（`MC_WEDGE_AFTER_MS`，默认越过客户端 60s 超时点 = 卡死信号）时，新调用
**不再转发**（转发也必超时），立刻回一个 `isError` 的工具结果：占用时长、
起始时间、CPU 探测命令（区分「在干活要等」与「已僵死要重启」）、恢复路径。
被拒绝的调用不进在途台账；占用方完成（应答到达）后自动放行后续调用。

**台账** `extensions/logs/proxy_calls.log`（2 MiB 轮转）：每个转发的
tools/call 一行 `CALL`；>10s（`MC_SLOW_CALL_MS`）的完成调用一行 `SLOW`；
被守卫拒绝的一行 `REFUSED`。卡死事故不再需要从会话记录反推。

**开关与阈值**（环境变量）：`MC_WEDGE_GUARD=0` 整体关闭（恢复零解析透传）；
`MC_WEDGE_AFTER_MS` / `MC_WEDGE_STALE_MS` / `MC_SLOW_CALL_MS` 调阈值。
超过 `MC_WEDGE_STALE_MS`（默认 30 分钟）无应答的条目按僵尸自动清除，守卫
不会因为对端吞掉一条应答而永久误判。

**安全性**：转发的帧保持逐字节原样；解析失败的帧原样转发；`ping` 与通知帧
不追踪不拒绝。守卫只拒绝「转发出去也必然 60s 超时」的排队调用——顺序调用
流（上一条返回才发下一条）永远不会触发。

## 回滚

把 profile 的 `cordis.patch.yml` 换回备份，或把 `mcp-matlab` 的 `command`/`args` 改回原样：

```
command: <REPO_ROOT>\matlab-mcp-server-windows-x64.exe
args: [ "--matlab-root=<MATLABROOT>", "--initialize-matlab-on-startup=false",
        "--disable-telemetry=true", "--extension-file=...\mcp-jobs.json",
        "--extension-file=...\mcp-qa-tools.json" ]
```

回滚方式：把客户端配置里该 MCP 服务器的 `command` / `args` 改回直连 exe 的形式（改动前请自行备份该配置文件）。

## 已修掉的自身缺陷（开发过程中自查发现，均有回归测试）

| 级别 | 缺陷 | 修法 |
|---|---|---|
| P0 | **背压丢帧**：`framer.push()` 已把帧取出，遇背压 `break` 掉的帧永久丢失（MCP 一次发多帧时客户端侧握手卡死） | 新增 `OutputPump`：帧先入队，按序送达，一帧不丢 |
| P1 | **退出竞态·第一版修错**：只设 `process.exitCode` 不调 `process.exit()`，而 MCP 会话 stdin 长开 ⇒ 事件循环不空 ⇒ **代理永不退出** | `finalize()`：`stdin.destroy()` → `stdout.end(cb)` → cb 里 `process.exit()`；`close` 触发收尾，`exit` 只记码 + 2 秒兜底 |
| P1 | **退出竞态·原版**：`exit` 里立刻 `process.exit()` 会截断 `child.stdout` 尚未派发的缓冲 | 收尾挂 `child.on('close')`（保证 stdio 全关） |
| P1 | **`once('drain')` 卡死**：drain 后再次背压时已无监听器 ⇒ 队列无人续写 | 改**持久** drain 监听 + 幂等 `gate()` |
| P1 | **路径含 `#`/`%` 时静默失效**：`new URL(\`file://${argv[1]}\`)` 把 `#` 当 fragment、`%` 当 percent-encoding ⇒ `invokedDirectly` 为 false ⇒ `main()` 不执行、进程静默 exit 0 | 改用 `pathToFileURL(process.argv[1]).href`（独立审查发现；已用 9 种路径实测） |
| P2 | **`push` 遇 EPIPE 抛异常**：调用点在 `child.stdout.on('data')` 里，抛出会变成未捕获异常打挂代理 | `pump()` 内 `try/catch`，置 `broken` 并清空队列 |

### 独立审查提出、当前**未修**的 P2（不影响放行）

| 缺陷 | 真实可达性（审查员实测） | 建议 |
|---|---|---|
| `fixObjectSchemas` 递归无深度上限，深嵌套 `items` 链（约 depth ≥ 2500）触发 `RangeError` 打死代理 | **不可达** —— 该服务器 37 个工具最大嵌套深度 = **3** | 加深度上限或 `uncaughtException` 兜底 |
| `child.stdin` 无 `'error'` 监听（子进程死后写入会 EPIPE） | 审查员构造 3 种场景**均未触发**（代理都先退出） | 补一行 `child.stdin.on('error', () => {})` |
| `isUsableProperties` 会把 `Map`/`Date` 当合法 properties | 不可达（`JSON.parse` 产不出这些） | 无需处理 |
| `inputSchema: true`（布尔 schema）被替换为等价空对象 | 不可达（MCP 要求 inputSchema 是对象） | 无需处理 |


## 第二层功能：内置工具描述增补（2026-10-11/12 追加）

exe 硬编码的内置工具 description 无法从 extensions 侧修改。代理在 `fixToolsListResult` 里对
6 个内置工具（evaluate_matlab_code / evaluate_logged / run_matlab_file / run_matlab_test_file /
eval_async / list_jobs）的 description **只增不改**地追加两类实测语义（幂等：已含标记不重复追加）：

1. **TIMEOUT SEMANTICS** —— 客户端 ~60s 掐断调用，但 MATLAB 引擎**继续执行**被掐断的任务，
   其后所有调用排队到超时（队头阻塞）。实测：75s pause 在 61.4s 被掐、引擎残留 ~30s；
   90s 测试套件被掐后紧随的轻调用等了 31.8s。>45s 的活走 eval_async+job_status 或 suite_run 分片。
2. **CONTINUATION-MODE TRAP** —— 残缺语法（for/if/while/switch/try 缺 `end`）使桌面 MATLAB
   命令窗口进入续行模式，其后**一切**工具调用返回空文本且无错误、无磁盘副作用；
   恢复法：向 evaluate_matlab_code 单独发缺失的关键字（通常就是 `end`），缓冲一次性回放、引擎复活。
   实测 A/B 复现 2/2、恢复 2/2；已向上游报告：matlab/matlab-mcp-server#123。

验证：`node proxy.test.mjs` 26/26、`node proxy-backpressure.test.mjs` 17/17、
`--probe` 全链路 37 工具 + 帧级 JSON 解析确认 3/3 TRAP_DOC。
