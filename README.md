# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

MATLAB MCP Server **扩展层**：基于官方 [matlab/matlab-mcp-server](https://github.com/matlab/matlab-mcp-server)（MathWorks），
零修改官方代码，经 `--extension-file` 把工具数从 5 个内置扩到 **37 个**（32 自研 .m 工具）。

## 版本记录（官方 exe，不入库，见 .gitignore）

| 官方版本 | 文件 | SHA-256 | 备注 |
|---|---|---|---|
| v0.13.0 | matlab-mcp-server-windows-x64.exe | `4e065398…`（全值见 0d76df5 提交说明） | 已退役备份 |
| **v0.14.0**（当前） | matlab-mcp-server-windows-x64.exe（19,502,944 B） | `6697a8962f148628f11d93b36960235871de5614905d6a27c55341c2b83f4118` | 2026-10-12 三方仲裁一致：certutil / Get-FileHash / 本仓库 file_op(sha256)；官方发行页 https://github.com/matlab/matlab-mcp-server/releases/tag/v0.14.0 |

> exe 是 MathWorks 专有二进制，本仓库不转发不改动，仅记录版本与指纹；GitHub Release
> `official-exe-v0.14.0` 为本仓库扩展层所钉扎的官方构建记录。

## 工具构成（37 = 5 内置 + 32 扩展）

- **官方内置（5）**：evaluate_matlab_code、run_matlab_file、run_matlab_test_file、check_matlab_code、detect_matlab_toolboxes
- **mcp-jobs.json（16）**：submit_job / submit_sweep / sweep_status / cancel_sweep / job_status / list_jobs / cancel_job / eval_async / evaluate_logged / get_variable / capture_figure / enable_checkpoint / restore_checkpoint / gpu_probe / gpu_mc / file_op
- **mcp-qa-tools.json（16）**：session_info / env_report / resolve_capability / list_ui / capture_app / run_tests / check_code_tree / code_refresh / longrun_preflight / suite_run / suite_status / steps_run / session_reset / sl_build / sl_sim / sl_compare
- 实现：`extensions/functions/*.m`（59 个文件，含 helper）；注册表：`extensions/mcp-jobs.json`、`extensions/mcp-qa-tools.json`

## schema 修复代理（mcp-schema-fix-proxy.mjs）

夹在 MCP 客户端与官方 exe 之间的 stdio JSON-RPC 代理，两件事（均只增不改、幂等、未修改帧逐字节透传）：

1. **properties 补齐**：官方内置 `detect_matlab_toolboxes` 的 inputSchema 缺 `properties` 键，
   部分 provider 的 schema 校验会整轮拒绝。代理补齐语义等价的 `properties: {}`。
2. **内置工具描述增补**：给 evaluate_matlab_code / evaluate_logged / run_matlab_file /
   run_matlab_test_file / eval_async / list_jobs 的 description 追加两类实测语义（exe 硬编码无法从源头改）：
   - TIMEOUT SEMANTICS：客户端 ~60s 掐断调用，但引擎继续跑被掐断的任务（队头阻塞）；>45s 的活走
     eval_async+job_status / suite_run 分片。
   - CONTINUATION-MODE TRAP：残缺语法（缺 end）使桌面 MATLAB 进入续行模式，其后**一切**工具调用
     返回空文本且无错误；恢复法 = 向 evaluate_matlab_code 单独发缺失的关键字（如 `end`），缓冲一次性回放。
     该陷阱已向上游报告：https://github.com/matlab/matlab-mcp-server/issues/123

用法与回滚见 [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md)。回归测试：`node proxy.test.mjs`（26 项）、
`node proxy-backpressure.test.mjs`（17 项），当前均全绿。

## 运行时防护（扩展层自研）

- `mcp_budget_guard(expectedSec, label)`：长任务入口守卫，>45s 时警告并指路分片方案。
- `run_tests` 把每次套件实测墙钟写入同目录 `<suite>.mcp_budget`；下次运行前若上次 >45s，先发 BUDGET WARNING。
  （该文件已 gitignore，属运行时产物。）
- `run_tests` 项目根推断：`tests/` 约定 + 通用回退（套件目录本身 + 含 `+package` 的父目录）。

## 已知行为与边界

- 共享单 MATLAB 会话：所有工具调用**串行**（实测 5s+1s 并发=6.4s），无并发逃生通道。
- 提交作业约定：`out = f(params)`（batch 输出数恒 0，worker 数走 NumWorkersRange；见 mcp_submit_job_core.m 注释）。
- `sl_sim` paramJson 权威格式 `{"set":[{block,name,value}]}`，兼容 `{"block.param":value}` 速记（下划线分割）。
- `sl_compare` 时间轴配对约定 `<name>__y` ↔ `<name>__t`；无配对时打印 note 并回退索引时间。
- `session_reset` 作用域 figures|models|pool|timers|vars(opt-in)；'all' 永不清 vars。

## 维护约定

- 运行时产物（jobs/ sweeps/ snippets/ exports/ logs/ *.mcp_budget checkpoint*）一律不入库。
- 对官方 exe 的行为缺陷：先在本仓库复现取证（A/B 复现 ≥2 次），再向上游提 issue，本地做文档/代理层缓解。
