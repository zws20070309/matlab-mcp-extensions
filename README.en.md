# matlab-mcp-extensions

[简体中文](README.md) | [English](README.en.md)

[![tools](https://img.shields.io/badge/tools-37%20(5%2B32)-blue)](#highlights)
[![base](https://img.shields.io/badge/official-v0.16.0-green)](https://github.com/matlab/matlab-mcp-server/releases)
[![matlab](https://img.shields.io/badge/MATLAB-R2025a-orange)](#requirements)
[![license](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![tests](https://img.shields.io/badge/proxy%20suite-58%2F58-brightgreen)](#verification)

An **extension layer** for the official [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-server) (MathWorks).

Zero changes to official code or the official binary. Tools are registered purely through the
`--extension-file` mechanism, which grows the tool surface from 5 built-in tools to **37**
(5 built-in + 32 extensions): async jobs, parameter sweeps, Simulink modelling and simulation,
GPU sampling, file operations, figure capture, session checkpoints, code-quality gates and a
certifiable test pipeline.

```
┌────────────────┐   stdio JSON-RPC   ┌──────────────────────────┐   stdio   ┌───────────────┐
│  MCP client    │ ◄────────────────► │ mcp-schema-fix-proxy.mjs │ ◄────────► │ official exe  │
│ (any host)     │   37 tools visible  │ schema repair + guard    │           │  v0.16.0      │
└────────────────┘                     └──────────────────────────┘           └───────┬───────┘
                                                                                     │
                                        extensions/mcp-jobs.json      ◄──────────────┤
                                        extensions/mcp-qa-tools.json  ◄──────────────┤
                                                                                     ▼
                                                                              ┌───────────────┐
                                                                              │    MATLAB     │
                                                                              └───────────────┘
```

## Capability overview (37 = 5 built-in + 32 extensions)

| Capability block | Tools |
|---|---|
| Official built-in (5) | `evaluate_matlab_code` · `run_matlab_file` · `run_matlab_test_file` · `check_matlab_code` · `detect_matlab_toolboxes` |
| Async jobs & sweeps (9) | `submit_job` · `submit_sweep` · `sweep_status` · `cancel_sweep` · `job_status` · `list_jobs` · `cancel_job` · `eval_async` · `evaluate_logged` |
| Files & variables (2) | `file_op` (14 actions in one tool: read/write/append/hash/list/tail/exists/stat/mkdir/copy/delete/json/find/sub) · `get_variable` |
| Graphics & session (5) | `capture_figure` · `capture_app` · `list_ui` · `session_info` · `session_reset` |
| Code quality & testing (9) | `run_tests` · `check_code_tree` · `code_refresh` · `suite_run` · `suite_status` · `steps_run` · `longrun_preflight` · `resolve_capability` · `env_report` |
| Simulink & GPU (7) | `sl_build` · `sl_sim` · `sl_compare` · `gpu_probe` · `gpu_mc` · `enable_checkpoint` · `restore_checkpoint` |

## Highlights

- **Evidence-oriented output.** Every tool returns facts you can check, not a claim that something
  happened: jobs persist `done.json` / `run.log`; test suites report tree digests and two independent
  accounts (files on disk, cases executed); simulations come with a self-check of the captured signal
  (n / min / max / mean); file writes return a SHA-256. Tools also refuse to overstate: `suite_run`
  will not certify coverage when no `counts.json` is present to prove it.
- **Long-run friendly.** The `eval_async` + `job_status` async flow, `suite_run` sharding with a time
  budget and resume-by-`runId`, and `mcp_budget_guard` early warnings all exist so that no single call
  can wedge the whole session.
- **Schema-repair proxy.** `mcp-schema-fix-proxy.mjs` is an optional stdio JSON-RPC proxy that fills in
  schema gaps in the official binary for strict AI providers and appends measured timeout semantics to
  built-in tool descriptions. Append-only, idempotent, and unmodified frames pass through byte-for-byte
  (design and safety boundaries: [SCHEMA-FIX-README.md](SCHEMA-FIX-README.md), Chinese).
- **Engine-occupancy guard** (same proxy). When the previous call has been in flight past a threshold,
  a new call returns a diagnosis immediately instead of queueing for a timeout, and logs a
  CALL / SLOW / REFUSED ledger to `extensions/logs/proxy_calls.log`. Head-of-line-blocking incidents no
  longer have to be reconstructed from session transcripts.

## Requirements

- MATLAB R2025a or newer
- Official `matlab-mcp-server` **v0.16.0** windows-x64
  (SHA-256 `7c70fdc69e7e7d4762732fede64f348b18ecbc89c3de705f9dde89a86d1883ea`)
- Any MCP client that supports `--extension-file` custom tools
- Optional: Node.js 18+ (to run the schema-repair proxy and its regression suites)

## Quick start

1. Obtain the official exe (this repository does not redistribute it) and place it anywhere.
2. Launch the official server with both registries:

   ```console
   matlab-mcp-server-windows-x64.exe \
     --matlab-root=<MATLAB install dir> \
     --extension-file=<this repo>/extensions/mcp-jobs.json \
     --extension-file=<this repo>/extensions/mcp-qa-tools.json
   ```

3. (Recommended) Wrap the server with the proxy to get schema repair and the occupancy guard:

   ```console
   node mcp-schema-fix-proxy.mjs -- <the server command above>
   ```

4. After the client reconnects, all 32 extension tools sit alongside the 5 built-in ones (37 total).

### Client configuration example

```json
{
  "mcpServers": {
    "matlab": {
      "type": "stdio",
      "command": "<absolute path to node>",
      "args": [
        "<this repo>/mcp-schema-fix-proxy.mjs",
        "--",
        "<absolute path to official exe>",
        "--matlab-root=<MATLAB install dir>",
        "--initialize-matlab-on-startup=false",
        "--disable-telemetry=true",
        "--extension-file=<this repo>/extensions/mcp-jobs.json",
        "--extension-file=<this repo>/extensions/mcp-qa-tools.json"
      ],
      "env": { "MC_WEDGE_AFTER_MS": "110" },
      "timeoutMs": 120000
    }
  }
}
```

> Set `MC_WEDGE_AFTER_MS` slightly **below the client's per-call timeout**: the threshold means
> "past the client's timeout point, so this is a wedge". Use the default 55 s when the client times out
> at 60 s, and 110 s when it times out at 120 s.

## Repository layout

```
extensions/
  functions/*.m        32 tool implementations + 28 shared helpers (60 .m files total)
  mcp-jobs.json        registry 1 (jobs/sweeps/files/variables/graphics/checkpoints/GPU, 16 tools)
  mcp-qa-tools.json    registry 2 (session/testing/Simulink/environment/pipeline, 16 tools)
  tools/*.js           registry maintenance scripts
  v10_fixture/         reproducible test fixture
  docs/                per-round measurement and acceptance records
mcp-schema-fix-proxy.mjs       schema-repair proxy + engine-occupancy guard
proxy.test.mjs                 schema-repair unit tests (26)
proxy-backpressure.test.mjs    backpressure / frame-loss / exit-race regression (17)
proxy-wedgeguard.test.mjs      guard unit tests + real proxy process integration (15)
CHANGELOG.md                   per-round changes and measured conclusions
UPGRADE-0.16.0-REPORT.md       0.16.0 upgrade and adaptation report
SCHEMA-FIX-README.md           proxy design, root-cause evidence, safety boundaries
```

## Verification

```console
# Three proxy regression suites (58 checks total)
node proxy.test.mjs
node proxy-backpressure.test.mjs
node proxy-wedgeguard.test.mjs

# Live self-check: start the official exe, handshake, report schema defects before/after
node mcp-schema-fix-proxy.mjs --probe -- <official exe> [original args...]
```

Tool behaviour on the MATLAB side is regression-tested by the tools themselves: `check_code_tree`
lints the whole tree, `run_tests` runs test files, `suite_run` performs a budgeted, tree-fingerprinted,
certifiable full-suite run, and `steps_run` executes a fixed-order closeout pipeline.

## Known boundaries

- **Figures do not survive across calls in `nodesktop` display mode** (official exe behaviour, not
  fixable in this layer). Start with `--matlab-display-mode=desktop` if `capture_figure` /
  `capture_app` / `list_ui` must see figures created by an earlier call; otherwise those tools report
  `[<tool>:noFiguresNodesktop]` with two concrete remedies instead of a bare "No open figures".
- **The proxy cannot prevent the exe's watchdog cleanup.** The official exe terminates the MATLAB
  process it started when the server closes, and the proxy exits together with it, so a short-lived
  throwaway call cannot be used to "pre-warm" a long-lived engine (measured conclusion in
  `UPGRADE-0.16.0-REPORT.md`).
- **`check_code_tree` grades severity with `checkcode(...,'-severity')`** (measured scale: 0=info,
  1=warning, 3=error). On a release without that option it falls back to keyword grading and prints a
  `NOTE` saying the basis was downgraded.

## License & attribution

**The original code in this repository is MIT-licensed** (see [LICENSE](LICENSE), plain MIT text).
The exact scope and exclusions are spelled out in [NOTICE](NOTICE).

**The official MATLAB MCP Server binary is not part of this repository and is NOT MIT.**

- Copyright 2025-2026 The MathWorks, Inc. All rights reserved.
- Licence: a MathWorks custom licence (BSD-3-Clause-style conditions plus an extra restriction);
  the complete text is reproduced verbatim in [LICENSE-MathWorks.md](LICENSE-MathWorks.md).
- Clause 3: the software and all modifications or derivatives are licensed to you solely for use
  in conjunction with MathWorks products and service offerings.

This repository contains no official binary (it is matched by `.gitignore`) and modifies no official
code. See [NOTICE](NOTICE) for the full declaration and the three-layer licence table.

MATLAB, Simulink, and MathWorks are trademarks of The MathWorks, Inc. This project is not
affiliated with, endorsed by, or supported by The MathWorks, Inc.
