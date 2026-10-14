const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const elements = {};
const el = id => elements[id] ||= {textContent: '', innerHTML: '', value: '',
  classList: {add() {}, remove() {}}, addEventListener() {}, setAttribute() {}};
const now = new Date().toISOString();
const healthy = {generated_at: now, refresh_seconds: 600,
  sources: Object.fromEntries(['runs','chain','token','oracle','agent','proxy','monitor','nightly','wallets','mpfs_collector','mpfs_roles'].map(id => [id, {status:'ok',last_success:now}])),
  monitor: {ok:true,last:'OK'}, proxy:{ready:true},
  hosts:{oracle:[{name:'moog-oracle-1',status:'Up 1 hour'}],agent:[{name:'moog-agent-1',status:'Up 1 hour'}],agent_errors_6h:0},
  mpfs: Object.fromEntries(['collector','roles'].map(role => [role,{container:{status:'running'},api:{reachable:true},synchronization:{ready:true}}]))};
const document = {title:'Moog dashboard',getElementById:el,querySelectorAll:()=>[],querySelector:()=>null};
const context = {document,window:{addEventListener(){}},location:{hash:''},fetch:()=>new Promise(()=>{}),setInterval(){},console,Date};
vm.createContext(context);
vm.runInContext(fs.readFileSync('site/compose.js','utf8'),context);
vm.runInContext(fs.readFileSync('site/index.html','utf8').match(/<script>([\s\S]*)<\/script>/)[1],context);
function show(d) {context.snapshot=d;vm.runInContext('renderHeader(snapshot)',context);}
show(healthy);
assert.equal(el('alarm-count').textContent,'0','The rendered alarm badge must report the current count');
assert.equal(document.title,'Moog dashboard');
assert.match(el('alarms').innerHTML,/No active alarms/);
let d = structuredClone(healthy);
for(const id of ['mpfs_roles','mpfs_collector','monitor']) d.sources[id]={status:'stale',last_success:'2020-01-01T00:00:00Z',error:'producer stale'};
d.monitor.ok=false;
show(d);
assert.equal(el('alarm-count').textContent,'3');
assert.equal(document.title,'(3) Moog dashboard');
assert.match(el('alarms').innerHTML,/producer stale/);
assert.equal((el('alarms').innerHTML.match(/data-alarm=/g)||[]).length,3,'Retained unhealthy values must not create duplicate fresh-health alarms');
show(healthy);
assert.equal(el('alarm-count').textContent,'0');
assert.equal(document.title,'Moog dashboard');
d=structuredClone(healthy);d.proxy.ready=false;d.monitor.ok=false;d.mpfs.roles.api.reachable=false;
show(d);assert.equal(el('alarm-count').textContent,'3');
d=structuredClone(healthy);d.sources.wallets.last_success='2020-01-01T00:00:00Z';
show(d);assert.equal(el('alarm-count').textContent,'1','Expired healthy observations are stale');
d=structuredClone(healthy);d.hosts.agent_errors_6h=2;
show(d);assert.equal(el('alarm-count').textContent,'1');
d=structuredClone(healthy);d.hosts.oracle=[];d.mpfs.collector.synchronization.ready=false;
show(d);assert.equal(el('alarm-count').textContent,'2');
d=structuredClone(healthy);d.runs=[{properties:{failing:['test assertion']}}];d.mpfs.roles.synchronization.lag_slots=999999;
show(d);assert.equal(el('alarm-count').textContent,'0','Test assertions and unruled slot lag are not service alarms');
d=structuredClone(healthy);d.generated_at='2020-01-01T00:00:00Z';
show(d);assert.equal(el('alarm-count').textContent,'1');
vm.runInContext('loadError="Snapshot fetch failed"',context);
show(healthy);assert.equal(el('alarm-count').textContent,'1');
assert.match(el('alarms').innerHTML,/Snapshot fetch failed/);
vm.runInContext('loadError=""',context);
show(null);assert.equal(el('alarm-count').textContent,'1','No initial snapshot is unavailable, never healthy');
d=structuredClone(healthy);d.sources.proxy.error='<img src=x onerror=bad>';d.sources.proxy.status='stale';
show(d);assert.doesNotMatch(el('alarms').innerHTML,/<img/);
assert.match(el('alarms').innerHTML,/&lt;img/);
console.log('Alarms reflect source freshness and current service failures, deduplicate, escape and recover');
