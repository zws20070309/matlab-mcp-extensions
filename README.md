# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

官方 [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-server)（MathWorks）的**扩展层**：零修改官方代码，
通过 `--extension-file` 机制把工具数从 5 个内置扩展到 **37 个**，让 AI 代理获得异步作业、Simulink、GPU、
文件操作、UI 截图、会话检查点与完整测试流水线等能力。

## 能力一览（37 = 5 内置 + 32 扩展）

| 能力块 | 工具 |
|---|---|
| 官方内置（5） | evaluate_matlab_code · run_matlab_file · run_matlab_test_file · check_matlab_code · detect_matlab_toolboxes |
| 异步作业与扫描（9） | submit_job · submit_sweep · sweep_status · cancel_sweep · job_status · list_jobs · cancel_job · eval_async · evaluate_logged |
| 文件与变量（2） | file_op（读/写/追加/哈希/内容搜索/替换等 14 种操作合一） · get_variable |
| 图形与会话（5） | capture_figure · capture_app · list_ui · session_info · session_reset |
| 代码质量与测试（9） | run_tests · check_code_tree · code_refresh · suite_run · suite_status · steps_run · longrun_preflight · resolve_capability · env_report |
| Simulink 与 GPU（7） | sl_build · sl_sim · sl_compare · gpu_probe · gpu_mc · enable_checkpoint · restore_checkpoint |

## 特色

- **证据导向输出**：每个工具都返回可核对的事实——作业落盘 done.json/run.log、套件树指纹、仿真数据自检（min/max/mean）、三方仲裁的文件哈希。
- **长任务友好**：eval_async + job_status 异步流、suite_run 分片与时间预算、mcp_budget_guard 超窗预警，避免单次调用卡死会话。
- **schema 修复代理**（`mcp-schema-fix-proxy.mjs`）：可选的 stdio JSON-RPC 代理，为严格校验的 AI 服务商补齐 schema 缺陷、为内置工具追加实测的超时语义说明。只增不改、幂等、未修改帧逐字节透传（详见 [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md)）。

## 环境要求

- MATLAB R2025a 或更新（本仓库针对官方 matlab-mcp-server **v0.14.0** windows-x64 测试）
- 支持 `--extension-file` 自定义工具的 MCP 客户端（Claude Code、DSH 等）

## 快速开始

1. 克隆本仓库；
2. 用两个注册表启动官方服务器：

   ```
   matlab-mcp-server-windows-x64.exe \
     --matlab-root=<MATLAB安装目录> \
     --extension-file=<本仓库>/extensions/mcp-jobs.json \
     --extension-file=<本仓库>/extensions/mcp-qa-tools.json
   ```
3. （可选）若你的 AI 服务商对 schema 严格，用代理包住服务器：

   ```
   node mcp-schema-fix-proxy.mjs -- <上面的服务器命令>
   ```

4. 客户端重连后，32 个扩展工具与 5 个内置工具并列可用。

## 仓库结构

```
extensions/
  functions/*.m        32 个工具实现 + 共享 helper
  mcp-jobs.json        注册表 1（作业/文件/图形/GPU/检查点，16 工具）
  mcp-qa-tools.json    注册表 2（会话/测试/Simulink/环境，16 工具）
  docs/                历版验收记录
mcp-schema-fix-proxy.mjs   schema 修复代理
proxy.test.mjs / proxy-backpressure.test.mjs   代理回归测试（node 直接运行）
```

## 许可与归属

官方 MATLAB MCP Server 二进制与 MATLAB 版权归 **The MathWorks, Inc.**；本仓库仅托管扩展层
（.m 实现、注册表 JSON、代理脚本），不包含也不修改官方二进制。
