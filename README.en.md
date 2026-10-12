# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

The **extension layer** for the MATLAB MCP Server: built on top of the official
[matlab/matlab-mcp-server](https://github.com/matlab/matlab-mcp-server) (MathWorks) with **zero modifications**
to official code. Via `--extension-file`, the tool count grows from 5 built-in tools to **37** (32 self-developed .m tools).

## Official exe version record (binary not committed, see .gitignore)

| Official version | File | SHA-256 | Notes |
|---|---|---|---|
| v0.13.0 | matlab-mcp-server-windows-x64.exe | `4e065398…` (full value in commit 0d76df5) | retired backup |
| **v0.14.0** (current) | matlab-mcp-server-windows-x64.exe (19,502,944 B) | `6697a8962f148628f11d93b36960235871de5614905d6a27c55341c2b83f4118` | verified 2026-10-12 by three independent sources: certutil / Get-FileHash / this repo's file_op(sha256); official release page: https://github.com/matlab/matlab-mcp-server/releases/tag/v0.14.0 |

> The exe is a MathWorks proprietary binary. This repository neither re-distributes nor modifies it —
> it only records the version and fingerprint. The GitHub Release `official-exe-v0.14.0` pins the exact
> official build this extension layer is tested against.

## Tool composition (37 = 5 built-in + 32 extensions)

- **Official built-in (5)**: evaluate_matlab_code, run_matlab_file, run_matlab_test_file, check_matlab_code, detect_matlab_toolboxes
- **mcp-jobs.json (16)**: submit_job / submit_sweep / sweep_status / cancel_sweep / job_status / list_jobs / cancel_job / eval_async / evaluate_logged / get_variable / capture_figure / enable_checkpoint / restore_checkpoint / gpu_probe / gpu_mc / file_op
- **mcp-qa-tools.json (16)**: session_info / env_report / resolve_capability / list_ui / capture_app / run_tests / check_code_tree / code_refresh / longrun_preflight / suite_run / suite_status / steps_run / session_reset / sl_build / sl_sim / sl_compare
- Implementation: `extensions/functions/*.m` (59 files incl. helpers); registries: `extensions/mcp-jobs.json`, `extensions/mcp-qa-tools.json`

## Schema-fix proxy (mcp-schema-fix-proxy.mjs)

A stdio JSON-RPC proxy sitting between the MCP client and the official exe. It does two things
(both append-only, idempotent, and unmodified frames pass through byte-for-byte):

1. **`properties` patching**: the built-in `detect_matlab_toolboxes` ships an inputSchema without a
   `properties` key, which some providers' schema validation rejects for the whole turn. The proxy adds
   the semantically equivalent `properties: {}`.
2. **Built-in description appendices** (exe-hardcoded, unfixable at the source): appends two measured
   semantics to the descriptions of evaluate_matlab_code / evaluate_logged / run_matlab_file /
   run_matlab_test_file / eval_async / list_jobs:
   - TIMEOUT SEMANTICS: the client times a call out at ~60s, but the MATLAB engine keeps running the
     abandoned call (head-of-line blocking). Anything over ~45s belongs in eval_async+job_status or
     sharded suite_run.
   - CONTINUATION-MODE TRAP: an incomplete statement (missing `end`) puts the desktop MATLAB command
     window into continuation mode; every later tool call then returns empty text with no error.
     Recovery: send the missing keyword (usually `end`) to evaluate_matlab_code — the buffered calls
     flush at once. Reported upstream: https://github.com/matlab/matlab-mcp-server/issues/123

Usage and rollback: see [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md) (Chinese). Regression suites:
`node proxy.test.mjs` (26 cases), `node proxy-backpressure.test.mjs` (17 cases) — both fully green.

## Runtime guards (self-developed, in the extension layer)

- `mcp_budget_guard(expectedSec, label)`: entry guard for long tasks — warns above 45s and points at the sharded alternatives.
- `run_tests` writes each suite's measured wall-clock time to `<suite>.mcp_budget`; if the last run exceeded 45s,
  a BUDGET WARNING is printed before the next run starts. (These files are gitignored runtime artifacts.)
- `run_tests` project-root inference: the `tests/` convention plus a general fallback (the suite directory itself
  and its parent when it contains `+package` folders).

## Known behaviors and boundaries

- One shared MATLAB session: all tool calls are **serial** (measured: 5s + 1s concurrently = 6.4s total); there is no concurrency escape hatch.
- Batch job convention: `out = f(params)` (batch output count is always 0; worker count goes through NumWorkersRange — see the comments in mcp_submit_job_core.m).
- `sl_sim` paramJson: canonical form `{"set":[{block,name,value}]}`; the shorthand `{"block.param":value}` is also accepted (split at the first underscore).
- `sl_compare` time-axis pairing: `<name>__y` ↔ `<name>__t`; without a pairing it prints a note and falls back to index time.
- `session_reset` scopes: figures | models | pool | timers | vars (opt-in); `all` never clears vars.

## Maintenance conventions

- Runtime artifacts (jobs/ sweeps/ snippets/ exports/ logs/ *.mcp_budget checkpoint*) are never committed.
- For behavioral defects in the official exe: reproduce and collect evidence in this repo first (A/B reproduction ≥ 2), then file an upstream issue, and mitigate locally at the docs/proxy layer.
