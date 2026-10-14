const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync('site/preferences.js', 'utf8');
function visit(storage, unavailable = false) {
  const classes = new Set();
  const root = {dataset: {}, classList: {toggle(name, on) { if (on) classes.add(name); else classes.delete(name); }}};
  const systemTheme = {matches: false, addEventListener(_, callback) { this.change = callback; }};
  const tabs = ['tests', 'pipeline', 'mpfs', 'accounts', 'alarms'].map(pane => ({
    dataset: {pane}, handlers: {}, attributes: {},
    addEventListener(key, callback) { this.handlers[key] = callback; },
    setAttribute(key, value) { this.attributes[key] = value; },
    focus() { this.focused = true; }
  }));
  const control = {handlers: {}, addEventListener(key, callback) { this.handlers[key] = callback; }};
  let ready;
  const context = {matchMedia: () => systemTheme, document: {documentElement: root, querySelectorAll: () => tabs,
    getElementById: () => control, addEventListener: (_, callback) => { ready = callback; }},
    localStorage: {
      getItem(key) { if (unavailable) throw Error('Storage denied'); return storage[key] ?? null; },
      setItem(key, value) { if (unavailable) throw Error('Quota exceeded'); storage[key] = value; }
    }};
  vm.createContext(context);
  vm.runInContext(source, context);
  ready();
  return {root, tabs, control, context, classes, systemTheme};
}
const storage = {};
let page = visit(storage);
assert.equal(page.root.dataset.pane, 'tests');
assert.equal(page.control.value, 'system');
page.control.value = 'dark';
page.control.handlers.change();
page.tabs[3].handlers.click();
page = visit(storage);
assert.equal(page.root.dataset.theme, 'dark');
assert.equal(page.control.value, 'dark');
assert.equal(page.root.dataset.pane, 'accounts');
assert.equal(page.tabs[3].attributes['aria-selected'], 'true');
assert.deepEqual(page.tabs.map(tab => tab.tabIndex), [-1, -1, -1, 0, -1]);
page.control.value = 'light';
page.control.handlers.change();
assert.equal(visit(storage).root.dataset.theme, 'light');
page.context.DashboardPreferences.openPane('tests', false);
assert.equal(page.root.dataset.pane, 'tests');
assert.equal(visit(storage).root.dataset.pane, 'accounts', 'A run link must not overwrite the saved pane');
let prevented = false;
page.tabs[4].handlers.click();
assert.equal(visit(storage).root.dataset.pane, 'alarms', 'Alarms must persist like every other pane');
page.tabs[4].handlers.keydown({key: 'ArrowRight', preventDefault() { prevented = true; }});
assert.ok(prevented && page.tabs[0].focused);
assert.equal(visit(storage).root.dataset.pane, 'tests');
page.control.value = 'system';
page.control.handlers.change();
assert.equal(visit(storage).root.dataset.theme, undefined);
page = visit({'moog-dashboard.theme': 'invalid', 'moog-dashboard.pane': 'invalid'});
assert.equal(page.root.dataset.pane, 'tests');
assert.equal(page.root.dataset.theme, undefined);
page = visit({}, true);
page.control.value = 'dark';
page.control.handlers.change();
page.tabs[2].handlers.click();
assert.equal(page.root.dataset.theme, 'dark');
assert.equal(page.root.dataset.pane, 'mpfs');
console.log('Theme and pane persist; keyboard, invalid values and unavailable storage work');

page = visit({});
page.systemTheme.matches = true;
page.systemTheme.change();
assert.ok(page.classes.has('wa-dark'), 'System dark mode must also theme the library control');
page.control.value = 'light';
page.control.handlers.change();
page.systemTheme.change();
assert.ok(!page.classes.has('wa-dark'), 'Explicit light overrides a dark system preference');
page.control.value = 'system';
page.control.handlers.change();
assert.ok(page.classes.has('wa-dark'));
page.systemTheme.matches = false;
page.systemTheme.change();
assert.ok(!page.classes.has('wa-dark'));
console.log('Library color scheme follows system changes and respects explicit overrides');
