function mcp_budget_guard(expectedSec, label)
%MCP_BUDGET_GUARD Fail fast when a call would exceed the MCP client timeout window.
%   The DSH MCP client times a tool call out at ~60 s while the MATLAB engine
%   keeps executing the abandoned call: the engine is then busy for the rest
%   of the task while every other session's calls (including trivial
%   session_info pings) queue behind it and die with "Request timed out".
%   Field evidence: session-7ac4a2ae (2026-10-10) lost 23 calls across 3
%   agents to this head-of-line blocking after one >60 s test suite.
%
%   Call this at the top of a long-running script executed through
%   evaluate_matlab_code / run_matlab_file:
%     mcp_budget_guard(90, 'acceptance suite')
%   It errors with actionable advice while aborting is still cheap.
if nargin < 2, label = 'this task'; end
expectedSec = mcp_num(expectedSec, 0);
if ~isfinite(expectedSec) || expectedSec <= 0
    return
end
budget = 45;   % leave margin under the ~60 s client timeout
if expectedSec <= budget
    fprintf('budget: %s ~%gs, inside the %gs MCP window\n', label, expectedSec, budget);
    return
end
warning('mcp:budgetGuard', ...
    ['%s needs ~%gs but the MCP client times calls out at ~60s and leaves the ' ...
     'engine busy afterwards (head-of-line blocking). Split it: run_tests for ' ...
     'suites, suite_run with shards/budgetSec for trees, or eval_async + ' ...
     'job_status for single jobs.'], label, expectedSec);
fprintf(['BUDGET: %s ~%gs exceeds the safe %gs MCP window - use eval_async/' ...
    'suite_run instead, or the client will time out and the engine will stay ' ...
    'busy\n'], label, expectedSec, budget);
end
