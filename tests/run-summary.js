const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const context = {
  document: {getElementById: () => ({classList: {add() {}, remove() {}}, addEventListener() {}, value: ''}),
    querySelectorAll: () => [], querySelector: () => null},
  window: {addEventListener() {}}, location: {hash: ''},
  fetch: () => new Promise(() => {}), setInterval() {}, console, Date
};
vm.createContext(context);
vm.runInContext(fs.readFileSync('site/compose.js', 'utf8'), context);
vm.runInContext(fs.readFileSync('site/index.html', 'utf8').match(/<script>([\s\S]*)<\/script>/)[1], context);
context.run = {run_id: 'summary-test', status: 'completed', properties: {total: 31, passing: 0,
  failing: Array.from({length: 30}, (_, i) => `Praos latency failure ${i}`).concat('Recent software version provided')}};
const row = vm.runInContext('testRowHtml({run, fact:null}, "owner/repo")', context);
assert.match(row, /30 failing/);
assert.doesNotMatch(row, /Praos latency failure/, 'Failure names overwhelm the summary row');
assert.match(row, /1 outside pipeline control/);
context.detail = {run_id: context.run.run_id, status: 'completed', properties: context.run.properties.failing.map(name => ({name, status: 'Failing'}))};
const detail = vm.runInContext('detailHtml(detail)', context);
for (const name of context.run.properties.failing) assert.ok(detail.includes(name), `Expanded detail lost ${name}`);
console.log('Run rows show counts and retain every failure in expanded details');
