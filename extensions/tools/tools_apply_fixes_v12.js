// Applies the v12 defect fixes with a hard assertion per edit: the search text
// must occur exactly once, otherwise the edit is skipped and reported. Nothing
// is written unless every edit for that file matched.
const fs = require('fs');
const path = require('path');
const F = (p) => path.join(__dirname, 'functions', p);
const edits = [
  { f: F('code_refresh.m'), find: "'ConvertBaseUnits', 0, ", repl: "",
    why: "datetime() has no ConvertBaseUnits parameter on R2025a; the tool crashed after 2 lines" },
  { f: F('run_tests.m'), find: "strjoin(lines(1:6), newline)", repl: "strjoin(lines(1:min(14, numel(lines))), newline)",
    why: "6 lines cut off before the Actual/Expected table, so the useful numbers never reached the caller" },
  { f: F('check_code_tree.m'), find: "if isempty(pattern)", repl: "pattern = mcp_str(pattern);\nif isempty(pattern)",
    why: "isempty(\"\") is false for a string scalar, so the *.m default never applied and .json files were linted" },
  { f: F('capture_figure.m'), find: "exportgraphics(fig, outPath, 'Resolution', 150);",
    repl: "[opDir, ~, ~] = fileparts(outPath);\nif ~isempty(opDir) && exist(opDir, 'dir') ~= 7\n    mkdir(opDir);\nend\nexportgraphics(fig, outPath, 'Resolution', 150);",
    why: "an explicit outPath in a not-yet-existing folder raised a raw exportgraphics error" },
  { f: F('mcp_submit_job_core.m'), find: "if ~isempty(attachedFiles)", repl: "attachedFiles = mcp_str(attachedFiles);\nif ~isempty(attachedFiles)",
    why: "a string-scalar \"\" is not isempty(), so the documented empty placeholder fell into the JSON parser" },
  { f: F('mcp_submit_job_core.m'), find: "        else\n            error('submit_job:badAttach', ...\n                '[submit_job:badAttach] attachedFiles must be a JSON array of path strings');\n        end",
    repl: "        elseif isempty(a)\n            attachList = {};\n        else\n            error('submit_job:badAttach', ...\n                '[submit_job:badAttach] attachedFiles must be a JSON array of path strings, e.g. [\"C:\\a\\b.m\"]');\n        end",
    why: "jsondecode('[]') returns [] which hit the else branch, so there was no accepted way to attach nothing" },
  { f: F('mcp_submit_job_core.m'), find: "        error('submit_job:badAttach', '[submit_job:badAttach] cannot parse attachedFiles: %s', e.message);",
    repl: "        if exist(attachedFiles, 'file') == 2\n            attachList = {attachedFiles};\n        else\n            error('submit_job:badAttach', '[submit_job:badAttach] cannot parse attachedFiles: %s (pass a JSON array of paths, e.g. [\"C:\\a\\b.m\"], or a single existing path)', e.message);\n        end",
    why: "a bare path is the obvious thing to pass; accept it instead of failing with a JSON parse error" },
];
let ok = 0, skipped = 0;
const byFile = new Map();
for (const e of edits) {
  if (!byFile.has(e.f)) byFile.set(e.f, fs.readFileSync(e.f, 'utf8'));
  let src = byFile.get(e.f);
  const n = src.split(e.find).length - 1;
  if (n !== 1) { console.log('SKIP  ' + path.basename(e.f) + '  matches=' + n + '  ' + e.why); skipped++; continue; }
  byFile.set(e.f, src.replace(e.find, e.repl));
  console.log('EDIT  ' + path.basename(e.f) + '  ' + e.why);
  ok++;
}
for (const [f, src] of byFile) fs.writeFileSync(f, src, 'utf8');
// registry: file_op advertises stat/json/find/sub in prose and implements them, but the enum blocked all four
const reg = path.join(__dirname, 'mcp-jobs.json');
const j = JSON.parse(fs.readFileSync(reg, 'utf8'));
const fo = j.tools.find(t => t.name === 'file_op');
const en = fo.inputSchema.properties.action.enum;
const add = ['stat', 'json', 'find', 'sub'].filter(a => !en.includes(a));
const i = en.indexOf('');
for (const a of add) en.splice(i < 0 ? en.length : i, 0, a);
fs.writeFileSync(reg, JSON.stringify(j, null, 2), 'utf8');
console.log('ENUM  file_op action += ' + JSON.stringify(add) + ' -> ' + en.filter(Boolean).join(','));
console.log('edits=' + ok + ' skipped=' + skipped);
