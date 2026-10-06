# `/mcp reload` 之后的验收清单（3 项，每项一条调用 + 预期结果）

前置：`extensions\` 的磁盘状态已经过静态核查，reload 不会失败——
无 BOM、纯 LF、行尾换行已补回、顶层键 `["tools","signatures"]`、16+16 个工具名与**顺序**逐一相同、
每个工具的键序仍是 `["name","title","description","inputSchema"]`、两个文件 `JSON.parse` 通过。
详见 `MCP_v12_全工具实测与修复_20260929.md` §16.2。

reload 前若要保住 MATLAB 会话：`restore_checkpoint("")` 可恢复 56 个基变量
（快照 `checkpoint.mat`，2026-09-29 12:19）；**3 个 uifigure 恢复不了**，快照按设计跳过硬柄对象。

---

## 1. `file_op` 的 4 个动作应当可达

改动：`mcp-jobs.json` 的 `action.enum` 补入 `stat,json,find,sub`
（`file_op.m` 一直有这 4 个 `case`，描述里也一直列着，只有 enum 漏了 ⇒ 客户端参数校验直接拒）。

```
mcp_call mcp__matlab__file_op {"action":"json","target":"<任意 .json>","optsJson":""}
```
- **修好的样子**：`JSON VALID: <n> bytes, top-level keys: ...`
- **还没生效**：`params/action must be equal to one of the allowed values`

代码路径已用直接调 `file_op.m` 的方式验过，4 个全通（含 `sub` 的拒绝路径与 `.bak` 备份），
所以这一步只验"客户端 enum 是否已刷新"。

## 2. `code_refresh` 描述里那条会骗人的 `"pattern"` 应当消失

改动：磁盘上的描述早已是 v11 的瘦身版（不含 `pattern`）；同时我**把 `pattern` 实现了**，
所以即使描述还留着它也不再是谎。两项都该在 reload 后可见。

```
mcp_get mcp__matlab__code_refresh
```
- **修好的样子**：描述是一行"Report how many .m files the session holds and rehash or clear them..."，**不含** `"pattern"`
- **还没生效**：描述里仍有 `optsJson: {"clearFunctions":...,"lint":true,"pattern":"*.m"}`

功能侧已现场验过（不依赖 reload）：`{"pattern":"*.json"}` → `scanned: 1 file(s) matching "*.json"`，
默认 → `8 file(s) matching "*.m"`。

## 3. 上下文瘦身的字节收益应当真的到账

**准确口径**（用 `mcp_get` 的实际返回形状 `{name,description,inputSchema,serverName,originalName}` 算，
不是用注册表文件大小算——`signatures` 2752 字符与 `title` 720 字符**根本不发**给客户端）：

| 32 个扩展工具的传输载荷 | 字符 | ≈tokens |
|---|---|---|
| reload **前**（当前会话在付） | 38786 | ~9697 |
| reload **后**（磁盘现状） | 15627 | ~3907 |
| **净省** | **−23159（−59.7%）** | **−5790 / 每轮对话** |

```
mcp_list {"keyword":"matlab","includeDescription":true}
```
- **修好的样子**：32 个扩展工具的描述合计约 **3.8k 字符**（平均 ~120 字符/工具）；
  `Pass "" when not using it - this bridge requires every listed argument to be present` 这句样板**只出现 1 次**
- **还没生效**：描述合计约 **20.4k 字符**，那句 69 字符的样板**重复 31 次**（~2139 字符纯重复）

剩下那 15627 里 **~90% 砍不动**：协议规定的 JSON 键（`"description":`、`"type":"string"` 各 1232）、
每个工具的 schema 外壳（1056）、`additionalProperties:false`（928，它是"参数名打错就报错"的唯一保障）、
参数名本身（780）、以及参数说明文本（2550，那是 `optsJson` 有哪些键的唯一文档，砍了就等于把
`glob` 没人知道那个缺陷再造一遍）。唯一可裁量的是 `required` 数组（812 字符 ≈ 200 tokens ≈ 1.3%），
但 32 个工具里只有 8 个能从 `:badArgs` 守卫取到"哪些是真必填"的证据，砍错会让工具 reload 后直接调不动、
且当场无法证伪 ⇒ **故意没砍**，只把门禁从 `required == order` 放宽成 `required ⊆ order` 以便将来做。
详见报告 §18.1–18.2。

"减少工具个数"（懒加载下唯一能降**每轮**成本的杠杆）也查过了：最像的合并候选
`capture_figure` ⊂ `capture_app` **不成立**——`capture_figure.m:43` 钉死 `exportgraphics(...,'Resolution',150)`，
而 `capture_app` 的两个导出分支都不传 Resolution。要合并得先给 `capture_app` 加 dpi 选项。详见 §18.3。


---

## reload 后建议顺手复跑的两条静态闸（都不需要 MATLAB）

```
node extensions/tools/check_registry_v12.js     # 期望 problems=0 CONTRACT OK
```
```
mcp_call mcp__matlab__check_code_tree {"rootPath":"<REPO_ROOT>\\extensions\\functions","pattern":"*.m","minSeverity":"error"}
                                                  # 期望 TOTAL files=58 error=0
```

## 还差一条我修不了的（reload 也不会变）

`cancel_job` 的实况描述写着 `Needs confirm="yes"`，但它只有 `jobId` 一个形参、没有确认闸
（真有 `confirm='yes'` 闸的是 `cancel_sweep`）。磁盘上的文本 v11 已改真，
但要给它**加**确认闸就得动 `signatures.input.order`（加第二个入参），那是启动时读的——
reload 只能让"文本变真"，不能让"多出一个参数"。
