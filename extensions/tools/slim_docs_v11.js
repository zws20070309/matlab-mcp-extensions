// v11 context diet: replace long tool/property prose with short, decision-grade text.
// Contract preserved: tools[].inputSchema.required == signatures.<tool>.input.order,
// every property described, additionalProperties:false. Run: node slim_docs_v11.js
const fs = require('fs');

const D = {
  // ---- mcp-qa-tools.json -------------------------------------------------
  capture_app: ['Capture window to PNG',
    'Screenshot a figure or uifigure to PNG. Needs an open window in this session; returns the file path.',
    { target: 'Window number, or app title substring', outPath: 'PNG path to write', mode: '"figure" | "app" | "auto"' }],
  list_ui: ['List open figures and apps',
    'List open MATLAB figures/uifigure apps with titles and handle paths, so a capture or click can name a window.',
    { target: 'Filter substring; empty lists all', verbose: 'true also lists control hierarchy' }],
  run_tests: ['Run one test file or folder',
    'Run a MATLAB test file or folder and print a pass/fail summary. For whole-suite certification with budgets use suite_run.',
    { testPath: '.m file or folder with tests' }],
  session_info: ['Session and host state',
    'Print MATLAB version, pid, memory, toolbox list and GPU availability. Cheap; call before long work.',
    { level: '"short" | "full"' }],
  sl_sim: ['Run a Simulink simulation',
    'Load a model, apply parameter overrides, run sim, write outputs to MAT and print a summary.',
    { modelPath: '.slx path', simTime: 'Stop time, e.g. "10"', paramJson: '{"block.param":value} or ""', outDir: 'Folder for the .mat, or "" for temp', keepInSession: 'true leaves the model loaded' }],
  sl_compare: ['Diff two sim result sets',
    'Compare variables from two .mat result sets within a tolerance and print per-signal verdicts.',
    { aRef: 'First .mat (or var)', bRef: 'Second .mat (or var)', tolJson: '{"abs":1e-6,"rel":1e-6} or ""', maxShift: 'Max samples to report per signal' }],
  resolve_capability: ['Report capability availability',
    'Resolve named toolbox/GPU/feature requirements against this host and print AVAILABLE / MISSING per item.',
    { namesJson: 'JSON array or object of requirement names', showTable: 'true prints every row' }],
  env_report: ['Host and toolbox inventory',
    'Print OS memory, CPU, MATLAB release, installed toolboxes and licensed GPUs.',
    { scope: '"all" | "memory" | "toolboxes" | "gpu"' }],
  session_reset: ['Clear workspace, figures, path',
    'Clear the base workspace and/or close figures and reset the path. Destructive: confirm must be the literal word.',
    { what: '"workspace" | "figures" | "path" | "all"', confirm: 'Literal "yes" to proceed' }],
  check_code_tree: ['Lint a folder of .m files',
    'Run checkcode over every .m under a folder and print per-file error/warning counts plus a verdict line.',
    { rootPath: 'Folder to scan', pattern: 'Glob, usually "*.m"', minSeverity: '"error" | "warning" | "info"' }],
  sl_build: ['Build a model from JSON',
    'Create or patch a Simulink model from a JSON block/wire spec, then save it.',
    { modelPath: '.slx to create or patch', specJson: 'Model spec as JSON', optsJson: '{"overwrite":true,...} or "" }'.trim() }],
  longrun_preflight: ['Gate before a long run',
    'Go/NO-GO before a long MATLAB run: free memory, MATLAB process count, tests folder, and artifacts newer/older than sources. Prints reasons.',
    { optsJson: '{"minFreeMB":2048,"maxMatlabProcs":2,"repoRoot":"...","testsDir":"...","evidenceFile":"...","sourceDirs":["src","tests"]}' }],
  code_refresh: ['Report and drop stale code',
    'Report how many .m files the session holds and rehash or clear them, so a run cannot certify old bytecode. +package/@class need clear functions, which it names.',
    { path: 'Folder to inspect ("" = whole repo path)', optsJson: '{"clear":true|false,"pattern":"*.m"}' }],
  suite_run: ['Certify a test suite in budget',
    'Run a repo test tree in shards with a time budget, appending BEGIN/END per file to a log outside the repo, then recompute the verdict from every END record (not the last line) and refuse to certify on 0 files, missing files, failures, count mismatch or a tree that changed mid-run.',
    { repoRoot: 'Repository root', optsJson: '{"testsDir","filePattern","shards","budgetSec","maxFiles","perCase","stopOnFail","countsJson","keyFiles","keyCases","addPaths","cwd","logDir","runId","clearFunctions","force"}' }],
  suite_status: ['Read a certification from disk',
    'Recompute a suite_run run from its log: per-file last record, cumulative cases, not-run list, MUTATED rounds, and the tree digest the log recorded versus the tree now. No verdict line means interrupted, not slow.',
    { runId: 'Run id, or "" / "last" to list runs', optsJson: '{"logDir","tail","checkTree","filePattern"}' }],
  steps_run: ['Run an ordered close-out chain',
    'Run numbered steps in order and abort at the first failure, naming which steps already wrote: kinds command|test|anchor|anchors|json|sub|exists|docsync|fresh. sub keeps a .bak; quotes are refused into .json; fresh/anchors catch stale generated files.',
    { repoRoot: 'Repository root', stepsJson: 'JSON array of {"name","kind",...} or a .json file path', optsJson: '{"stopOnFail","dryRun","addPaths","logDir","runId","stepsFile"}' }],

  // ---- mcp-jobs.json -----------------------------------------------------
  submit_job: ['Submit a batch job',
    'Run a MATLAB function as an async job on a parpool worker (optional GPU) and return a job id. Needs a pool; on a 16 GB single host prefer suite_run.',
    { scriptPath: '.m with one function', paramsJson: 'JSON array of arguments or ""', tag: 'Label for list_jobs', numWorkers: 'Workers, 1 default', gpu: 'true requires a parallel GPU pool', attachedFiles: 'JSON array of files to copy to the worker' }],
  job_status: ['One job status', 'Print one submitted job\u2019s state, elapsed time and tail of its log.',
    { jobId: 'id from submit_job' }],
  list_jobs: ['List jobs', 'List submitted jobs, optionally filtered by state or tag; prints ids and states.',
    { state: '"queued|running|done|failed|""', limit: 'Max rows', tagContains: 'Substring of tag' }],
  cancel_job: ['Cancel a job', 'Cancel a running or queued job by id. Needs confirm="yes".',
    { jobId: 'id to cancel', confirm: 'Literal "yes"' }],
  get_variable: ['Inspect a workspace variable',
    'Print class/size/type and a bounded preview of a base-workspace variable. Values come from disk-safe capture, not a dump.',
    { name: 'Variable name', mode: '"summary" | "head" | "json"' }],
  capture_figure: ['Capture a figure', 'Save a figure to PNG by number or handle name, printing the path.',
    { target: 'Figure number or name', outPath: 'PNG path' }],
  enable_checkpoint: ['Turn on.matlab checkpoints', 'Enable periodic workspace snapshots and report the interval.',
    { periodSeconds: 'Snapshot interval' }],
  restore_checkpoint: ['Restore a snapshot', 'Restore the base workspace from a snapshot file. Destructive to current variables.',
    { snapshot: 'Snapshot id or file, "" = latest' }],
  eval_async: ['Evaluate code without waiting',
    'Send code to the session and return immediately; poll with job_status/list_jobs. Use for work longer than the client timeout.',
    { code: 'MATLAB statements; newlines are stripped, use @@NL@@', codeFile: 'Path to a .m text file, or ""', tag: 'Label' }],
  evaluate_logged: ['Evaluate and log full output',
    'Evaluate code and write all command-window output to exports/eval_<time>.log, printing the path and the last lines. Use when output may exceed the client cut.',
    { code: 'One line only unless @@NL@@ marks breaks; "" when codeFile is used', codeFile: 'UTF-8 file with the multi-line code; "" when code is used' }],
  submit_sweep: ['Submit a parameter sweep',
    'Submit one job per parameter set from a JSON array of argument arrays and return a sweep id.',
    { scriptPath: '.m function', paramsJsonArray: 'JSON array of argument arrays', tag: 'Label', numWorkers: 'Workers per job', gpu: 'true for GPU pool', attachedFiles: 'JSON array of files' }],
  sweep_status: ['Sweep progress', 'Print per-case states and counts for a sweep id.',
    { sweepId: 'id from submit_sweep', tail: 'Log lines per case' }],
  cancel_sweep: ['Cancel a sweep', 'Cancel every unfinished job in a sweep. Needs confirm="yes".',
    { sweepId: 'id to cancel', confirm: 'Literal "yes"' }],
  probe_gpu: ['Probe GPU', 'Report CUDA devices and, on request, time a small array operation.',
    { enable: 'true also runs a timed kernel', samples: 'Repeat count' }],
  gpu_probe: ['Probe GPU', 'Report CUDA devices plus optional timed single and parallel GPU checks, and whether gpuArray is usable.',
    { enable: 'true runs the timed checks', samples: 'Repeat count for timings' }],
  gpu_mc: ['GPU monte-Carlo batch',
    'Run a user function on GPU over a vectorised batch and print summary statistics of the returned samples.',
    { funPath: '.m returning samples, vectorised over N', specJson: '{"n":...,"params":{...},"seed":...}' }],
  file_op: ['File read/write/inspect',
    'One file tool: read|tail|write|append|list|delete|copy|stat|json|find|sub. tail/read page with next_cursor; json validates and points at an unescaped quote; sub replaces only when the occurrence count matches and keeps a .bak.',
    { action: 'read|tail|write|append|list|delete|copy|stat|json|find|sub', target: 'File or folder path', optsJson: '{"maxBytes","cursor","encoding","recursive","glob","find","replace","expect","allowQuote","backup","listJson","get","regex"}' }]
};

function apply(file) {
  const before = fs.readFileSync(file, 'utf8');
  const j = JSON.parse(before);
  const missing = [];
  for (const t of j.tools) {
    const e = D[t.name];
    if (!e) { missing.push(t.name); continue; }
    t.title = e[0];
    t.description = e[1];
    const sc = t.inputSchema || t.schema;
    if (!sc || !sc.properties) continue;
    const props = e[2] || {};
    for (const k of Object.keys(sc.properties)) {
      if (props[k]) sc.properties[k].description = props[k];
      else if (!sc.properties[k].description) missing.push(t.name + '.' + k);
      if ('type' in sc.properties[k] && 'description' in sc.properties[k] && Object.keys(sc.properties[k]).filter(x => !['type', 'description'].includes(x)).length) {
        // keep any extra keywords, nothing to do
      }
    }
  }
  if (missing.length) { console.error('NO TEXT FOR: ' + missing.join(', ')); process.exit(1); }
  fs.writeFileSync(file, JSON.stringify(j, null, 2));
  const after = fs.statSync(file).size;
  // contract re-check
  const bad = [];
  const k2 = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const t of k2.tools) {
    const sc = t.inputSchema || t.schema || {};
    const ord = (k2.signatures[t.name] && k2.signatures[t.name].input && k2.signatures[t.name].input.order) || [];
    if (JSON.stringify(sc.required || []) !== JSON.stringify(ord)) bad.push(t.name + ' required!=order');
    if (sc.additionalProperties !== false) bad.push(t.name + ' additionalProperties');
    for (const p of ord) if (!sc.properties || !sc.properties[p]) bad.push(t.name + ' missing prop ' + p);
    for (const p of Object.keys(sc.properties || {})) if (!sc.properties[p].description) bad.push(t.name + '.' + p + ' no description');
    if (!t.title || !t.description) bad.push(t.name + ' empty title/desc');
  }
  const text = k2.tools.reduce((a, t) => a + t.title.length + t.description.length +
    Object.keys(t.inputSchema.properties || {}).reduce((b, k) => b + (t.inputSchema.properties[k].description || '').length, 0), 0);
  console.log(`${file}: ${before.length} -> ${after} bytes  (described text ${text})  contract: ${bad.length ? bad.join('; ') : 'OK'}`);
}

for (const f of ['mcp-qa-tools.json', 'mcp-jobs.json']) {
  const p = 'C:/Users/ZWS/matlab-mcp-server/extensions/' + f;
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  for (const t of j.tools) if (!D[t.name]) { console.error('unmapped tool: ' + t.name); process.exit(1); }
  apply(p);
}
console.log('total now: ' + (fs.statSync('C:/Users/ZWS/matlab-mcp-server/extensions/mcp-qa-tools.json').size + fs.statSync('C:/Users/ZWS/matlab-mcp-server/extensions/mcp-jobs.json').size) + ' bytes');
