# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

[![tools](https://img.shields.io/badge/tools-37%20(5%2B32)-blue)](#特色)
[![base](https://img.shields.io/badge/official-v0.16.0-green)](https://github.com/matlab/matlab-mcp-server/releases)
[![matlab](https://img.shields.io/badge/MATLAB-R2025a-orange)](#环境要求)
[![license](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![tests](https://img.shields.io/badge/proxy%20suite-58%2F58-brightgreen)](#验证)

官方 [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-server)（MathWorks）的**扩展层**。

零修改官方代码与二进制，只通过 `--extension-file` 机制注册自定义工具，把可用工具从 5 个内置扩展到 **37 个**
（5 内置 + 32 扩展），让 AI 代理获得异步作业、参数扫描、Simulink 建模与仿真、GPU 采样、文件操作、
图形截图、会话检查点、代码质量门禁与可认证的测试流水线。

```
┌──────────────┐   stdio JSON-RPC   ┌─────────────────────────┐   stdio   ┌──────────────┐
│  MCP 客户端   │ ◄────────────────► │ mcp-schema-fix-proxy.mjs │ ◄────────► │  官方 exe     │
│ (任意宿主)    │   37 个工具可见      │  schema 补齐 + 占用守卫   │           │  v0.16.0     │
└──────────────┘                     └─────────────────────────┘           └──────┬───────┘
                                                                                   │
                                       extensions/mcp-jobs.json      ◄──────────────┤
                                       extensions/mcp-qa-tools.json  ◄──────────────┤
                                                                                   ▼
                                                                            ┌──────────────┐
                                                                            │    MATLAB     │
                                                                            └──────────────┘
```

## 能力一览（37 = 5 内置 + 32 扩展）

| 能力块 | 工具 |
|---|---|
| 官方内置（5） | `evaluate_matlab_code` · `run_matlab_file` · `run_matlab_test_file` · `check_matlab_code` · `detect_matlab_toolboxes` |
| 异步作业与扫描（9） | `submit_job` · `submit_sweep` · `sweep_status` · `cancel_sweep` · `job_status` · `list_jobs` · `cancel_job` · `eval_async` · `evaluate_logged` |
| 文件与变量（2） | `file_op`（14 种动作合一：读/写/追加/哈希/列表/尾部/存在/属性/建目录/复制/删除/JSON 校验/搜索/定点替换） · `get_variable` |
| 图形与会话（5） | `capture_figure` · `capture_app` · `list_ui` · `session_info` · `session_reset` |
| 代码质量与测试（9） | `run_tests` · `check_code_tree` · `code_refresh` · `suite_run` · `suite_status` · `steps_run` · `longrun_preflight` · `resolve_capability` · `env_report` |
| Simulink 与 GPU（7） | `sl_build` · `sl_sim` · `sl_compare` · `gpu_probe` · `gpu_mc` · `enable_checkpoint` · `restore_checkpoint` |

## 特色

- **证据导向输出**：每个工具返回可核对的事实，而不是"已完成"。作业落盘 `done.json` / `run.log`；
  测试套件给树指纹与覆盖两本账；仿真给信号自检（n / min / max / mean）；文件操作给 SHA-256。
  工具自己也会在结论不成立时明说（例如 `suite_run` 在缺少 `counts.json` 时拒绝声称覆盖已证明）。
- **长任务友好**：`eval_async` + `job_status` 异步流；`suite_run` 分片 + 时间预算 + 可续跑（同 `runId`）；
  `mcp_budget_guard` 对超窗调用提前预警。目标是不让一次调用把整个会话拖死。
- **schema 修复代理**：`mcp-schema-fix-proxy.mjs` 是可选的 stdio JSON-RPC 代理，为严格校验的 AI 服务商
  补齐官方 exe 的 schema 缺陷，并为内置工具追加实测得到的超时语义。只增不改、幂等、未修改帧逐字节透传
  （详见 [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md)）。
- **引擎占用守卫**（同上代理）：上一个调用在途超过阈值时，新调用立即返回诊断而非排队空等，
  并在 `extensions/logs/proxy_calls.log` 留下 CALL / SLOW / REFUSED 台账。队头阻塞事故不再需要
  从会话记录反推。

## 环境要求

- MATLAB R2025a 或更新
- 官方 `matlab-mcp-server` **v0.16.0** windows-x64
  （SHA-256 `7c70fdc69e7e7d4762732fede64f348b18ecbc89c3de705f9dde89a86d1883ea`）
- 任意支持 `--extension-file` 自定义工具的 MCP 客户端
- 可选：Node.js 18+（运行 schema 修复代理及其回归测试）

## 快速开始

1. 取得官方 exe（本仓库不收录二进制），放在任意目录；
2. 用两个注册表启动官方服务器：

   ```console
   matlab-mcp-server-windows-x64.exe \
     --matlab-root=<MATLAB安装目录> \
     --extension-file=<本仓库>/extensions/mcp-jobs.json \
     --extension-file=<本仓库>/extensions/mcp-qa-tools.json
   ```

3. （推荐）用代理包住服务器，以获得 schema 修补与引擎占用守卫：

   ```console
   node mcp-schema-fix-proxy.mjs -- <上面的服务器命令>
   ```

4. 客户端重连后，32 个扩展工具与 5 个内置工具并列可见（共 37 个）。

### 客户端配置示例

```json
{
  "mcpServers": {
    "matlab": {
      "type": "stdio",
      "command": "<node 绝对路径>",
      "args": [
        "<本仓库>/mcp-schema-fix-proxy.mjs",
        "--",
        "<官方 exe 绝对路径>",
        "--matlab-root=<MATLAB安装目录>",
        "--initialize-matlab-on-startup=false",
        "--disable-telemetry=true",
        "--extension-file=<本仓库>/extensions/mcp-jobs.json",
        "--extension-file=<本仓库>/extensions/mcp-qa-tools.json"
      ],
      "env": { "MC_WEDGE_AFTER_MS": "110" },
      "timeoutMs": 120000
    }
  }
}
```

> `MC_WEDGE_AFTER_MS` 请设为**客户端调用超时略低**的值：该阈值表示"已越过客户端超时点，可判定为卡死"。
> 客户端超时 60 s 时用默认 55 s；超时 120 s 时用 110 s。

## 仓库结构

```
extensions/
  functions/*.m        32 个工具实现 + 28 个共享 helper（共 60 个 .m）
  mcp-jobs.json        注册表 1（作业/扫描/文件/变量/图形/检查点/GPU，16 工具）
  mcp-qa-tools.json    注册表 2（会话/测试/Simulink/环境/流水线，16 工具）
  tools/*.js           注册表维护脚本
  v10_fixture/         可复现的测试夹具
  docs/                历版验收与实测记录
mcp-schema-fix-proxy.mjs        schema 修复代理 + 引擎占用守卫
proxy.test.mjs                  schema 修补逻辑单测（26 项）
proxy-backpressure.test.mjs     背压/丢帧/退出竞态回归（17 项）
proxy-wedgeguard.test.mjs       占用守卫单测 + 真实代理进程集成（15 项）
CHANGELOG.md                    逐轮变更与实测结论
UPGRADE-0.16.0-REPORT.md        0.16.0 升级适配报告
SCHEMA-FIX-README.md            代理的设计、根因取证与安全边界
```

## 验证

```console
# 代理三套回归（共 58 项）
node proxy.test.mjs
node proxy-backpressure.test.mjs
node proxy-wedgeguard.test.mjs

# 真实链路自检：启动官方 exe、握手、报告修补前后的 schema 缺陷数
node mcp-schema-fix-proxy.mjs --probe -- <官方 exe> [原参数...]
```

MATLAB 侧的工具行为回归通过工具自身完成：`check_code_tree` 全树 lint、`run_tests` 跑测试文件、
`suite_run` 做带预算与树指纹的认证式全量回归、`steps_run` 跑固定顺序的收尾流水线。

## 已知边界

- **`nodesktop` 显示模式下图形不跨调用存活**（官方 exe 行为，非本层可修）。需要 `capture_figure` /
  `capture_app` / `list_ui` 跨调用工作时，用 `--matlab-display-mode=desktop` 启动；否则三个图工具会
  明确报出 `[<tool>:noFiguresNodesktop]` 并给出两条补救路径，而不是只回一句"No open figures"。
- **代理层无法阻止 exe 的看门狗清理**：官方 exe 关闭时会结束它自己启动的 MATLAB 进程，代理退出
  与之联动，因此短命的一次性调用无法用来"预热"长驻引擎（实测结论见 `UPGRADE-0.16.0-REPORT.md`）。
- **`check_code_tree` 的严重级别依据 `checkcode(...,'-severity')`**（实测刻度 0=info / 1=warning /
  3=error）。若某版本不支持该选项，会降级为关键词分级并在输出里打印 `NOTE` 说明依据已降级。

## 许可与归属

**本仓库原创代码采用 MIT 许可**：见 [LICENSE](LICENSE)（纯 MIT 正文）。许可范围（32 个工具 / 60 个 `.m`、
两个注册表、代理、脚本、夹具、文档）与排除项见 [NOTICE](NOTICE)。

**官方 MATLAB MCP Server 二进制不属于本仓库，也不适用 MIT**：

- 版权：Copyright 2025-2026 The MathWorks, Inc. All rights reserved.
- 许可证：MathWorks 自定义许可证（BSD-3 形式条款 + 第 3 条限制），全文逐字收录于 [LICENSE-MathWorks.md](LICENSE-MathWorks.md)。
- 第 3 条：该软件及其任何修改与衍生版，仅授予在与 MathWorks 产品与服务配合使用时使用。

本仓库不包含官方二进制（`.gitignore` 已屏蔽），也不修改官方代码。完整声明与三层许可对照表见 [NOTICE](NOTICE)。

MATLAB、Simulink、MathWorks 是 The MathWorks, Inc. 的商标。本项目与 MathWorks 无隶属关系，亦未获得其认可或支持。
