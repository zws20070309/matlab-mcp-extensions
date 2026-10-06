// Read-only gate for the two MCP registries. Lives in extensions/tools/, so the
// extension root is one level up. Supersedes check_registry_v12.js.
// 1) structural: required is a subset of signatures[name].input.order, every order
//    name has a property, every property has a description, additionalProperties:false,
//    functions/<name>.m exists.
// 2) advertised-keys: every camelCase key quoted inside a tool's description text must
//    appear in that tool's .m file, otherwise the surface promises an option that is
//    parsed-but-unused or absent (measured: warnOnly, stepsFile, stopOnFail, pattern).
// 3) enum parity, three independent ways:
//    c. the property DESCRIPTION and the enum must list the same values. A value the
//       description names but the enum rejects sends a caller straight into a client-side
//       validation error; an enum value the description omits is undiscoverable.
//       Measured after the v11 shortening: 3 of the 4 enum-bearing properties mismatched,
//       worst being capture_app.mode advertising "figure" | "app", neither of which the
//       enum accepts, while hiding exportapp / exportgraphics / screen.
//    a. a dispatch value the .m handles must be reachable through the enum (measured:
//       file_op implemented stat/json/find/sub and its description listed them, but the
//       enum omitted all four, so no client could call them).
//    b. an enum value must be mentioned by the .m.
//    Dispatch values are collected from all three styles present in this code base:
//    case 'v', case {'a','b'}, and strcmp/strcmpi(x, 'v').
const fs = require('fs');
const path = require('path');

const ext = path.join(__dirname, '..');
const root = path.join(ext, 'functions');
const files = ['mcp-qa-tools.json', 'mcp-jobs.json'];
let problems = 0;
let toolsChecked = 0;
let keyChecked = 0;
let enumChecked = 0;

for (const f of files) {
  const p = path.join(ext, f);
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  const sigs = j.signatures || {};
  for (const t of j.tools) {
    toolsChecked++;
    const name = t.name;
    const sch = t.inputSchema || {};
    const req = sch.required || [];
    const props = sch.properties || {};
    const order = (sigs[name] && sigs[name].input && sigs[name].input.order) || [];
    const say = (m) => { console.log('  ' + name + ': ' + m); problems++; };

    for (const r of req) if (!order.includes(r)) say('required name not in order: ' + r);
    for (const o of order) if (!props[o]) say('order name has no property: ' + o);
    for (const k of Object.keys(props)) if (!props[k].description) say('property without description: ' + k);
    if (sch.additionalProperties !== false) say('additionalProperties not false');

    const mPath = path.join(root, name + '.m');
    if (!fs.existsSync(mPath)) { say('no functions/' + name + '.m'); continue; }
    const src = fs.readFileSync(mPath, 'utf8');

    const text = [t.description || '', props.optsJson ? props.optsJson.description : '',
      props.stepsJson ? props.stepsJson.description : '',
      props.testsJson ? props.testsJson.description : '']
      .filter(Boolean).join(' ');
    const cited = new Set();
    const re = /["']([a-z][A-Za-z0-9]{2,})["']/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const key = m[1];
      if (['json', 'true', 'false', 'auto', 'closeout', 'error', 'warning', 'info'].includes(key)) continue;
      cited.add(key);
    }
    for (const key of cited) {
      keyChecked++;
      if (!src.includes(key)) say('description advertises "' + key + '" but functions/' + name + '.m never mentions it');
    }

    const handled = new Set();
    for (const mm of src.matchAll(/case\s+'([a-zA-Z][a-zA-Z0-9_]*)'/g)) handled.add(mm[1]);
    for (const mm of src.matchAll(/case\s*\{([^}]*)\}/g)) {
      for (const q of mm[1].matchAll(/'([a-zA-Z][a-zA-Z0-9_]*)'/g)) handled.add(q[1]);
    }
    for (const mm of src.matchAll(/strcmpi?\s*\([^,]+,\s*'([a-zA-Z][a-zA-Z0-9_]*)'/g)) handled.add(mm[1]);

    for (const [pk, pv] of Object.entries(props)) {
      if (!Array.isArray(pv.enum)) continue;
      const ev = pv.enum.filter((x) => x !== '');
      if (!ev.length) continue;

      // (c) description <-> enum. Independent of the .m, so it always runs.
      const dtxt = String(pv.description || '');
      const named = dtxt.split('|')
        .map((x) => x.replace(/[^A-Za-z]/g, ''))
        .filter((x) => /^[a-z][a-zA-Z]*$/.test(x));
      for (const nmv of named) {
        enumChecked++;
        if (!ev.includes(nmv)) say(pk + " description names '" + nmv + "' but the enum rejects it (a caller following the docs gets a validation error)");
      }
      for (const x of ev) {
        enumChecked++;
        if (!named.includes(x)) say(pk + " enum accepts '" + x + "' but the description never mentions it (undiscoverable)");
      }

      // (a)/(b) code <-> enum. Only meaningful when the .m visibly dispatches on these values.
      const related = [...handled].filter((h) => ev.includes(h));
      if (related.length < Math.min(2, ev.length)) continue;
      for (const h of related) {
        enumChecked++;
        if (!ev.includes(h)) say('code handles ' + pk + "='" + h + "' but the enum omits it (unreachable from a client)");
      }
      for (const x of ev) {
        enumChecked++;
        if (!src.includes(x)) say('enum advertises ' + pk + "='" + x + "' but the .m never mentions it");
      }
    }
  }
}

console.log('tools=' + toolsChecked + ' citedKeys=' + keyChecked + ' enumValues=' + enumChecked + ' problems=' + problems);
console.log(problems === 0 ? 'CONTRACT OK' : 'CONTRACT FAIL');
