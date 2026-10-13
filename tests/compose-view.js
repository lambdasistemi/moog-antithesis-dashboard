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
if (fs.existsSync('site/compose.js')) vm.runInContext(fs.readFileSync('site/compose.js', 'utf8'), context);
vm.runInContext(fs.readFileSync('site/index.html', 'utf8').match(/<script>([\s\S]*)<\/script>/)[1], context);
context.detail = {run_id: 'compose-test', status: 'completed', properties: [],
  compose: {status: 'available', url: 'runs/compose-test/docker-compose.yaml', internal_network: true,
    commit: '0123456789012345678901234567890123456789',
    source_url: 'https://github.com/public-owner/public-repo/blob/0123456789012345678901234567890123456789/testnets/local/docker-compose.yaml'}};
const html = vm.runInContext('detailHtml(detail)', context);
assert.match(html, /<details class="compose-viewer"/, 'Compose viewer is absent from the real run detail renderer');
assert.doesNotMatch(html, /<details class="compose-viewer"[^>]*\bopen\b/);
assert.match(html, /INTERNAL_NETWORK=true/);
assert.match(html, /Download/);
assert.match(html, /Copy/);
const yaml = 'services:\n  node:\n    image: "<img src=x onerror=alert(1)>"\n    environment:\n      INTERNAL_NETWORK: true\n      OTHER: ${OTHER}\n# example\n';
const rendered = context.ComposeViewer.renderYaml(yaml);
assert.match(rendered, /yaml-block/);
assert.match(rendered, /yaml-key/);
assert.match(rendered, /yaml-value/);
assert.match(rendered, /class="yaml-block" data-line="1"><summary>/, 'Nested service YAML does not start folded');
assert.match(rendered, /&lt;img/);
assert.doesNotMatch(rendered, /<img/);
assert.match(rendered, /\$\{OTHER\}/);
context.detail.unavailable = true;
assert.match(vm.runInContext('detailHtml(detail)', context), /compose-viewer/, 'Missing property detail hides an available Compose asset');
context.detail.compose.url = 'https://another-origin.invalid/file.yaml';
assert.doesNotMatch(vm.runInContext('detailHtml(detail)', context), /href="https:\/\/another-origin/);
context.detail.compose = {status: 'unavailable', reason: 'source_unavailable'};
assert.match(vm.runInContext('detailHtml(detail)', context), /Compose source is not available/);
console.log('Compose rendering starts collapsed, shows provenance and safely highlights folded YAML');
