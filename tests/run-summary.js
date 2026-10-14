const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const filters = {};
const context = {
  document: {getElementById: id => ({classList: {add() {}, remove() {}}, addEventListener() {}, value: filters[id] || ''}),
    querySelectorAll: () => [], querySelector: () => null},
  window: {addEventListener() {}}, location: {hash: ''},
  fetch: () => new Promise(() => {}), setInterval() {}, console, Date
};
vm.createContext(context);
vm.runInContext(fs.readFileSync('site/compose.js', 'utf8'), context);
vm.runInContext(fs.readFileSync('site/index.html', 'utf8').match(/<script>([\s\S]*)<\/script>/)[1], context);
context.run = {run_id: 'summary-test', status: 'completed', requester:'wolf31o2',platform:'github',repository:'owner/repo',directory:'testnets/example',commit:'shared',try:1,properties: {total: 31, passing: 0,
  failing: Array.from({length: 30}, (_, i) => `Praos latency failure ${i}`).concat('Recent software version provided')}};
const row = vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context);
assert.match(row, /30 failing/);
assert.match(row, /0 passing/);
assert.doesNotMatch(row, /31 reported results/);
assert.doesNotMatch(row, />completed</);
assert.doesNotMatch(row, /Praos latency failure/, 'Failure names overwhelm the summary row');
assert.match(row, /1 outside pipeline control/);
for (const [status, label] of [['incomplete', 'incomplete'], ['in_progress', 'running']]) {
  context.run.status = status;
  const pendingRow = vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context);
  assert.match(pendingRow, new RegExp(`>${label}<`));
  assert.doesNotMatch(pendingRow, /\d+ passing|\d+ failing/);
}
context.run.status = 'completed';
context.detail = {run_id: context.run.run_id, status: 'completed', properties: context.run.properties.failing.map(name => ({name, status: 'Failing'}))};
const detail = vm.runInContext('detailHtml(detail)', context);
for (const name of context.run.properties.failing) assert.ok(detail.includes(name), `Expanded detail lost ${name}`);
context.detail.directory = 'testnets/cardano_amaru';
context.detail.nightly = [{url:'https://github.com/owner/repo/actions/runs/1',day:'2026-10-14',stage:'launch'}];
context.detail.properties[0].description = 'A detailed property explanation';
const foldedDetail = vm.runInContext('detailHtml(detail)', context);
assert.doesNotMatch(foldedDetail, /Nightly Amaru integration|not a nightly testnet run/);
assert.match(foldedDetail, /<details class="property-description"><summary>Description<\/summary>/);
assert.doesNotMatch(foldedDetail, /<details class="property-description"[^>]*\bopen\b/);
context.snapshot = {runs:[
  {requester:'wolf31o2',directory:'testnets/example',commit:'shared',try:1,run_id:'wolf',created_at:'2026-10-14'},
  {requester:'saratomaz',directory:'testnets/example',commit:'shared',try:1,run_id:'sara',created_at:'2026-10-13'},
  {requester:'wolf31o2',directory:'testnets/example',commit:'shared',try:1,run_id:'wolf-repeat',created_at:'2026-10-12'},
  {requester:'wolf31o2',repository:'owner/fork',directory:'testnets/example',commit:'shared',try:1,run_id:'wolf-fork',created_at:'2026-10-11'}
],chain:{recent:[
  {requester:'wolf31o2',directory:'testnets/example',commit:'shared',try:1,phase:'finished'},
  {requester:'saratomaz',directory:'testnets/example',commit:'shared',try:1,phase:'accepted'},
  {requester:'wolf31o2',repository:'owner/fork',directory:'testnets/example',commit:'shared',try:1,phase:'rejected'}
]}};
for (const item of [...context.snapshot.runs,...context.snapshot.chain.recent]) {
  item.platform='github';
  item.repository ||= 'owner/repo';
}
const joined = vm.runInContext('buildTestRows(snapshot)', context);
assert.equal(joined.length, 4);
for (const row of joined) {
  assert.equal(row.fact?.requester, row.run.requester, 'On-chain matching lost requester identity or repeated execution');
  assert.equal(row.fact?.repository, row.run.repository, 'On-chain matching mixed repositories');
}
assert.match(vm.runInContext('testRowHtml({run,fact:null}, "owner/repo", false)', context), /On-chain coverage unavailable/);
assert.match(vm.runInContext('testRowHtml({run,fact:null}, "owner/repo", true)', context), /No matching record/);
filters['flt-result'] = 'passing';
context.run.properties = null;
assert.equal(vm.runInContext('rowMatches({run, fact:null})', context), false, 'Unknown results appear as passing');
context.run.properties = {total: 69, passing: 69, failing: []};
assert.equal(vm.runInContext('rowMatches({run, fact:null})', context), true);
assert.match(vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context), /69 passing · 0 failing/);
console.log('Run rows show counts and retain every failure in expanded details');

context.document.getElementById = id => ({value: id === 'flt-result' ? 'passing' : ''});
for (const [properties, expected] of [
  [null, false],
  [{total: 0, failing: []}, false],
  [{total: 1, failing: ['Recent software version provided']}, false],
  [{total: 2, failing: ['Pipeline assertion']}, false],
  [{total: 2, failing: []}, true],
  [{total: 2, failing: ['Recent software version provided']}, true]
]) {
  context.candidate = {run: {status: 'completed', directory: 'testnets/example', properties}, fact: null};
  assert.equal(vm.runInContext('rowMatches(candidate)', context), expected,
    `Passing filter misclassified ${JSON.stringify(properties)}`);
}
console.log('Passing filter requires measured properties with no pipeline failures');
