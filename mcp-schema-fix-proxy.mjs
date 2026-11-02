#!/usr/bin/env node
/**
 * mcp-schema-fix-proxy.mjs —— MATLAB MCP 服务器的 schema 修复代理（stdio JSON-RPC）
 *
 * ── 为什么需要它（2026-10-10，用户 `/team` 报障的根因）────────────────────────
 * 报错原文（provider 侧）：
 *   Tool 25 function has invalid 'parameters' schema: None is not of type 'object'
 *   Failed validating 'type' in metaschema[...]['properties']['properties'] ...
 *   On schema['properties']: None
 *
 * 完整因果链（逐条实测取证；第 4 条的归因经过一次纠正，见下方「诚实标注」）：
 *   1. matlab-mcp-server 是 **Go 编译的预编译 exe**（二进制含 `go:buildid`），仓库
 *      `matlab-mcp-extensions` 只托管 extensions/（.m + .json），**没有服务器源码**，
 *      也没有可供二进制补丁的 schema 字面量（`additionalProperties` 全文件仅 1 处，
 *      且是 Go 运行时类型元数据；`"properties":{}` 0 处）⇒ 无法改源码或改二进制。
 *   2. 它内置工具 `detect_matlab_toolboxes` 的 inputSchema 是：
 *        {"type":"object","additionalProperties":false}      ← **没有 properties 键**
 *      （直连该 exe 的 tools/list 实测确认；它不在任何 --extension-file 里，
 *        是 exe 硬编码的内置工具）
 *   3. 扩展文件**不能**覆盖内置工具：实测报
 *        Custom tool name "detect_matlab_toolboxes" ... conflicts with a built-in tool.
 *        Choose a different name.
 *   4. provider 的 AJV metaschema 校验直接 400 ⇒ **整个会话的这一轮请求全废**
 *      （不是「这个工具不能用」，是整轮失败）。工具总数一变（例如 `/team` 多挂 4 个
 *      ops_* 工具）索引就漂移，所以它会时好时坏，看起来像随机故障。
 *      实测：报错会话 84 个工具，provider 报的 `Tool 25`（0-based）正是
 *      `mcp__matlab__detect_matlab_toolboxes`。
 *
 * ── 诚实标注：哪一条是实测事实，哪一条我没能定位 ──────────────────────────────
 * 已实测为真（可直接复现）：
 *   * 该工具的 inputSchema **确实缺 properties 键** —— 直连 exe 与 DSH 落盘的
 *     request/header 都能看到（我扫了 6 个会话日志：报错会话里 `缺 properties 键 = 1 个`，
 *     就是它；其余会话 0 个）。
 *   * 该缺陷会被 provider 的 schema 校验拒绝。provider 的错误原文点名
 *     `On schema['properties']: None`。
 *   * 补齐 `properties: {}` 之后，同一份 schema 不再触发该错误。
 *
 * **未能定位（不要当作结论引用）**：究竟是 DSH 的**哪一段代码**把「缺键」变成
 * provider 眼中的 `None`。我曾归因于 Anthropic SDK `mcpTool` helper 里的
 * `properties: tool.inputSchema.properties ?? null`，但**这条归因是错的**：
 *   * 它属于 Anthropic provider 路径，而报错会话用的是 GLM（`sn-glm-5-3`）；
 *   * 我逐字复刻 `convertTools` 验证过：`schema.properties ?? {}` 在 `undefined` 时给的是
 *     `{}`，**不可能产出 null**；`strict === true` 的合并支路（`{...parameters, ...legacy}`）
 *     里 legacy 在后，也只会覆盖成 `{}`。
 *   * 我也追了 GLM/OpenAI 风格的 `toFunctionTools` → `getJsonSchemaToolParameters(tool, true)`
 *     → `makeStrictJsonSchema` → `makeJsonSchemaNodeStrict`：它对「缺 properties」既不抛错
 *     也不写 null（只在 `properties !== undefined` 时才做类型校验）。
 *   * 该报错文本来自 provider 的 AJV，**不在 app.asar 内**（搜 `"None is not of type"`
 *     与 `"Failed validating"` 均 0 命中）。
 *   * 我扫过 6 个会话的 request/header：**`parameters.properties === null` 出现 0 次**，
 *     只出现「缺 properties 键」。⇒ null 更可能产生于**发给 provider 之后**的链路
 *     （或 GLM 网关侧的归一化），不在 DSH 落盘的这一层。
 *
 * **这对修复意味着什么**：本代理修的是**已实测确认的上游异常**（缺 properties 键），
 * 且修复后 provider 不再报错。但如果链路下游还有**第二处**会把 schema 变成 null 的地方，
 * 本代理覆盖不到 —— 遇到就再按同样方式定位与修复。
 *
 * ── 本代理做什么 ──────────────────────────────────────────────────────────────
 * 夹在 DSH 的 dsh-mcp-client 与 matlab exe 之间，做三件事：
 *   1. server→client：给「声明为 object 但缺 properties 键」的 schema 补上
 *      `properties: {}`；给少数内置工具的 description 追加超时语义说明。
 *   2. 引擎占用守卫（2026-11-03）：client→server 的 tools/call 逐帧检查，
 *      上一个调用在途超过 55s（客户端已超时、引擎仍在执行的被抛弃调用）时，
 *      新调用不转发、立刻回秒达的诊断结果，终结「每次重试白付 60s」的
 *      队头阻塞循环。MC_WEDGE_GUARD=0 可关闭；关闭后恢复零解析透传。
 *   3. 慢调用台账 extensions/logs/proxy_calls.log：>10s 的调用与被拒绝的
 *      调用各记一行，卡死事故不再需要从会话记录反推。
 * 其余一切字节原样透传。
 *
 * 为什么这是安全的：
 *   * JSON Schema 里 `{"type":"object"}` 与 `{"type":"object","properties":{}}`
 *     **语义完全等价**（properties 为空表示没有声明任何具名属性）；
 *   * 只增不改：不删字段、不改类型、不动 required、不动任何工具的调用行为；
 *   * 守卫只拒绝「转发出去也必然 60s 超时」的排队调用，且带秒回诊断；
 *   * 对不含该缺陷的服务器是**恒等变换**（本文件因此可以安全地长期挂着）。
 *
 * ── 用法 ─────────────────────────────────────────────────────────────────────
 *   node mcp-schema-fix-proxy.mjs -- <真实服务器命令> [参数...]
 *   node mcp-schema-fix-proxy.mjs --probe -- <真实服务器命令> [参数...]
 *   node mcp-schema-fix-proxy.mjs --help
 *
 * `--probe` 是**真实链路自检**：它会真的启动目标服务器、完成 initialize 握手、
 * 发 tools/list，然后报告「修复前发现几处缺陷、修复后还剩几处」。它不依赖
 * --help 之类的表面输出，所以能真正证明代理生效。
 *
 * ── 行为保证 ─────────────────────────────────────────────────────────────────
 *   * stdio 传输：换行分隔的 JSON-RPC（MCP 标准），不是 LSP 的 Content-Length 分帧；
 *   * client→server 方向**零解析**，字节原样转发（不引入任何解析风险）；
 *   * server→client 方向：只有能解析成 JSON 且是 tools/list 成功响应、且确实修到了
 *     东西的那一行才重新序列化；其余行按原始字节写出（含 \r\n 与空行）；
 *   * 子进程 stderr 原样透传到本进程 stderr（DSH 会收进 stderrLines 供排查）；
 *   * 退出码/信号传播：子进程怎么退，本代理怎么退；stdin 关闭则关掉子进程 stdin。
 */

import { spawn } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { mkdirSync, appendFileSync, statSync, renameSync } from 'node:fs'

/** 日志前缀。DSH 的 mcp-client 收集子进程 stderr 作为诊断线索。 */
const LOG_PREFIX = '[mcp-schema-fix]'

/**
 * 写一行诊断到 stderr。
 * @param {string} message - 诊断内容。
 * @returns {void}
 */
function log(message) {
  process.stderr.write(`${LOG_PREFIX} ${message}\n`)
}

const USAGE = `mcp-schema-fix-proxy —— 给 MCP 服务器补全 object schema 缺失的 properties

用法:
  node mcp-schema-fix-proxy.mjs -- <命令> [参数...]            以代理方式运行
  node mcp-schema-fix-proxy.mjs --probe -- <命令> [参数...]    真实链路自检（启动服务器并核对）
  node mcp-schema-fix-proxy.mjs --help

说明:
  -- 之后的第一个参数是要代理的真实服务器，其余是它的参数。
  代理只在 server→client 的 tools/list 响应里，给「type=object 但缺 properties」
  的 schema 补 properties:{}；JSON Schema 语义等价，不改变任何工具的调用行为。
`

/**
 * 把 argv 拆成「代理自己的开关」与「被代理的真实命令」。
 *
 * `--` 之前是本代理的开关，之后是被代理命令及其参数。没有 `--` 时报错而不是猜，
 * 因为猜错会把真实服务器参数当成代理开关，产出极难排查的故障。
 *
 * @param {string[]} argv - process.argv.slice(2)。
 * @returns {{probe: boolean, help: boolean, command: string|undefined, args: string[]}}
 *   解析结果；command 为 undefined 表示没有给出目标命令。
 */
export function parseArgv(argv) {
  const separator = argv.indexOf('--')
  const own = separator === -1 ? argv : argv.slice(0, separator)
  const rest = separator === -1 ? [] : argv.slice(separator + 1)
  return {
    probe: own.includes('--probe'),
    help: own.includes('--help') || own.includes('-h'),
    command: rest.length > 0 ? rest[0] : undefined,
    args: rest.slice(1),
  }
}

/** 可能承载子 schema 的 JSON Schema 关键字（用于递归时知道往哪走）。 */
const SCHEMA_MAP_KEYWORDS = Object.freeze([
  'properties',
  'patternProperties',
  '$defs',
  'definitions',
  'dependentSchemas',
])

/** 值是单个子 schema（或子 schema 数组）的关键字。 */
const SCHEMA_VALUE_KEYWORDS = Object.freeze([
  'items',
  'additionalProperties',
  'additionalItems',
  'contains',
  'propertyNames',
  'not',
  'if',
  'then',
  'else',
  'unevaluatedItems',
  'unevaluatedProperties',
])

/** 值是子 schema 数组的关键字。 */
const SCHEMA_ARRAY_KEYWORDS = Object.freeze([
  'allOf',
  'anyOf',
  'oneOf',
  'prefixItems',
])

/**
 * 判断一个 schema 节点是否声明为「对象」类型。
 *
 * `type` 可能是字符串，也可能是数组（`["object","null"]` 这种联合）。两者都要认，
 * 否则联合类型里的同一个缺陷会被漏掉。
 * @param {object} node - schema 节点。
 * @returns {boolean} 是否包含 object 类型。
 */
function declaresObject(node) {
  if (node.type === 'object') return true
  return Array.isArray(node.type) && node.type.includes('object')
}

/**
 * 判断 properties 是否已经是可用的对象映射。
 * @param {unknown} value - 待检查的值。
 * @returns {boolean} 是合法对象映射返回 true（空对象 {} 也算合法）。
 */
function isUsableProperties(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/**
 * 递归补全 schema 里所有「声明为 object 但缺 properties」的节点。
 *
 * 直接原地修改传入的 schema（调用方随后会序列化它）。语义等价性：JSON Schema 中
 * `{"type":"object"}` 与 `{"type":"object","properties":{}}` 的校验行为完全相同，
 * 因此这是纯粹的兼容性补丁，不会放宽也不会收紧任何约束。
 *
 * @param {unknown} node - 当前 schema 节点。
 * @param {string} at - 当前路径（用于诊断输出）。
 * @param {string[]} changed - 收集被修补的路径。
 * @param {string[]} warnings - 收集「可疑但不自动修」的发现。
 * @returns {void}
 */
// ── 内置工具描述增补（2026-10-11 队头阻塞事故后追加）────────────────────────
// 内置工具的 description 在 exe 里硬编码，无法从 extensions 侧修改。这里在
// tools/list 转发时对少数内置工具的 description 做 **只增不改** 的追加：把
// "~60s 客户端超时 + 超时后引擎仍占用" 的语义写进文档，防止代理再写出
// >60s 的前台调用（session-7ac4a2ae 因此丢了 23 次调用）。
// 幂等：已含标记的描述不重复追加；对其他服务器/工具零影响。
const DESCRIPTION_APPENDICES = {
  'evaluate_matlab_code': ' TIMEOUT SEMANTICS: the client times a call out at ~60s; the MATLAB engine KEEPS RUNNING an abandoned call afterwards and every other call queues behind it (head-of-line blocking). Keep foreground calls well under 45s; for longer work use eval_async+job_status, run_tests, or suite_run with shards/budgetSec. CONTINUATION-MODE TRAP: an incomplete statement (a for/if/while/switch/try block whose end is missing) puts the desktop MATLAB command window into continuation mode; every later tool call then returns EMPTY text while the engine buffers it (measured on v0.14.0, 2026-10-12). Recover by calling evaluate_matlab_code with just the missing keyword (usually end): the queued calls flush at once. Always terminate all blocks before submitting.',
  'evaluate_logged': ' TIMEOUT SEMANTICS: same ~60s client timeout as evaluate_matlab_code; the engine keeps running an abandoned call. Keep foreground calls well under 45s; use eval_async+job_status for longer work. CONTINUATION-MODE TRAP: an incomplete statement (a for/if/while/switch/try block whose end is missing) puts the desktop MATLAB command window into continuation mode; every later tool call then returns EMPTY text while the engine buffers it (measured on v0.14.0, 2026-10-12). Recover by calling evaluate_matlab_code with just the missing keyword (usually end): the queued calls flush at once. Always terminate all blocks before submitting.',
  'run_matlab_file': ' TIMEOUT SEMANTICS: the client times a call out at ~60s and the engine keeps running an abandoned script afterwards (head-of-line blocking for every other session). Scripts expected to exceed ~45s should be split or moved to eval_async+job_status. CONTINUATION-MODE TRAP: an incomplete statement (a for/if/while/switch/try block whose end is missing) puts the desktop MATLAB command window into continuation mode; every later tool call then returns EMPTY text while the engine buffers it (measured on v0.14.0, 2026-10-12). Recover by calling evaluate_matlab_code with just the missing keyword (usually end): the queued calls flush at once. Always terminate all blocks before submitting.',
  'run_matlab_test_file': ' TIMEOUT SEMANTICS: the client times a call out at ~60s and the engine keeps running the abandoned suite afterwards. For suites that take >45s prefer run_tests or suite_run with shards/budgetSec (resumable), or eval_async+job_status.',
  'eval_async': ' NOTE: this is the recommended way to run >45s work: submit returns immediately; poll with job_status; stop with cancel_job.',
  'list_jobs': ' NOTE: if this simple call times out, another call is occupying the shared engine; wait for it or check with session_info after a pause.',
};
const DESCRIPTION_MARK = 'TIMEOUT SEMANTICS';

// ── 引擎占用守卫（2026-11-03，session-7fa54c30 事故后追加）──────────────────
// 事故链（逐条实测取证，见仓库报告）：
//   1. DSH 客户端对 tools/call 的超时是 ~60s（会话日志精确复现 60/61/62s）。
//   2. 一个 >60s 的前台调用（实测：600-DPI exportgraphics）超时后被抛弃，
//      但 MATLAB 引擎继续执行它；引擎串行，之后所有调用——包括「提交即返回」
//      的 eval_async——都排队 60s 后超时，形成「MCP 完全无响应」的假象。
//   3. 实测该状态持续 ~12 分钟（04:12:35→04:24），期间 agent 每次重试都白付
//      60s，毫无诊断信息。
// 本守卫做的事：上一个 MATLAB 调用在途超过 MC_WEDGE_AFTER_MS（默认 55s，
// 已越过客户端超时点 = 卡死信号）时，新来的 tools/call 不再转发（转发也必
// 超时），而是立刻回一个 isError 的工具结果，内容带占用时长、CPU 探测命令
// 与恢复路径——把每轮 60s 的盲等变成一次即时诊断。转发出去的帧保持逐字节
// 原样；解析失败的帧原样转发（不引入解析风险）。环境变量 MC_WEDGE_GUARD=0
// 可整体关闭。
const WEDGE_GUARD = process.env.MC_WEDGE_GUARD !== '0'
const WEDGE_AFTER_MS_DEFAULT = 55_000
const WEDGE_STALE_MS_DEFAULT = 1_800_000
const SLOW_CALL_MS_DEFAULT = 10_000

function envInt(name, dflt) {
  const v = Number.parseInt(process.env[name] ?? '', 10)
  return Number.isFinite(v) && v > 0 ? v : dflt
}

/** 代理自身的行为台账：慢调用、被守卫拒绝的调用（2 MiB 轮转）。 */
const PROXY_LOG = join(dirname(fileURLToPath(import.meta.url)), 'extensions', 'logs', 'proxy_calls.log')

function proxyLog(line) {
  try {
    mkdirSync(dirname(PROXY_LOG), { recursive: true })
    let bytes = 0
    try { bytes = statSync(PROXY_LOG).size } catch { /* 首次写入 */ }
    if (bytes > 2_097_152) {
      try {
        renameSync(PROXY_LOG, `${PROXY_LOG}.1`)
      } catch { /* 轮转失败不碍事 */ }
    }
    appendFileSync(PROXY_LOG, `${line}\n`, 'utf8')
  } catch { /* 日志绝不破坏代理 */ }
}

/**
 * 在途调用台账：驱动引擎占用守卫与慢调用记录。
 *
 * begin/end 由代理的 stdin/stdout 两个方向分别调用；end 返回本次调用的
 * 耗时（找不到对应 begin 时返回 null，例如对端根本没发过的应答）。
 * blocker() 返回「在途已超过 wedgeAfterMs」的调用——那正是客户端已经
 * 超时放弃、引擎还在跑的被抛弃调用。超过 staleMs 的僵尸条目自动清除，
 * 保证对端吞掉一条应答时守卫不会永久误判。
 */
export class CallTracker {
  constructor({ wedgeAfterMs = envInt('MC_WEDGE_AFTER_MS', WEDGE_AFTER_MS_DEFAULT),
                staleMs = envInt('MC_WEDGE_STALE_MS', WEDGE_STALE_MS_DEFAULT) } = {}) {
    this.wedgeAfterMs = wedgeAfterMs
    this.staleMs = staleMs
    this.inFlight = new Map()
  }

  begin(id, name, now = Date.now()) {
    this.inFlight.set(String(id), { name: String(name ?? '(unknown)'), startedAt: now })
  }

  end(id, now = Date.now()) {
    const key = String(id)
    const rec = this.inFlight.get(key)
    if (!rec) return null
    this.inFlight.delete(key)
    return { name: rec.name, startedAt: rec.startedAt, durationMs: Math.max(0, now - rec.startedAt) }
  }

  /** 在途超过 wedgeAfterMs 的最老调用；僵尸条目（超过 staleMs）顺手清除。 */
  blocker(now = Date.now()) {
    let oldest = null
    for (const [id, rec] of this.inFlight) {
      const ageMs = now - rec.startedAt
      if (ageMs > this.staleMs) {
        this.inFlight.delete(id)
        continue
      }
      if (ageMs > this.wedgeAfterMs && (!oldest || rec.startedAt < oldest.startedAt)) {
        oldest = { id, name: rec.name, startedAt: rec.startedAt, ageMs }
      }
    }
    return oldest
  }

  get size() {
    return this.inFlight.size
  }
}

/**
 * 检查一条 client→server 帧：tools/call 且引擎已被占用时产出秒回的拒绝帧，
 * 否则原帧转发并登记在途。解析失败/通知帧一律原样转发。
 *
 * @param {Buffer} frame - 含结尾换行的原始帧。
 * @param {CallTracker} tracker
 * @param {number} [now]
 * @returns {{forward: true, tracked: {id: string, name: string}|null}
 *           |{forward: false, response: Buffer, meta: {called: string, blockerName: string, blockerAgeMs: number, refusedCount: number}}}
 */
export function inspectClientFrame(frame, tracker, now = Date.now()) {
  const text = frame.toString('utf8').trim()
  if (text.startsWith('{')) {
    let message
    try {
      message = JSON.parse(text)
    } catch {
      message = undefined
    }
    if (message !== undefined && message.method === 'tools/call'
        && message.id !== undefined && message.id !== null
        && message.params && typeof message.params === 'object') {
      const blocker = tracker.blocker(now)
      if (blocker) {
        tracker.refusedCount = (tracker.refusedCount ?? 0) + 1
        const response = Buffer.from(`${JSON.stringify({
          jsonrpc: '2.0',
          id: message.id,
          result: {
            content: [{ type: 'text', text: wedgeGuardText(message.params.name, blocker, tracker.refusedCount) }],
            isError: true,
          },
        })}\n`, 'utf8')
        return { forward: false, response, meta: { called: String(message.params.name ?? ''), blockerName: blocker.name, blockerAgeMs: blocker.ageMs, refusedCount: tracker.refusedCount } }
      }
      tracker.refusedCount = 0
      const name = typeof message.params.name === 'string' ? message.params.name : '(unknown)'
      tracker.begin(message.id, name, now)
      return { forward: true, tracked: { id: String(message.id), name } }
    }
  }
  return { forward: true, tracked: null }
}

/**
 * 观察一条 server→client 帧：若它是对在途调用的应答，记下耗时。
 * 只观察不改写——帧随后仍走 transformServerFrame，未修改的帧逐字节透传。
 */
export function observeServerFrame(frame, tracker, now = Date.now()) {
  const text = frame.toString('utf8').trim()
  if (!text.startsWith('{')) return null
  let message
  try {
    message = JSON.parse(text)
  } catch {
    return null
  }
  if (message === null || typeof message !== 'object') return null
  if (message.id === undefined || message.id === null) return null
  if (typeof message.result !== 'object' && typeof message.error !== 'object') return null
  const done = tracker.end(message.id, now)
  if (done && done.durationMs > envInt('MC_SLOW_CALL_MS', SLOW_CALL_MS_DEFAULT)) {
    proxyLog(`${new Date().toISOString()} SLOW ${done.durationMs}ms ${done.name}`)
    return done
  }
  return done
}

function wedgeGuardText(calledName, blocker, refusedCount) {
  const ageSec = Math.round(blocker.ageMs / 1000)
  const startedAt = new Date(blocker.startedAt).toISOString().replace('T', ' ').slice(0, 19)
  const head = refusedCount > 1
    ? `[引擎占用守卫] 第 ${refusedCount} 次拒绝排队 - 引擎仍被占用`
    : '[引擎占用守卫] 拒绝排队 - 这次调用转发了也只会在 60s 后超时'
  return [
    `${head}`,
    `MATLAB 引擎已被上一次调用 <${blocker.name}> 占用 ${ageSec}s（${startedAt} 发出，客户端早已超时，引擎仍在执行）。`,
    '引擎是串行的：现在转发 <' + String(calledName ?? '') + '> 只会排队到同一个引擎后面，60s 后同样超时',
    '（实测 session-7fa54c30：3 连超时、空耗 7 分钟）。',
    '处理：',
    '1) 占用方若是导出/仿真等长任务：等它完成即自行恢复，无需任何操作；',
    '2) 用 ops_bash 探测引擎是否还活着：',
    '   powershell -NoProfile -Command "Get-Process MATLAB | Select-Object Id,CPU,WS"',
    '   CPU 在涨 = 在干活（选 1 等待）；CPU 平 = 已僵死（选 3）；',
    '3) 已僵死：重启本 MCP 服务器（DSH 的 MCP 设置），或结束对应 MATLAB 进程由 exe 重建。',
    '根治：>45s 的工作改走 eval_async + job_status（提交立即返回，不占前台引擎）。',
    '本守卫可用环境变量 MC_WEDGE_GUARD=0 关闭。',
  ].join('\n')
}

function appendBuiltinDescriptions(tools, changed, warnings) {
  if (!Array.isArray(tools)) return
  for (const tool of tools) {
    if (!tool || typeof tool !== 'object') continue
    const name = tool.name
    const appendix = DESCRIPTION_APPENDICES[name]
    if (!appendix) continue
    if (typeof tool.description !== 'string') {
      tool.description = appendix
      changed.push(`tools/${name}.description（原缺失，已写入）`)
      continue
    }
    if (tool.description.endsWith(appendix) || tool.description.includes(DESCRIPTION_MARK)) continue // 幂等
    tool.description = tool.description + ' ' + appendix
    changed.push(`tools/${name}.description（追加 timeout 语义）`)
  }
}

export function fixObjectSchemas(node, at = '$', changed = [], warnings = []) {

  if (node === null || typeof node !== 'object') return

  if (Array.isArray(node)) {
    node.forEach((item, index) => fixObjectSchemas(item, `${at}[${index}]`, changed, warnings))
    return
  }

  if (declaresObject(node) && !isUsableProperties(node.properties)) {
    const before = node.properties
    node.properties = {}
    changed.push(`${at}.properties（原值：${before === undefined ? '缺失' : JSON.stringify(before) ?? String(before)}）`)
  }

  // 自查（不自动修）：required 里的名字若不在 properties 中，语义上可能是错的。
  // 不自动修的理由：additionalProperties 未设为 false 时，调用方**可以**传未声明的属性，
  // 所以「required 项不在 properties 里」不等于坏 schema —— 删掉它会放宽约束、改变行为。
  if (Array.isArray(node.required) && isUsableProperties(node.properties)) {
    for (const name of node.required) {
      if (typeof name === 'string' && !Object.prototype.hasOwnProperty.call(node.properties, name)) {
        warnings.push(`${at}.required 含未声明属性 ${JSON.stringify(name)}（additionalProperties 未禁止时仍可传，故不自动修改）`)
      }
    }
  }

  for (const key of SCHEMA_MAP_KEYWORDS) {
    const map = node[key]
    if (!isUsableProperties(map)) continue
    for (const [name, child] of Object.entries(map)) {
      fixObjectSchemas(child, `${at}.${key}.${name}`, changed, warnings)
    }
  }

  for (const key of SCHEMA_VALUE_KEYWORDS) {
    if (node[key] === undefined) continue
    if (typeof node[key] === 'boolean') continue // additionalProperties: true/false 是合法布尔形式
    fixObjectSchemas(node[key], `${at}.${key}`, changed, warnings)
  }

  for (const key of SCHEMA_ARRAY_KEYWORDS) {
    const list = node[key]
    if (!Array.isArray(list)) continue
    list.forEach((child, index) => fixObjectSchemas(child, `${at}.${key}[${index}]`, changed, warnings))
  }
}

/**
 * 检查一个工具的 inputSchema 是否合法；不合法则就地修复。
 *
 * 三种缺陷都处理：
 *   ① inputSchema 缺失 / 为 null  → 补 `{type:'object',properties:{}}`
 *   ② inputSchema 不是对象（例如字符串、数组）→ 替换为等价空对象 schema
 *   ③ inputSchema 是对象但缺 properties（**用户这次的真实病根**）→ 补 `properties:{}`
 *
 * @param {object} tool - MCP tools/list 里的一个工具定义。
 * @param {string[]} changed - 收集被修补的描述。
 * @param {string[]} warnings - 收集自查发现。
 * @returns {void}
 */
export function fixToolInputSchema(tool, changed, warnings) {
  if (tool === null || typeof tool !== 'object') return
  const name = typeof tool.name === 'string' && tool.name !== '' ? tool.name : '(未命名工具)'
  const schema = tool.inputSchema

  if (schema === undefined || schema === null) {
    tool.inputSchema = { type: 'object', properties: {} }
    changed.push(`${name}: inputSchema ${schema === null ? '为 null' : '缺失'} → 已补 {type:object,properties:{}}`)
    return
  }
  if (typeof schema !== 'object' || Array.isArray(schema)) {
    tool.inputSchema = { type: 'object', properties: {} }
    changed.push(`${name}: inputSchema 不是对象（${Array.isArray(schema) ? 'array' : typeof schema}）→ 已替换为等价空对象 schema`)
    return
  }
  fixObjectSchemas(schema, name, changed, warnings)

  // 顶层没声明 type 时，DSH 会硬编码 type:'object'；这里只在「确实缺 type 且即将被当作
  // object 用」时补齐，让上游与下游对这份 schema 的理解一致。
  if (schema.type === undefined && isUsableProperties(schema.properties)) {
    schema.type = 'object'
    changed.push(`${name}: inputSchema 缺 type → 已补 'object'（DSH 侧本就按 object 处理）`)
  }
}

/**
 * 判断一条 server→client 消息是不是 `tools/list` 的成功响应。
 * @param {unknown} message - 已解析的 JSON-RPC 消息。
 * @returns {boolean} 是则返回 true。
 */
export function isToolsListResult(message) {
  return message !== null
    && typeof message === 'object'
    && !Array.isArray(message)
    && message.result !== null
    && typeof message.result === 'object'
    && !Array.isArray(message.result)
    && Array.isArray(message.result.tools)
}

/**
 * 对 tools/list 结果里的全部工具做 schema 修复。
 * @param {{tools: unknown[]}} result - tools/list 的 result。
 * @returns {{changed: string[], warnings: string[]}} 修补与自查结果。
 */
export function fixToolsListResult(result) {
  const changed = []
  const warnings = []
  appendBuiltinDescriptions(result.tools, changed, warnings)
  for (const tool of result.tools) fixToolInputSchema(tool, changed, warnings)
  return { changed, warnings }
}

/**
 * 换行分隔的 JSON-RPC 帧切分器。
 *
 * MCP 的 stdio 传输用换行分帧，单条 JSON 里的换行会被 JSON.stringify 转义成 `\n` 两个字符，
 * 所以真实换行字节只可能出现在帧之间 —— 按 `\n` 切分是安全的。
 *
 * 注意：服务端若用 CRLF（`\r\n`），切出的帧会以 `\r\n` 结尾；调用方（transformServerFrame）
 * 用 `trim()` 处理这种尾部，所以 CRLF 与 LF 都能正确解析。这里**不**把 `\r` 吃掉，
 * 原因是保持「未修改的帧逐字节原样透传」这条不变量。
 */
export class LineFramer {
  constructor() {
    /** @type {Buffer} 尚未成帧的尾巴。 */
    this.pending = Buffer.alloc(0)
  }

  /**
   * 送入一段字节，取出其中所有完整的帧。
   * @param {Buffer} chunk - 新到达的字节。
   * @returns {Buffer[]} 完整帧（每帧含结尾换行符）。
   */
  push(chunk) {
    this.pending = this.pending.length === 0 ? chunk : Buffer.concat([this.pending, chunk])
    const frames = []
    let index = this.pending.indexOf(0x0a)
    while (index !== -1) {
      frames.push(this.pending.subarray(0, index + 1))
      this.pending = this.pending.subarray(index + 1)
      index = this.pending.indexOf(0x0a)
    }
    return frames
  }

  /**
   * 取出残留的不完整尾巴（子进程退出时可能有半行）。
   * @returns {Buffer} 残留字节。
   */
  flush() {
    const rest = this.pending
    this.pending = Buffer.alloc(0)
    return rest
  }
}

/**
 * 有序帧队列 + 背压泵。
 *
 * ── 为什么需要它（2026-10-10 自查发现并修掉的 P0）──────────────────────────
 * 初版在 `child.stdout.on('data')` 里这样写：
 *     const frames = framer.push(chunk)
 *     for (const frame of frames) {
 *       if (paused) break          // ← 丢帧！
 *       ...write(frame)...
 *     }
 * `LineFramer.push()` 已经把帧**从内部缓冲取出**，所以 `break` 之后的帧既不在
 * framer.pending 里、也没被写出 —— **永久丢失**。真实场景：MCP 服务器一次发多帧
 * （initialize 响应 + notifications/* + 很大的 tools/list 一起到达），而 stdout 管道
 * 缓冲写满触发背压时，后面的帧就没了，DSH 侧表现为握手卡死或 tool 列表不完整。
 *
 * 本类保证：`push()` 进来的帧**一个都不会丢** —— 每帧要么已交给 write，要么留在队列里
 * 等 drain 后续写。Node 的语义是「write 返回 false = 数据已被接受，但缓冲区已满，
 * 请暂停上游」；因此遇 false 时该帧**仍然出队**（不重写，避免重复），只是把后续帧
 * 暂存下来、并暂停源流，等 drain 再继续。
 */
export class OutputPump {
  /**
   * @param {(chunk: Buffer) => boolean} write - 写出函数；返回 false 表示缓冲区满。
   */
  constructor(write) {
    /** @type {(chunk: Buffer) => boolean} */
    this.write = write
    /** @type {Buffer[]} 尚未写出的帧（严格保持顺序）。 */
    this.queue = []
    /**
     * 是否正在等 drain。
     *
     * 语义：为 true 时 `pump()` 不再尝试写出 —— 因为上游缓冲已满，继续 write 只会让
     * Node 的写队列无界增长（内存风险），正确做法是等 drain 事件把它清空。
     */
    this.awaitingDrain = false
    /**
     * 写出口是否已彻底不可用（stdout 关闭 / EPIPE）。
     * 一旦为 true，后续 push 直接丢弃而不抛错 —— 代理的收尾绝不能因为管道没了而崩。
     */
    this.broken = false
  }

  /**
   * 入队若干帧并尽量写出。
   *
   * write 抛异常（例如 stdout 已关闭的 EPIPE）时**不向上抛**：调用点在
   * `child.stdout.on('data')` 里，抛出去会变成未捕获异常、把代理整个打挂。
   * 此时放弃剩余帧并停止写出（管道没了，写什么都送不到）。
   * @param {Buffer[]} frames - 待写帧。
   * @returns {void}
   */
  push(frames) {
    if (this.broken) return
    for (const frame of frames) this.queue.push(frame)
    this.pump()
  }

  /**
   * 继续写出，直到队列空或遇到背压。
   * @param {boolean} [afterDrain] - true 表示这是 drain 之后的续写（清除等待标志）。
   * @returns {void}
   */
  pump(afterDrain = false) {
    if (afterDrain) this.awaitingDrain = false
    if (this.awaitingDrain || this.broken) return
    while (this.queue.length > 0) {
      const chunk = this.queue.shift()
      // Node 语义：write 返回 false 表示「数据已被接受，但请暂停发送」
      // ⇒ 该 chunk 已出队（不能重写，否则重复），只是不再继续写下一帧。
      let accepted
      try {
        accepted = this.write(chunk)
      } catch {
        // 管道已关：后续帧写不出去，标记 broken 并清空，避免反复抛错。
        this.broken = true
        this.queue.length = 0
        return
      }
      if (!accepted) {
        this.awaitingDrain = true
        return
      }
    }
  }

  /**
   * 一次性把队列排空（忽略背压信号）。
   *
   * 只用于进程即将退出的收尾：此时再等 drain 已无意义，能写多少写多少。
   * write 抛异常（管道已关的 EPIPE）时清空队列并正常返回 —— 收尾路径绝不能抛。
   * @returns {void}
   */
  drainNow() {
    this.awaitingDrain = false
    if (this.broken) return
    while (this.queue.length > 0) {
      const chunk = this.queue.shift()
      try {
        this.write(chunk)
      } catch {
        // 管道已关：剩下的写出去也没有接收方，直接放弃并结束。
        this.broken = true
        this.queue.length = 0
        return
      }
    }
  }

  /** 队列里还剩几帧未写（诊断用）。 @returns {number} */
  get pending() {
    return this.queue.length
  }

  /** 是否正等 drain（诊断用）。 @returns {boolean} */
  get stalled() {
    return this.awaitingDrain
  }
}

/**
 * 处理一条来自服务器（server→client）的帧：必要时修 schema，返回要写出的字节。
 *
 * 注意：本函数**只负责产出字节**，不负责写出与背压 —— 那是 OutputPump 的职责。
 * 这样切分是为了让「丢帧」不可能发生：帧一旦产出就被入队，队列负责送达。
 *
 * @param {Buffer} frame - 含结尾换行的原始帧。
 * @returns {Buffer} 要写出的字节（修复过的或原样的）。
 */
export function transformServerFrame(frame) {
  const text = frame.toString('utf8')
  const trimmed = text.trim()

  // 只处理看起来像 JSON 对象的帧，避免对通知/空行做任何解析尝试。
  // 注意用 trim()：这样服务端若用 CRLF（\r\n）分帧，末尾的 \r 也会被去掉，
  // JSON.parse 因此不会失败（原本这是 CRLF 场景下最容易踩的坑）。
  if (trimmed.startsWith('{')) {
    let message
    try {
      message = JSON.parse(trimmed)
    } catch {
      message = undefined // 解析不了就原样透传，绝不吞掉
    }
    if (message !== undefined && isToolsListResult(message)) {
      const { changed, warnings } = fixToolsListResult(message.result)
      for (const warning of warnings) log(`自查提示：${warning}`)
      if (changed.length > 0) {
        log(`已修复 ${changed.length} 处 schema 缺陷（JSON Schema 语义等价）：`)
        for (const item of changed) log(`  - ${item}`)
        // 统一用 \n 结尾重发（JSON-RPC over stdio 允许 \n 与 \r\n 两种；
        // 重发整行是必要的，因为 JSON 长度已变，不可能做原地替换）。
        return Buffer.from(`${JSON.stringify(message)}\n`, 'utf8')
      }
    }
  }

  return frame
}

/**
 * 以代理方式运行，永不返回（直到进程退出）。
 * @param {string} command - 真实服务器可执行文件。
 * @param {string[]} args - 它的参数。
 * @returns {void}
 */
function runProxy(command, args) {
  const child = spawn(command, args, {
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
    // 环境原样继承：服务器要靠 MW_MCP_SERVER_* 与 PATH 工作。
    env: process.env,
  })

  const framer = new LineFramer()
  /** client→server 方向的分帧器：守卫需要逐帧看 tools/call。 */
  const inFramer = new LineFramer()
  /** 引擎占用守卫的在途台账（工具调用 id → 名称/起始时间）。 */
  const tracker = new CallTracker()
  let exiting = false
  /** 收尾只做一次（close 与兜底定时器可能都触发）。 */
  let finalized = false
  /** 子进程退出码；close 与 exit 的先后顺序不保证，所以单独记着。 */
  let exitCode = 0

  // server → client：唯一需要检查方向。
  //
  // 用 OutputPump 而不是「就地循环 + break」：帧一旦从 framer 取出就必须有归宿，
  // 否则背压时 break 掉的帧会永久丢失（初版的 P0，详见 OutputPump 的注释）。
  const pump = new OutputPump((chunk) => process.stdout.write(chunk))
  let sourcePaused = false

  /**
   * 背压闸门：stdout 缓冲满则暂停上游，drain 后恢复并续写队列。
   *
   * 为什么用**持久** drain 监听而不是 `once`：
   *   `once` 只覆盖「本次背压」。若 drain 之后的续写又立刻触发背压（大 tools/list 很常见），
   *   那时已经没有 drain 监听器了 ⇒ 队列里剩下的帧永远没人续写 ⇒ **代理卡死**。
   *   持久监听 + 幂等的 `resumeIfDrained()` 覆盖任意次背压。
   */
  const gate = () => {
    if (pump.stalled) {
      if (!sourcePaused) {
        sourcePaused = true
        child.stdout.pause()
      }
      return
    }
    resumeIfDrained()
  }

  /** 队列已不 stalled 时恢复源流。 */
  const resumeIfDrained = () => {
    if (sourcePaused) {
      sourcePaused = false
      child.stdout.resume()
    }
  }

  // 持久 drain 监听：每次 stdout 排空都尝试续写队列，直到又一次背压为止。
  process.stdout.on('drain', () => {
    pump.pump(true)
    gate()
  })

  child.stdout.on('data', (chunk) => {
    const frames = framer.push(chunk)
    if (frames.length === 0) return
    // 应答观察（慢调用台账）在前，工具列表修复在后；两者都只产出字节，
    // 送达交给队列。
    for (const frame of frames) observeServerFrame(frame, tracker)
    pump.push(frames.map((frame) => transformServerFrame(frame)))
    gate()
  })

  child.stdout.on('end', () => {
    // flush 残留的半行：它是「没有换行结尾的最后一帧」，仍需变换后再写出。
    const rest = framer.flush()
    if (rest.length > 0) {
      pump.push([transformServerFrame(rest)])
      gate()
    }
  })

  // client → server：逐帧过守卫。被拒绝的帧不转发，改为立刻向客户端回一个
  // isError 的工具结果（经同一 OutputPump 写出，与 server→client 的写串行）；
  // 转发的帧保持逐字节原样。解析失败的帧原样转发。
  // 背压：子进程 stdin 缓冲满时暂停父进程 stdin，drain 后恢复。
  process.stdin.on('data', (chunk) => {
    const frames = inFramer.push(chunk)
    if (frames.length > 0) {
      const forwarded = []
      for (const frame of frames) {
        const verdict = WEDGE_GUARD ? inspectClientFrame(frame, tracker) : { forward: true, tracked: null }
        if (verdict.forward) {
          forwarded.push(frame)
          if (verdict.tracked) proxyLog(`${new Date().toISOString()} CALL ${verdict.tracked.name} id=${verdict.tracked.id}`)
        } else {
          proxyLog(`${new Date().toISOString()} REFUSED ${verdict.meta.called} blockedBy=${verdict.meta.blockerName} ageMs=${verdict.meta.blockerAgeMs} refusedCount=${verdict.meta.refusedCount}`)
          pump.push([verdict.response])
        }
      }
      if (forwarded.length > 0) {
        const chunkOut = Buffer.concat(forwarded)
        if (!child.stdin.write(chunkOut)) {
          process.stdin.pause()
          child.stdin.once('drain', () => process.stdin.resume())
        }
      }
    }
  })
  process.stdin.on('end', () => child.stdin.end())
  process.stdin.on('error', () => { /* 父进程消失：交给 child exit 处理 */ })

  // 子进程 stderr 原样透传（DSH 会收集它作为诊断线索）。
  child.stderr.on('data', (chunk) => process.stderr.write(chunk))

  child.on('error', (error) => {
    if (exiting) return
    exiting = true
    log(`无法启动目标服务器 ${JSON.stringify(command)}：${error.message}`)
    process.exit(127)
  })

  /**
   * 收尾：把「已收到但还没写出」的内容尽力送出，然后按子进程的退出码结束自己。
   *
   * ── 为什么不能直接在 'exit' 里 process.exit（2026-10-10 自查发现的 P1）──────
   * Node 的 `exit` 事件在**子进程结束时**就触发，此刻 `child.stdout` 里可能还有
   * 尚未派发成 'data' 事件的缓冲数据。若在 'exit' 里立刻 `process.exit()`，那批数据
   * **永久丢失**（表现为 DSH 侧 tools/list 不完整或握手半截）。
   * 正确做法：`close` 事件保证「进程已退出 **且 stdio 全部关闭**」，因此把最终收尾挂在
   * `close` 上；`exit` 只用来记住退出码。同时留一个短兜底定时器，避免子进程的孙进程
   * 一直占着 stdout 导致 close 迟到。
   * @returns {void}
   */
  const finalize = () => {
    if (finalized) return
    finalized = true
    const rest = framer.flush()
    if (rest.length > 0) pump.push([transformServerFrame(rest)])
    if (pump.pending > 0 && !process.stdout.writableEnded) pump.drainNow()

    // 收尾三件事，顺序不能错：
    //   ① 关掉 stdin：DSH 会话期间它会一直开着，不关则事件循环不会空；
    //   ② stdout.end(cb)：cb 表示**底层资源已把数据刷完**，此时才能安全退出；
    //   ③ 在 cb 里 process.exit(exitCode)：既保证最后一批字节送达，又保证进程真的结束。
    //
    // 为什么不能只用 `process.exitCode = ...` 然后不管：
    //   Node 只有在**事件循环为空**时才按 exitCode 自然退出。MCP 会话里 stdin 是长开的
    //   管道，仅设 exitCode 会让代理**永远活着**（子进程已死、代理不退），DSH 侧表现为
    //   「服务器还在但不再响应」——比直接退出更糟。所以必须显式 exit。
    try { process.stdin.destroy() } catch { /* 已关 */ }

    const done = () => {
      try { process.exit(exitCode) } catch { /* 极端情况下已退出 */ }
    }
    try {
      if (process.stdout.writableEnded) done()
      else process.stdout.end(done)
    } catch {
      done()
    }
  }

  child.on('close', () => finalize())

  child.on('exit', (code, signal) => {
    if (exiting) return
    exiting = true
    exitCode = signal !== null && code === null ? 1 : (code === null ? 1 : code)
    // 兜底：close 若因孙进程占用 stdout 而迟到，2 秒后仍收尾（unref 不阻塞正常退出）。
    const fallback = setTimeout(() => {
      log('子进程 close 事件迟到，按退出码收尾')
      finalize()
    }, 2000)
    fallback.unref?.()
  })

  // 父进程（DSH）要求退出时，先优雅关掉子进程再走。
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP', 'SIGBREAK']) {
    process.on(signal, () => {
      if (exiting) return
      exiting = true
      try {
        child.kill(signal)
      } catch { /* 子进程可能已退出 */ }
      process.exit(0)
    })
  }

  process.stdout.on('error', (error) => {
    if (error.code === 'EPIPE') process.exit(0) // 父进程关了管道：正常收场
  })
}

/**
 * `--probe`：真实链路自检。
 *
 * 真的启动目标服务器、完成 initialize 握手、发 tools/list，然后报告修复前后的缺陷数。
 * 这是唯一能证明「代理确实修好了 schema」的方式 —— 不依赖任何表面输出。
 *
 * @param {string} command - 真实服务器可执行文件。
 * @param {string[]} args - 它的参数。
 * @param {number} [timeoutMs] - 总超时。
 * @returns {Promise<number>} 退出码：0 = 修复后无缺陷；1 = 仍有缺陷或握手失败。
 */
function runProbe(command, args, timeoutMs = 90_000) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env: process.env })
    const framer = new LineFramer()
    /** @type {object|undefined} */
    let rawToolsResult
    const stderrTail = []
    let settled = false

    const finish = (code) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { child.kill() } catch { /* 已退出 */ }
      resolve(code)
    }

    const timer = setTimeout(() => {
      log('自检超时：服务器未在期限内给出 tools/list 响应')
      for (const line of stderrTail.slice(-10)) log(`  服务器 stderr: ${line}`)
      finish(1)
    }, timeoutMs)

    const send = (message) => {
      if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`)
    }

    child.on('error', (error) => {
      log(`无法启动目标服务器 ${JSON.stringify(command)}：${error.message}`)
      finish(1)
    })

    child.on('exit', (code) => {
      if (settled) return
      log(`服务器在自检完成前退出（code=${code}）`)
      for (const line of stderrTail.slice(-10)) log(`  服务器 stderr: ${line}`)
      finish(1)
    })

    child.stderr.on('data', (chunk) => {
      for (const line of chunk.toString('utf8').split('\n')) {
        if (line.trim() !== '') stderrTail.push(line.trim())
      }
      if (stderrTail.length > 40) stderrTail.splice(0, stderrTail.length - 40)
    })

    child.stdout.on('data', (chunk) => {
      for (const frame of framer.push(chunk)) {
        const text = frame.toString('utf8').trim()
        if (!text.startsWith('{')) continue
        let message
        try { message = JSON.parse(text) } catch { continue }
        if (isToolsListResult(message)) {
          rawToolsResult = message.result
          report(rawToolsResult)
          return
        }
      }
    })

    /**
     * 报告并给结论：先在**副本**上验证修复效果，避免污染原始数据。
     * @param {{tools: unknown[]}} result - 原始 tools/list 结果。
     * @returns {void}
     */
    const report = (result) => {
      const total = result.tools.length

      // 修复前：数一遍
      const before = []
      const beforeWarnings = []
      for (const tool of result.tools) {
        const name = tool?.name ?? '(未命名工具)'
        const schema = tool?.inputSchema
        if (schema === undefined || schema === null || typeof schema !== 'object' || Array.isArray(schema)) {
          before.push(`${name}: inputSchema 不是可用对象`)
        } else if (!isUsableProperties(schema.properties)) {
          before.push(`${name}: 缺 properties（原值 ${JSON.stringify(schema.properties) ?? 'undefined'}）`)
        }
        fixObjectSchemas(structuredClone ? structuredClone(schema) : schema, name, [], beforeWarnings)
      }

      // 修复后：在深拷贝上应用，再数一遍
      const clone = structuredClone(result)
      const changed = []
      const warnings = []
      for (const tool of clone.tools) fixToolInputSchema(tool, changed, warnings)
      const after = []
      for (const tool of clone.tools) {
        const name = tool?.name ?? '(未命名工具)'
        const schema = tool?.inputSchema
        if (schema === undefined || schema === null || typeof schema !== 'object' || Array.isArray(schema)) {
          after.push(`${name}: inputSchema 仍不是可用对象`)
        } else if (!isUsableProperties(schema.properties)) {
          after.push(`${name}: 仍缺 properties`)
        }
      }

      process.stdout.write(`工具总数：${total}\n`)
      process.stdout.write(`\n[修复前] 缺陷 ${before.length} 处\n`)
      for (const item of before) process.stdout.write(`  ✗ ${item}\n`)
      if (beforeWarnings.length > 0) {
        process.stdout.write(`\n[自查·不自动修] ${beforeWarnings.length} 条\n`)
        for (const item of beforeWarnings) process.stdout.write(`  ! ${item}\n`)
      }
      process.stdout.write(`\n[代理修补] ${changed.length} 处\n`)
      for (const item of changed) process.stdout.write(`  ✓ ${item}\n`)
      process.stdout.write(`\n[修复后] 剩余缺陷 ${after.length} 处\n`)
      for (const item of after) process.stdout.write(`  ✗ ${item}\n`)

      const ok = after.length === 0 && before.length > 0
      process.stdout.write(`\n结论：${after.length > 0
        ? '仍有缺陷，代理未覆盖该形状'
        : before.length === 0
          ? '该服务器本来就没有此缺陷（代理对其为恒等变换）'
          : `修复成功：${before.length} 处缺陷全部消除`}\n`)

      // 幂等性自证：对已修好的结果再修一次，应无新增改动。
      const again = []
      for (const tool of clone.tools) fixToolInputSchema(tool, again, [])
      process.stdout.write(`幂等性：再修一次产生 ${again.length} 处改动${again.length === 0 ? '（正确）' : '（异常，请报告）'}\n`)

      finish(ok && again.length === 0 ? 0 : 1)
    }

    // 握手时序：initialize → initialized 通知 → tools/list
    send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'mcp-schema-fix-proxy', version: '1.0.0' },
      },
    })
    setTimeout(() => send({ jsonrpc: '2.0', method: 'notifications/initialized' }), 800)
    setTimeout(() => send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }), 1200)
  })
}

/**
 * 入口。
 * @returns {Promise<void>} 完成时 resolve（仅 --probe / --help 会走到）。
 */
async function main() {
  const { probe, help, command, args } = parseArgv(process.argv.slice(2))

  if (help) {
    process.stdout.write(USAGE)
    return
  }
  if (command === undefined) {
    process.stderr.write(USAGE)
    process.stderr.write('\n错误：没有给出目标服务器。请用 `-- <命令> [参数...]` 指定。\n')
    process.exitCode = 2
    return
  }

  if (probe) {
    const code = await runProbe(command, args)
    process.exitCode = code
    return
  }

  runProxy(command, args)
}

// 仅在直接执行时进入 main；被 import 时（例如测试）不产生副作用。
//
// ⚠️ 必须用 pathToFileURL 而不是手拼字符串（2026-10-10 独立审查发现的 P1）：
//   旧写法 `new URL(\`file://${process.argv[1].replace(/\\/g, '/')}\`)` 对路径里的特殊字符
//   会静默判错 —— `#` 被当成 URL fragment、`%` 被当成 percent-encoding 解码，于是
//   `import.meta.url === ...` 为 false ⇒ **main() 根本不执行** ⇒ 进程 exit 0 且不打印任何
//   东西、不转发任何字节。这种「换了目录就静默失效、还不报错」的失效模式排查成本极高。
//   pathToFileURL 按 URL 规范正确转义，任何合法路径都能得到一致的比较结果。
const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(process.argv[1]).href

if (invokedDirectly) {
  main().catch((error) => {
    log(`未预期的失败：${error?.stack ?? error}`)
    process.exit(1)
  })
}