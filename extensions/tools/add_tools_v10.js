// Registers the v10 tool layer (self-evolution items 1-5) into the two MATLAB
// MCP extension files. Refuses to write anything on a contract violation.
const fs = require('fs');
const path = require('path');

const EXT = 'C:/Users/ZWS/matlab-mcp-server/extensions';
const QA = path.join(EXT, 'mcp-qa-tools.json');
const JOBS = path.join(EXT, 'mcp-jobs.json');

const newTools = [
  {
    name: 'longrun_preflight',
    title: 'Decide Whether a Long MATLAB Run May Start on This Host',
    description:
      'Read-only host gate before any long certification, sweep or ladder run: prints pid, concurrent ' +
      'MATLAB process count, free/total physical memory, this process CPU seconds, Java heap, then NO-GO ' +
      'reasons. Also scans the repository root for Simulink/cache pollution (slprj, html, derived, gcache, ' +
      '*.slx_autosave) and counts discovered test files. On this 16 GB host a second MATLAB session costs ' +
      'about 1.5 GB and a paged run took 70 minutes, so starting a long job while the gate is red is the ' +
      'single most expensive mistake available. optsJson: {"minFreeMB":2048,"maxMatlabProcs":2,"repoRoot":"",' +
      '"testsDir":"","warnOnly":false}. Prints only; returns nothing.',
    order: ['optsJson'],
    props: {
      optsJson: {
        type: 'string',
        description:
          'JSON object of options, all optional; pass "" for defaults. Keys: minFreeMB, maxMatlabProcs, repoRoot, testsDir, warnOnly.',
      },
    },
  },
  {
    name: 'code_refresh',
    title: 'Make Edited MATLAB Code Take Effect in the Live Session',
    description:
      'Refresh MATLAB code knowledge after editing sources without restarting the session: always runs ' +
      'rehash, and clears cached function definitions when the target tree contains a +package or @class ' +
      'directory (package files are memoized, so a rehash alone keeps running the OLD code - this silently ' +
      'invalidated verifications in the field). Reports file count, total bytes, newest mtime and its age, ' +
      'and can lint the tree afterwards. path may be a folder or a single .m file. optsJson: ' +
      '{"clearFunctions":"auto"|true|false,"lint":true,"pattern":"*.m"}. Prints only; returns nothing.',
    order: ['path', 'optsJson'],
    props: {
      path: {type: 'string', description: 'Absolute folder or .m file whose code must take effect now.'},
      optsJson: {
        type: 'string',
        description:
          'JSON object of options; pass "" for defaults. Keys: clearFunctions (auto|true|false), lint (bool), pattern.',
      },
    },
  },
  {
    name: 'suite_run',
    title: 'Budgeted, Resumable, Evidence-Graded Full-Suite Certification',
    description:
      'Run a repository test suite inside the live MCP session with a TIME BUDGET instead of a timeout, so ' +
      'the call returns cleanly with next=<file> rather than leaving you to guess whether a -32603 meant ' +
      '"not executed" (a timed-out call may still have run, and resending a call with side effects doubles ' +
      'host load). Features: host gate first, shards ordered unit then integration, per-case BEGIN/END ' +
      'appended to a UTC-named log OUTSIDE the repo the moment each event happens, resume by passing the ' +
      'same runId (finished files are skipped, so re-invocation is idempotent), two hard accounts printed as ' +
      'COVERAGE|disk_files=|expect_files=|cases_run=|cases_expect= (files on disk vs counts.json and cases ' +
      'run vs counts.json), tree fingerprint at start and end so a repository edited mid-run is reported as ' +
      'MUTATED and the verdict downgraded, scratch cwd by default so Simulink caches cannot land in the tree, ' +
      'and CERTIFIED|runId|ALL_GREEN only when every condition holds. optsJson keys: testsDir, filePattern, ' +
      'budgetSec (default 45), maxFiles, perCase, stopOnFail, countsJson, keyFiles, keyCases, addPaths, cwd, ' +
      'logDir, runId, clearFunctions, force. Prints only; returns nothing.',
    order: ['repoRoot', 'optsJson'],
    props: {
      repoRoot: {type: 'string', description: 'Absolute repository root; its tests/ tree is the subject.'},
      optsJson: {
        type: 'string',
        description:
          'JSON object of options; pass "" for defaults. Common: {"budgetSec":45,"countsJson":"<repo>/docs/counts.json","keyFiles":"counts.test_files","keyCases":"counts.test_functions","addPaths":["src","app","tools"],"runId":"r..."}.',
      },
    },
  },
  {
    name: 'suite_status',
    title: 'Read a Certification Run Back From Disk',
    description:
      'Slice a suite_run log by its runId and print the trustworthy account: files finished, cases run, ' +
      'failures with diagnostics, the COVERAGE and verdict lines verbatim, which file was in flight when ' +
      'writing stopped, seconds of silence since the last log write, whether the run was started by this ' +
      'PID or another (possibly dead) session, and the remaining files needed to resume. Because MATLAB ' +
      'handles one eval at a time, the fact that this tool answered means no suite_run is executing here, so ' +
      'a missing verdict line means INTERRUPTED rather than slow - it states that explicitly instead of ' +
      'leaving you to infer it. Lines from earlier runs in the same directory are ignored, so a leftover ' +
      'CERTIFIED line can never be read as this run\'s verdict. runId "" or "last" lists recent runs. ' +
      'optsJson: {"logDir":"","tail":12,"showRemaining":true}. Prints only; returns nothing.',
    order: ['runId', 'optsJson'],
    props: {
      runId: {type: 'string', description: 'Run id to inspect (from the suite_run log name). Pass "" to list recent runs.'},
      optsJson: {
        type: 'string',
        description: 'JSON object of options; pass "" for defaults. Keys: logDir, tail, showRemaining.',
      },
    },
  },
  {
    name: 'steps_run',
    title: 'Run a Fixed-Order Closeout Pipeline, Failing Loudly',
    description:
      'Execute an ordered list of closeout steps in one call and abort on the first failure, because the ' +
      'order is load-bearing and skipping a step produces a state that is only self-consistent in the ' +
      'narration: regenerate counts before syncing the number into the docs, regenerate derived tables ' +
      'after editing the text they quote, refresh evidence, re-check the governance locks last. Step kinds: ' +
      'command (MATLAB executed as-is; the generation tools in tools/ are PLAIN functions, so tepc.genCounts() ' +
      'does not resolve), test (one test file, 0 failures required, optional minCases), anchor (a literal ' +
      'string must exist verbatim in a file, with line number and closest candidates when it does not), json ' +
      '(parse and report the suspect character offset for an unescaped ASCII double quote inside a string ' +
      'value, then optionally read a dotted key and compare it), sub (literal replace with an expected ' +
      'occurrence count and a timestamped backup; refuses to insert an ASCII quote into a .json value), ' +
      'exists (size plus freshness in seconds), docsync (a number from a json file must appear verbatim in ' +
      'each listed document). Reports which steps already wrote files, logs every step to disk as it happens, ' +
      'and prints VERDICT|...|ALL_OK only when nothing failed. stepsJson is an array of objects; pass "" ' +
      'with opts {"recipe":"closeout"} to use docs/closeout_steps.json or the built-in order. Prints only; ' +
      'returns nothing.',
    order: ['repoRoot', 'stepsJson', 'optsJson'],
    props: {
      repoRoot: {type: 'string', description: 'Absolute repository root; every relative step path resolves here.'},
      stepsJson: {
        type: 'string',
        description:
          'JSON array of step objects, executed in order: [{"name":"...","kind":"command|test|anchor|json|sub|exists|docsync", ...kind fields}, ...]. Pass "" to use opts.recipe.',
      },
      optsJson: {
        type: 'string',
        description:
          'JSON object of options; pass "" for defaults. Keys: recipe ("closeout"), addPaths (array, e.g. ["tools","src"]), stopOnFail, dryRun, logDir.',
      },
    },
  },
];

const fileOpDesc =
  'Read, write, append, hash, list, tail, stat, validate JSON, literal-search with line numbers, and ' +
  'counted substitute on files and folders through the MCP. read/tail default to the LAST maxBytes window ' +
  'and report next_cursor, because client output is truncated from the front at roughly 44 KB; find proves ' +
  'an evidence anchor exists verbatim in a file or across a tree; json reports the suspect character offset ' +
  'when parsing fails; sub refuses unless the occurrence count equals opts.expect and writes a timestamped ' +
  'backup; delete requires opts.confirm="yes". content must arrive as a JSON string (its \\n escapes survive ' +
  'the bridge; newlines inside the code argument do not). action: read|write|append|hash|list|tail|exists|' +
  'stat|json|find|sub|mkdir|copy|delete. Prints only; returns nothing.';

function validate(tool, sig) {
  const errs = [];
  const req = tool.inputSchema.required || [];
  const order = sig.input.order;
  if (JSON.stringify(req) !== JSON.stringify(order)) {
    errs.push(`required != order for ${tool.name}: ${JSON.stringify(req)} vs ${JSON.stringify(order)}`);
  }
  const props = Object.keys(tool.inputSchema.properties);
  if (JSON.stringify(props.slice().sort()) !== JSON.stringify(order.slice().sort())) {
    errs.push(`properties != order set for ${tool.name}: ${JSON.stringify(props)} vs ${JSON.stringify(order)}`);
  }
  if (tool.inputSchema.additionalProperties !== false) {
    errs.push(`${tool.name}: additionalProperties must be false`);
  }
  for (const p of props) {
    if (!tool.inputSchema.properties[p].description) {
      errs.push(`${tool.name}.${p}: missing description`);
    }
  }
  if (!tool.description || !tool.title) {
    errs.push(`${tool.name}: needs title and description`);
  }
  const fnFile = path.join(EXT, 'functions', tool.name + '.m');
  if (!fs.existsSync(fnFile)) {
    errs.push(`${tool.name}: no functions/${tool.name}.m`);
  }
  return errs;
}

function apply(file, addNames, patchFn) {
  const raw = fs.readFileSync(file, 'utf8');
  const json = JSON.parse(raw);
  const problems = [];
  for (const t of newTools) {
    if (!addNames.includes(t.name)) continue;
    if (json.tools.some((x) => x.name === t.name)) {
      problems.push(`${t.name} already registered in ${path.basename(file)}`);
    }
  }
  if (problems.length) {
    console.log('REFUSE: ' + problems.join('; '));
    process.exitCode = 1;
    return;
  }
  for (const t of newTools) {
    if (!addNames.includes(t.name)) continue;
    const tool = {
      name: t.name,
      title: t.title,
      description: t.description,
      inputSchema: {
        type: 'object',
        properties: Object.fromEntries(t.order.map((p) => [p, t.props[p]])),
        required: t.order.slice(),
        additionalProperties: false,
      },
    };
    const sig = {function: t.name, input: {order: t.order.slice()}};
    const errs = validate(tool, sig);
    if (errs.length) {
      console.log('REFUSE (contract):\n  ' + errs.join('\n  '));
      process.exitCode = 1;
      return;
    }
    json.tools.push(tool);
    json.signatures[t.name] = sig;
  }
  if (patchFn) patchFn(json);
  // final contract sweep over the whole file
  for (const tool of json.tools) {
    const sig = json.signatures[tool.name];
    if (!sig) {
      console.log(`REFUSE: tool ${tool.name} has no signature`);
      process.exitCode = 1;
      return;
    }
    const errs = validate(tool, sig);
    if (errs.length) {
      console.log('REFUSE (contract):\n  ' + errs.join('\n  '));
      process.exitCode = 1;
      return;
    }
  }
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '');
  const bak = file + '.bak-v10-' + stamp;
  fs.writeFileSync(bak, raw);
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + '\n');
  // prove the written file re-parses and still satisfies the contract
  const back = JSON.parse(fs.readFileSync(file, 'utf8'));
  const names = back.tools.map((x) => x.name);
  console.log(
    `wrote ${path.basename(file)}: ${names.length} tool(s), backup ${path.basename(bak)}, ` +
      `added ${addNames.filter((n) => names.includes(n)).join(', ')}`
  );
}

apply(QA, ['longrun_preflight', 'code_refresh', 'suite_run', 'suite_status', 'steps_run']);
apply(JOBS, [], (json) => {
  const t = json.tools.find((x) => x.name === 'file_op');
  if (!t) {
    console.log('REFUSE: file_op not found in mcp-jobs.json');
    process.exitCode = 1;
    return;
  }
  t.description = fileOpDesc;
  t.title = 'File Primitives With Bounded Output';
});
console.log('done');
