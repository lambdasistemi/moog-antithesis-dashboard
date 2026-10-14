const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const html = fs.readFileSync('site/index.html', 'utf8');
const context = {
  document: {getElementById: () => ({classList: {add() {}, remove() {}}, addEventListener() {}, value: ''}),
    querySelectorAll: () => [], querySelector: () => null},
  window: {addEventListener() {}}, location: {hash: ''},
  fetch: () => new Promise(() => {}), setInterval() {}, console, Date
};
vm.createContext(context);
vm.runInContext(fs.readFileSync('site/compose.js', 'utf8'), context);
vm.runInContext(html.match(/<script>([\s\S]*)<\/script>/)[1], context);
context.run = {run_id: 'selected-run_42', status: 'completed', directory: 'testnets/example',
  repository: 'owner/repo', commit: 'commit', try: 1, properties: {total: 1, failing: []}};
const row = vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context);
assert.match(row, /href="https:\/\/antithesis-proxy\.plutimus\.com\/browser\/report\/selected-run_42"/,
  'Run rows need the selected public run-ID resolver destination');
assert.match(row, /target="_blank"/);
assert.match(row, /rel="noopener noreferrer"/);
assert.match(row, /referrerpolicy="no-referrer"/);
assert.match(row, /Open report/);
assert.doesNotMatch(row, /antithesis\.com\/report\//);
for (const status of ['in_progress', 'incomplete']) {
  context.run.status = status;
  assert.match(vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context), /\/browser\/report\/selected-run_42/);
}
context.run.status = 'completed';
for (const id of ['', null, 17, '../escape', 'run?redirect=elsewhere', 'run#fragment', 'run/other', 'run\n', 'run\r', 'run\u2028', 'λ', 'x'.repeat(129), 'bad\" onmouseover=\"bad']) {
  context.run.run_id = id;
  const invalid = vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context);
  assert.doesNotMatch(invalid, /href="[^"]*\/browser\/report\//, `Invalid ID became a report destination: ${id}`);
}
context.run.run_id = 'x'.repeat(128);
assert.match(vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context), /\/browser\/report\//);
context.fact = {directory: 'testnets/example', repository:'owner/repo', commit:'commit', try:1, phase:'accepted'};
assert.doesNotMatch(vm.runInContext('testRowHtml({run:null,fact}, "owner/repo")', context), /Open report|\/browser\/report\//);
context.detail = {...context.run, properties: []};
assert.match(vm.runInContext('detailHtml(detail)', context), /\/browser\/report\//);
context.detail.unavailable = true;
assert.match(vm.runInContext('detailHtml(detail)', context), /\/browser\/report\//,
  'Unavailable public property details must not hide the protected report action');
assert.match(html, /href="https:\/\/antithesis-proxy\.plutimus\.com\/browser\/account"[^>]*target="_blank"[^>]*rel="noopener noreferrer"[^>]*referrerpolicy="no-referrer"/);
assert.match(html, /pragma-org\/antithesis-access/);
console.log('Report links validate run identity, isolate navigation and preserve public browsing');
