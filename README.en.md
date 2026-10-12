# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

An **extension layer** for the official [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-server) (MathWorks):
zero modifications to official code. Via the `--extension-file` mechanism, the tool count grows from 5 built-in
tools to **37**, giving AI agents async jobs, Simulink, GPU, file operations, UI capture, session checkpoints and a
full test pipeline.

## Capability overview (37 = 5 built-in + 32 extensions)

| Capability block | Tools |
|---|---|
| Official built-in (5) | evaluate_matlab_code · run_matlab_file · run_matlab_test_file · check_matlab_code · detect_matlab_toolboxes |
| Async jobs & sweeps (9) | submit_job · submit_sweep · sweep_status · cancel_sweep · job_status · list_jobs · cancel_job · eval_async · evaluate_logged |
| Files & variables (2) | file_op (14 operations in one tool: read/write/append/hash/content-search/substitute/...) · get_variable |
| Graphics & session (5) | capture_figure · capture_app · list_ui · session_info · session_reset |
| Code quality & testing (9) | run_tests · check_code_tree · code_refresh · suite_run · suite_status · steps_run · longrun_preflight · resolve_capability · env_report |
| Simulink & GPU (7) | sl_build · sl_sim · sl_compare · gpu_probe · gpu_mc · enable_checkpoint · restore_checkpoint |

## Highlights

- **Evidence-oriented output**: every tool returns checkable facts — on-disk done.json/run.log for jobs, tree digests
  for suites, self-checked simulation stats (min/max/mean), three-way-arbitrated file hashes.
- **Long-run friendly**: eval_async + job_status async flow, suite_run sharding with time budgets, mcp_budget_guard
  early warnings — so a single call never wedges the session.
- **Schema-fix proxy** (`mcp-schema-fix-proxy.mjs`): an optional stdio JSON-RPC proxy that patches schema gaps for
  strict AI providers and appends measured timeout semantics to built-in tool descriptions. Append-only, idempotent,
  unmodified frames pass through byte-for-byte (details in [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md), Chinese).

## Requirements

- MATLAB R2025a or newer (tested against the official matlab-mcp-server **v0.14.0**, windows-x64)
- An MCP client that supports `--extension-file` custom tools (Claude Code, DSH, ...)

## Quick start

1. Clone this repository.
2. Launch the official server with both registries:

   ```
   matlab-mcp-server-windows-x64.exe \
     --matlab-root=<MATLAB install dir> \
     --extension-file=<this repo>/extensions/mcp-jobs.json \
     --extension-file=<this repo>/extensions/mcp-qa-tools.json
   ```
3. (Optional) If your AI provider validates schemas strictly, wrap the server with the proxy:

   ```
   node mcp-schema-fix-proxy.mjs -- <the server command above>
   ```

4. After the client reconnects, all 32 extension tools sit alongside the 5 built-in ones.

## Repository layout

```
extensions/
  functions/*.m        32 tool implementations + shared helpers
  mcp-jobs.json        registry 1 (jobs/files/graphics/GPU/checkpoints, 16 tools)
  mcp-qa-tools.json    registry 2 (session/testing/Simulink/env, 16 tools)
  docs/                historical acceptance records
mcp-schema-fix-proxy.mjs   the schema-fix proxy
proxy.test.mjs / proxy-backpressure.test.mjs   proxy regression suites (run with node)
```

## License & attribution

The official MATLAB MCP Server binary and MATLAB are copyright **The MathWorks, Inc.**
This repository hosts only the extension layer (.m implementations, registry JSON, proxy scripts);
it contains no official binary and modifies no official code.
