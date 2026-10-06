// Builds a throwaway repository fixture to exercise suite_run / suite_status /
// steps_run end to end, including deliberately failing cases. Lives inside the
// MCP extension tree, not in any user project, and is deleted after acceptance.
const fs = require('fs');
const path = require('path');

const root = '<REPO_ROOT>/extensions/v10_fixture';
const dirs = ['tests/unit', 'tests/integration', 'docs', 'tools', 'src'];
for (const d of dirs) fs.mkdirSync(path.join(root, d), {recursive: true});

function w(rel, text) {
  const p = path.join(root, rel);
  fs.mkdirSync(path.dirname(p), {recursive: true});
  fs.writeFileSync(p, text, 'utf8');
  console.log('wrote ' + rel + ' (' + Buffer.byteLength(text) + ' bytes)');
}

w('tests/unit/test_alpha.m', `classdef test_alpha < matlab.unittest.TestCase
    methods (Test)
        function addOne(tcase)
            tcase.verifyEqual(1 + 1, 2);
        end
        function roundTrip(tcase)
            tcase.verifyEqual(sum([1 2 3]), 6);
        end
    end
end
`);

w('tests/unit/test_beta.m', `classdef test_beta < matlab.unittest.TestCase
    methods (Test)
        function matrixShape(tcase)
            m = [1 2; 3 4];
            tcase.verifyEqual(size(m), [2 2]);
        end
    end
end
`);

w('tests/integration/test_gamma.m', `classdef test_gamma < matlab.unittest.TestCase
    methods (Test)
        function pipelinePass(tcase)
            tcase.verifyEqual(numel(linspace(0, 1, 11)), 11);
        end
        function pipelineFail(tcase)
            % deliberately wrong on purpose: this fixture must produce a red
            % case so the failure path of suite_run gets measured, not assumed
            tcase.verifyEqual(pi, 3.0, 'AbsTol', 1e-6);
        end
    end
end
`);

w('src/driver.m', `function y = driver(x)
y = x .* 2;
end
`);

w('tools/genCounts.m', `function genCounts()
%GENCOUNTS Plain (non-package) generator, like the repository it imitates.
%   Recomputes test file and test case counts from disk into docs/counts.json.
root = fileparts(fileparts(mfilename('fullpath')));
td = fullfile(root, 'tests');
fl = dir(fullfile(td, '**', 'test_*.m'));
nFiles = 0;
nCases = 0;
for k = 1:numel(fl)
    if fl(k).isdir, continue; end
    nFiles = nFiles + 1;
    txt = fileread(fullfile(fl(k).folder, fl(k).name));
    tok = regexp(txt, 'function\\s+\\w+\\s*\\(', 'tokens');
    nCases = nCases + numel(tok);
end
out = struct('generated', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HHmmss''Z''')), ...
    'counts', struct('test_files', nFiles, 'test_functions', nCases));
fid = fopen(fullfile(root, 'docs', 'counts.json'), 'w');
fwrite(fid, jsonencode(out, 'PrettyPrint', true));
fclose(fid);
fprintf('genCounts: files=%d cases=%d\\n', nFiles, nCases);
end
`);

// Deliberately stale numbers so the docsync step has something real to catch:
// counts.json will be regenerated to files=3 cases=6, README says 572.
w('docs/counts.json', JSON.stringify({generated: '2020-01-01T00:00:00Z', counts: {test_files: 99, test_functions: 572}}, null, 2));
w('README.md', '# Fixture\n\nThe suite has 572 test cases and 99 files.\n');
w('docs/quickstart.md', '# Quickstart\n\nRun the 572 test cases with suite_run.\n');
w('docs/register.json', JSON.stringify({items: [{id: 'A1', reason: 'uses 「」 not ASCII quotes'}]}, null, 2));
w('docs/anchor_target.md', '# Anchors\n\nverbatim-anchor-token-7Q occurs once.\n');

console.log('fixture root: ' + root);
