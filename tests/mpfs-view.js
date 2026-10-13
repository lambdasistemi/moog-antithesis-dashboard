const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const captured = {};
const element = id => ({
  set innerHTML(value) { captured[id] = value; },
  set textContent(value) { captured[id] = value; },
  classList: {add() {},remove() {}},addEventListener() {},value:''
});
const context = {
  document:{getElementById:element,querySelectorAll:()=>[],querySelector:()=>null},
  window:{addEventListener() {}},location:{hash:''},
  fetch:()=>new Promise(()=>{}),setInterval(){},console,Date
};
vm.createContext(context);
vm.runInContext(fs.readFileSync('site/index.html','utf8').match(/<script>([\s\S]*)<\/script>/)[1],context);
const time=new Date().toISOString();
const observation={container:{name:'mpfs-compose-mpfs-1',image:'mpfs:v1.3.0',status:'running'},
  api:{reachable:true,http_status:200},synchronization:{status:'observed',ready:true,lag_slots:0}};
context.snapshot={generated_at:time,refresh_seconds:600,runs:[],hosts:{},
  mpfs:{collector:observation,roles:null},
  sources:{mpfs_collector:{status:'ok',last_success:time},mpfs_roles:{status:'error',last_success:null}}};
vm.runInContext('render(snapshot)',context);
assert.match(captured.mpfs || '',/MPFS · collector/,'MPFS is absent from the rendered dashboard');
assert.match(captured.mpfs,/0 slots/);
assert.match(captured.mpfs,/network tip/);
assert.match(captured.mpfs,/issues\/30/);
assert.match(captured.mpfs,/issues\/37/);
context.snapshot.sources.mpfs_collector.status='stale';
vm.runInContext('render(snapshot)',context);
const card=captured.mpfs.match(/data-service="mpfs_collector"[\s\S]*?<\/article>/)[0];
assert.match(card,/chip warn">stale/);
assert.match(card,/Last observed/);
context.snapshot.sources.mpfs_collector={status:'ok',last_success:new Date(Date.now()-16*60*1000).toISOString()};
vm.runInContext('render(snapshot)',context);
assert.match(captured.mpfs,/chip warn">stale/,'stopped reporter displayed healthy');
context.snapshot.sources.mpfs_collector={status:'ok',last_success:time};
context.snapshot.mpfs.collector.api.reachable=false;
context.snapshot.mpfs.collector.synchronization={status:'unmeasured'};
vm.runInContext('render(snapshot)',context);
assert.match(captured.mpfs,/API unreachable/);
assert.match(captured.mpfs,/Synchronization unmeasured/);
console.log('MPFS view distinguishes freshness, container, API and backend-referenced lag');
