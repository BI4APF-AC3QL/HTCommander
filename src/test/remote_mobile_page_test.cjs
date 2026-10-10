// Runs the real mobile page script against a simulated DOM/audio/socket only.
// No microphone, network, Bluetooth, or radio is opened by this test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../lib/services/web/remote_mobile_page.dart'), 'utf8');
const script = source.split('<script>')[1].split('</script>')[0];
const elements = new Map(), drawCounts = {}, intervals = [];
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    value: id === 'playback' ? '0.8' : '', textContent: '', disabled: false,
    attributes:{},setAttribute(k,v){this.attributes[k]=v;},removeAttribute(k){delete this.attributes[k];},
    handlers: {}, classList: { add() {}, remove() {} },
    addEventListener(name, handler) { this.handlers[name] = handler; },
    replaceChildren(...children) { this.children = children; }, setPointerCapture() {},
    getBoundingClientRect(){return {left:0,top:0,width:512,height:320};},
    getContext(){return {fillRect(){drawCounts[id]=(drawCounts[id]||0)+1;},drawImage(){},beginPath(){},arc(){},fill(){},fillText(){},moveTo(){},lineTo(){},stroke(){}};},
  });
  return elements.get(id);
}
const documentEvents = {}, windowEvents = {};
let resolvePermission, resolveLocation, stopped = 0, processor;
const stream = { getTracks: () => [{ stop() { stopped++; } }] };
const audioNode = () => ({ connect() {}, disconnect() {}, gain: { value: 1 } });
class AudioContext {
  constructor() { this.sampleRate = 48000; this.state = 'running'; this.currentTime = 0; this.destination = {}; }
  async resume() {}
  createGain() { return audioNode(); }
  createMediaStreamSource() { return audioNode(); }
  createScriptProcessor() { processor = audioNode(); return processor; }
  createBuffer(channels,frames){const data=Array.from({length:channels},()=>new Float32Array(frames));return {getChannelData:i=>data[i]};}
  createBufferSource(){return {...audioNode(),start(){},stop(){if(this.onended)this.onended();}};}
}
class WebSocket {
  static OPEN = 1;
  static sockets = [];
  constructor() { this.readyState = 1; this.bufferedAmount = 0; this.sent = []; WebSocket.sockets.push(this); }
  send(data) { this.sent.push(data); }
  close() { this.readyState = 3; }
}
const cards=['radio','aprs','map','audio','more'].map(page=>({dataset:{page},hidden:page!=='radio'}));
const document = { querySelectorAll:()=>cards, hidden: false, getElementById: element, createElement: () => ({}),
  addEventListener: (name, f) => documentEvents[name] = f };
const context = { document, WebSocket, ArrayBuffer, DataView, Float32Array,
  Image: class {static all=[];constructor(){this.constructor.all.push(this);}},
  window: { isSecureContext: true, AudioContext, confirm:()=>true, addEventListener: (name, f) => windowEvents[name] = f },
  location: { protocol: 'https:', host: 'radio.example' },
  navigator: { mediaDevices: { getUserMedia: () => new Promise(r => resolvePermission = r) },geolocation:{getCurrentPosition:callback=>resolveLocation=callback} },
  setInterval(callback,delay) {intervals.push({callback,delay});}, setTimeout() {}, clearTimeout() {}, fetch: async () => ({ redirected: false }),
};
vm.runInNewContext(script, context);
const socket = WebSocket.sockets[0];
const state = { connected: true, audio: true, txAllowed: true, txOwner: null, controlOwner: 1, controlRequests: [],
  settings: { channelA: 0 }, channels: [{ channelId: 0, name: 'Test', rxFreq: 145000000 }] };
function update(owner = null) { socket.onmessage({ data: 'remote:' + JSON.stringify({ clientId: 1, state: { ...state, txOwner: owner } }) }); }
const press = () => element('ptt').handlers.pointerdown({ preventDefault() {}, pointerId: 1 });
const wait = () => new Promise(r => setImmediate(r));
const commands = () => socket.sent.filter(v => typeof v === 'string' && v.startsWith('remote:')).map(v => JSON.parse(v.slice(7)).op);

(async () => {
  const fft=vm.runInNewContext('spectrumDb',context);
  const tone=new Float32Array(1024);for(let i=0;i<1024;i++)tone[i]=.5*Math.sin(2*Math.PI*32*i/1024);
  const bins=fft(tone);const peak=Array.from(bins).indexOf(Math.max(...bins));
  assert.equal(peak,32);assert.ok(Math.abs(bins[32]+6.0206)<.05);
  assert.ok(Array.from(fft(new Float32Array(1024))).every(x=>x===-120));
  assert.throws(()=>fft(new Float32Array(1000)));
  socket.onopen(); update();
  element('menuAprs').onclick();assert.ok(cards.every(c=>c.hidden===(c.dataset.page!=='aprs')));assert.equal(element('menuAprs').attributes['aria-current'],'page');
  element('menuRadio').onclick();assert.equal(element('menuAprs').attributes['aria-current'],undefined);
  state.settings.squelchLevel=5;update();assert.equal(element('squelch').value,5);assert.equal(element('squelch').disabled,false);
  element('squelch').value='7';element('squelch').onchange();assert.equal(commands().at(-1),'squelch');
  state.readOnly=true;update();assert.equal(element('squelch').disabled,true);state.readOnly=false;update();
  state.satellite={enabled:true,observerKnown:true,catalog:[{id:25544,name:'ISS',usages:[{index:0,name:'Voice',downlinkHz:145800000}]}],positions:[{id:25544,azimuthDeg:90,elevationDeg:30,rangeRateKmS:1,fresh:true}]};update();
  assert.equal(element('satelliteStart').disabled,false);element('satelliteStart').onclick();assert.equal(commands().at(-1),'satelliteStart');
  state.satellite.tracking={name:'ISS',remoteClientId:1};state.frequencyModeActive=true;state.frequencyModeHz=145799600;update();assert.equal(element('frequency').textContent,'145.79960 MHz');assert.equal(element('ptt').disabled,true);delete state.satellite.tracking;state.frequencyModeActive=false;update();
  state.satellite.positions[0].fresh=false;update();assert.equal(element('satelliteStart').disabled,true);state.satellite={};update();

  assert.ok(element('dashboardRadio').textContent.includes('电台 未知'));
  assert.ok(element('dashboardMessages').textContent.includes('等待 ACK 未知'));
  state.dashboard={radio:{link:'Connected',receiving:true,transmitting:false,scan:true,signalLevel:7,reportAt:'2026-10-03T00:59:52Z',reportAgeSeconds:8,channel:'<img src=x onerror=alert(1)>',channelSource:'report',rxFrequency:144390000},gateway:{enabled:true,link:'Connected (verified)',health:{receivedRf:5,receivedIs:6,toInternet:4,toRfRequested:2,dropped:1,failures:0}},messages:{waiting:2,acknowledged:1,rejected:0,timedOut:0,cancelled:0},clientCount:2,activity:[{time:'2026-10-03T01:00:00Z',clientId:1,action:'volume',result:'accepted',text:'private-message',password:'private-password'}]};update();
  assert.ok(element('dashboardRadio').textContent.includes('接收 中'));
  assert.ok(element('dashboardReport').textContent.includes('8 秒前'));
  assert.ok(element('dashboardChannel').textContent.includes('144.39000 MHz'));
  assert.ok(element('dashboardChannel').textContent.includes('<img'));
  assert.ok(element('dashboardGateway').textContent.includes('已验证连接'));
  assert.ok(element('dashboardTotals').textContent.includes('RF 收到 5'));
  assert.ok(element('dashboardMessages').textContent.includes('等待 ACK 2'));
  assert.ok(element('dashboardClients').textContent.includes('远程连接 2'));
  assert.equal(element('dashboardActivity').children.length,1);
  assert.ok(!element('dashboardActivity').children[0].textContent.includes('private'));
  state.dashboard.radio={link:'Disconnected',reportAt:null,reportAgeSeconds:null,signalLevel:null};state.dashboard.gateway={enabled:false,link:'Disconnected',health:{}};update();
  assert.ok(element('dashboardRadio').textContent.includes('电台 未连接'));
  assert.ok(element('dashboardRadio').textContent.includes('接收 未知'));
  assert.equal(element('dashboardReport').textContent,'上次状态报告时间未知');
  assert.ok(element('dashboardChannel').textContent.includes('频率未知'));
  assert.ok(element('dashboardGateway').textContent.includes('已关闭'));
  state.dashboard={};state.linkDiagnostics={control:{connected:true,rxBytes:1234,framingSkippedBytes:3,writeDelay:{samples:1,lastMs:120,medianMs:120,maxMs:120},failureReason:'readTimeout'},audio:{state:'running',bufferedMs:500,droppedFrames:16000,droppedBlocks:1,feedErrors:2,failureReason:'playbackBacklog',password:'secret'}};update();
  assert.ok(element('linkDiagnostics').children.some(e=>e.textContent.includes('RX 1234 字节')));
  assert.ok(element('linkDiagnostics').children.some(e=>e.textContent.includes('120 / 120 / 120 ms')));
  assert.ok(element('linkDiagnostics').children.some(e=>e.textContent.includes('本机播放积压')));
  assert.ok(!element('linkDiagnostics').children.some(e=>e.textContent.includes('secret')));
  state.linkDiagnostics={control:null,audio:null};update();
  assert.ok(element('linkDiagnostics').children.some(e=>e.textContent.includes('控制通道 未知')));
  state.gatewayMetrics={queueDepth:2,connectionFailures:3,disconnects:1,reconnectAttempts:4,failureReason:'loginTimeout',toInternet:true,toRf:false,rfForwarded:5};
  state.gatewayHealth=[{hour:'2026-10-02T00:00:00Z',receivedRf:6,receivedIs:7,toInternet:8,toRfRequested:2,dropped:3,failures:1}];update();
  assert.ok(element('gatewayLink').textContent.includes('APRS-IS 登录超时'));
  assert.ok(element('gatewayRf').textContent.includes('下行提交 5'));
  assert.ok(element('gatewayHealth').children[0].textContent.includes('RF 收到 6'));
  state.auditEvents=[{time:'2026-10-02T12:00:00Z',clientId:1,action:'aprsMessage',result:'accepted',text:'private-message'}];update();
  assert.ok(element('auditEvents').children[0].textContent.includes('客户端 #1'));
  assert.ok(element('auditEvents').children[0].textContent.includes('请求接受'));
  assert.ok(!element('auditEvents').children[0].textContent.includes('private-message'));
  state.controlOwner=null;update();assert.equal(element('channel').disabled,true);element('controlRequest').onclick();assert.equal(commands().at(-1),'requestControl');
  state.controlRequested=true;state.controlRequests=[1];update();assert.ok(element('controlStatus').textContent.includes('第 1 位'));assert.equal(element('controlRequest').disabled,true);
  state.controlRequested=false;state.controlRequests=[2];state.controlOwner=1;update();assert.equal(element('controlHandoff').children.length,1);
  const handoffButton=name=>element('controlHandoff').children.find(e=>e.textContent===name);
  handoffButton('移交给 #2').onclick();assert.notEqual(commands().at(-1),'handoffControl');handoffButton('取消移交').onclick();assert.equal(element('controlHandoff').children.length,1);
  handoffButton('移交给 #2').onclick();update();handoffButton('确认移交给 #2').onclick();assert.equal(commands().at(-1),'handoffControl');state.controlRequests=[];
  state.readOnly=true;update();assert.equal(element('ptt').disabled,true);assert.equal(element('channel').disabled,true);assert.equal(element('scan').disabled,true);
  state.readOnly=false;state.emergencyStopped=true;update();assert.equal(element('ptt').disabled,true);
  state.emergencyStopped=false;update();
  state.aprsAllowed=true;state.aprsShortcuts={favorites:['BI4APF-7'],templates:[{name:'CQ',text:'CQ test'}]};update();
  const beforeMessage=commands().filter(x=>x==='aprsMessage').length;
  element('aprsFavorite').value='BI4APF-7';element('aprsFavorite').onchange();element('aprsTemplate').value='0';element('aprsTemplate').onchange();
  assert.equal(element('aprsDestination').value,'BI4APF-7');assert.equal(element('aprsText').value,'CQ test');assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage);
  element('aprsSend').handlers.click();assert.equal(element('aprsConfirmation').hidden,false);assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage);
  element('aprsCancel').onclick();assert.equal(element('aprsConfirm').disabled,true);
  element('aprsSend').handlers.click();element('aprsConfirm').onclick();element('aprsConfirm').onclick();assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage+1);
  element('aprsSend').handlers.click();state.controlOwner=null;update();assert.equal(element('aprsConfirm').disabled,true);element('aprsConfirm').onclick();assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage+1);
  state.controlOwner=1;update();element('aprsSend').handlers.click();element('aprsText').value='changed';element('aprsConfirm').onclick();assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage+1);
  element('aprsSend').handlers.click();vm.runInNewContext('pendingAprs.expires=Date.now()-1',context);element('aprsConfirm').onclick();assert.equal(commands().filter(x=>x==='aprsMessage').length,beforeMessage+1);
  state.positionAllowed=true;update();
  const beforePosition=commands().filter(x=>x==='aprsPosition').length;
  element('positionAcquire').onclick();
  resolveLocation({coords:{latitude:31.2,longitude:121.5,accuracy:15},timestamp:Date.now()});
  assert.equal(commands().filter(x=>x==='aprsPosition').length,beforePosition);
  assert.equal(element('positionSend').disabled,false);
  element('positionSend').onclick();element('positionCancel').onclick();
  assert.equal(commands().filter(x=>x==='aprsPosition').length,beforePosition);
  element('positionSend').onclick();element('positionConfirm').onclick();element('positionConfirm').onclick();
  assert.equal(commands().filter(x=>x==='aprsPosition').length,beforePosition+1);
  element('positionSend').onclick();state.positionAllowed=false;update();
  element('positionConfirm').onclick();
  assert.equal(commands().filter(x=>x==='aprsPosition').length,beforePosition+1);
  state.positionAllowed=true;update();element('positionSend').onclick();
  vm.runInNewContext('pendingPosition.expires=Date.now()-1',context);
  element('positionConfirm').onclick();
  assert.equal(commands().filter(x=>x==='aprsPosition').length,beforePosition+1);
  element('positionSend').onclick();document.hidden=true;documentEvents.visibilitychange();
  assert.equal(element('positionConfirm').disabled,true);document.hidden=false;
  await element('installApp').onclick();assert.ok(element('notice').textContent.includes('添加到主屏幕'));
  const project=vm.runInNewContext('mapProject',context),unproject=vm.runInNewContext('mapUnproject',context);
  const point=project(31.2,121.5,8),reverse=unproject(...point,8);
  assert.ok(Math.abs(reverse[0]-31.2)<1e-6&&Math.abs(reverse[1]-121.5)<1e-6);
  state.mapSources=[{id:'test',name:'Test tiles',url:'https://example.invalid/{z}/{x}/{y}',attribution:'Test'}];state.mapSource='test';
  state.mapStations=[{call:'BI4APF-7',lat:31.2,lon:121.5,time:'2026-10-02T12:00:00',track:[]}];update();
  vm.runInNewContext('drawMap()',context);
  assert.ok(vm.runInNewContext('mapLoads',context)<=8);
  assert.ok(vm.runInNewContext('mapTiles.size',context)<=64);
  element('mapStationList').children[0].onclick();
  assert.equal(element('aprsDestination').value,'BI4APF-7');
  for(const image of context.Image.all)if(image.onload)image.onload();
  vm.runInNewContext('mapDirty=true;drawMap()',context);
  state.aprsMessages=[{id:1,peer:'BI4APF',source:'BI4APF',destination:'AC3QL',incoming:true,text:'<script>hello</script>',sequence:'1',time:'2026-10-02T12:00:00'}];
  update();
  assert.equal(element('aprsUnread').textContent,'（1 条未读）');
  assert.equal(element('aprsMessages').children[1].textContent,'<script>hello</script>');
  element('aprsMessages').children[0].onclick();
  assert.equal(element('aprsDestination').value,'BI4APF');
  element('aprsSearch').value='absent';element('aprsSearch').oninput();
  assert.equal(element('aprsMessages').children.length,0);
  element('aprsSearch').value='';element('aprsSearch').oninput();
  element('aprsRead').onclick();
  assert.equal(element('aprsUnread').textContent,'');
  assert.equal(element('ptt').disabled, false);
  // Releasing while the permission dialog is still pending cannot start TX.
  const cancelled = press(); await wait();
  element('ptt').handlers.pointerup(); resolvePermission(stream); await cancelled;
  assert.equal(commands().includes('pttStart'), false);
  assert.equal(stopped, 1);
  // PCM cannot be forwarded before the host grants exclusive ownership.
  const started = press(); await wait(); resolvePermission(stream); await started;
  assert.equal(commands().at(-1), 'pttStart');
  const event = { inputBuffer: { getChannelData: () => new Float32Array(2048).fill(0.5) } };
  processor.onaudioprocess(event);
  assert.equal(socket.sent.filter(v => v instanceof ArrayBuffer).length, 0);
  update(1); processor.onaudioprocess(event);
  const frames = socket.sent.filter(v => v instanceof ArrayBuffer);
  assert.equal(frames.length, 1);
  const pcm = new DataView(frames[0]);
  assert.equal(pcm.getUint8(0), 0xf2);
  assert.equal(pcm.getUint16(2, true), 32000);
  assert.equal(pcm.getInt16(4, true), 16384);
  assert.ok(frames[0].byteLength > 2700 && frames[0].byteLength < 2800);
  // Backgrounding stops both PTT and the microphone tracks.
  document.hidden = true; documentEvents.visibilitychange();
  assert.equal(commands().at(-1), 'pttStop');
  assert.equal(stopped, 2);
  assert.equal(element('ptt').textContent, '按住讲话');
  document.hidden=false;await element('listen').onclick();
  const received=new ArrayBuffer(4+2048*2),rx=new DataView(received);
  rx.setUint8(0,241);rx.setUint8(1,1);rx.setUint16(2,32000,true);
  for(let i=0;i<2048;i++)rx.setInt16(4+i*2,16384,true);
  for(let i=0;i<100;i++)socket.onmessage({data:received});
  assert.ok(vm.runInNewContext('scheduledAudio.size',context)<=32);
  assert.ok(vm.runInNewContext('audioResets',context)>0);
  await element('listen').onclick();
  assert.equal(vm.runInNewContext('scheduledAudio.size',context),0);
  element('spectrumPause').onclick();assert.equal(element('spectrumPause').textContent,'继续图形');
  // Compare the real page's periodic work over the same simulated 8 seconds.
  let clock=Date.now();context.Date=class extends Date {static now(){return clock;}};
  const poll=intervals.find(i=>i.delay===500&&String(i.callback).includes('lastStatePoll')).callback;
  const cadence=(low,page)=>{
    vm.runInNewContext(`showPage('${page}')`,context);
    element('networkMode').value=low?'low':'normal';element('networkMode').onchange();
    const start=clock;vm.runInNewContext('lastStatePoll=Date.now();lastSpectrumDraw=Date.now();lastMapDraw=Date.now();listening=true;spectrumPaused=false;spectrumCount=1024;',context);
    const before=commands().filter(x=>x==='state').length,spec=drawCounts.spectrum||0,map=drawCounts.stationMap||0;
    for(let t=100;t<=8000;t+=100){clock=start+t;vm.runInNewContext('spectrumDirty=true;mapDirty=true;drawSpectrum();drawMap();',context);if(t%500===0)poll();}
    return {polls:commands().filter(x=>x==='state').length-before,spec:((drawCounts.spectrum||0)-spec),map:((drawCounts.stationMap||0)-map)};
  };
  // Start in low mode: no automatic tile requests, including a new source.
  element('networkMode').value='low';element('networkMode').onchange();
  assert.equal(commands().at(-2),'media');
  const mediaCommand=JSON.parse(socket.sent.filter(v=>typeof v==='string'&&v.startsWith('remote:')).at(-2).slice(7));
  assert.equal(mediaCommand.lowBandwidth,true);
  element('menuMap').onclick();
  const imageCount=context.Image.all.length;
  element('mapSource').onchange();vm.runInNewContext('lastMapDraw=0;drawMap()',context);
  assert.equal(context.Image.all.length,imageCount);
  element('mapRetry').onclick();vm.runInNewContext('lastMapDraw=0;drawMap()',context);
  assert.ok(vm.runInNewContext('mapLoads',context)<=2);
  assert.ok(context.Image.all.length>imageCount);
  for(const image of context.Image.all.slice(imageCount))if(image.onload)image.onload();
  assert.deepEqual(cadence(true,'audio'),{polls:1,spec:16,map:0});
  assert.deepEqual(cadence(false,'audio'),{polls:4,spec:80,map:0});
  assert.deepEqual(cadence(true,'map'),{polls:1,spec:0,map:4});
  assert.deepEqual(cadence(false,'map'),{polls:4,spec:0,map:16});
  element('menuAudio').onclick();
  element('networkMode').value='low';element('networkMode').onchange();socket.onopen();
  assert.ok(socket.sent.some(v=>v==='remote:{"op":"media","lowBandwidth":true}'));
  state.media={lowBandwidth:true,audioPayloadBytes:16004,audioFrames:50,skippedBlocks:1};update();
  assert.ok(element('mediaMetrics').textContent.includes('8 kHz 单声道'));
  assert.ok(element('mediaMetrics').textContent.includes('15.6 KiB'));
  assert.ok(element('mediaMetrics').textContent.includes('主机待发 未知'));
  state.media.hostOutput={queuedPayloadBytes:65536,droppedAudioBlocks:17};update();
  assert.ok(element('mediaMetrics').textContent.includes('主机待发 64.0 KiB'));
  assert.ok(element('mediaMetrics').textContent.includes('主机丢弃旧/积压音频块 17'));
  document.hidden=true;clock+=8000;const noPoll=commands().length;poll();assert.equal(commands().length,noPoll);document.hidden=false;

  // Local microphone testing is available to read-only clients, but never
  // requests PTT, encodes upstream audio, uploads samples or plays echo.
  state.readOnly=true;state.txAllowed=false;state.controlOwner=null;update();
  const binaryBefore=socket.sent.filter(v=>v instanceof ArrayBuffer).length;
  const pttBefore=commands().filter(v=>v==='pttStart').length;
  const testTimers=new Map();let timerId=1000,rejectPermission;
  context.setTimeout=(callback,delay)=>{const id=++timerId;testTimers.set(id,{callback,delay});return id;};
  context.clearTimeout=id=>testTimers.delete(id);
  context.navigator.mediaDevices.getUserMedia=()=>new Promise((r,j)=>{resolvePermission=r;rejectPermission=j;});
  let localTest=element('micTest').onclick();await wait();
  assert.equal(element('ptt').disabled,true);assert.equal(element('micTestStop').disabled,false);
  element('micTestStop').onclick();const cancelledCount=stopped;resolvePermission(stream);await localTest;
  assert.equal(stopped,cancelledCount+1);assert.equal(element('micTestStop').disabled,true);
  // A pending permission response after the watchdog cannot revive the test.
  localTest=element('micTest').onclick();await wait();
  const pendingTimer=Array.from(testTimers.values()).find(t=>t.delay===15000);
  pendingTimer.callback();const expiredCount=stopped;resolvePermission(stream);await localTest;
  assert.equal(stopped,expiredCount+1);
  localTest=element('micTest').onclick();await wait();rejectPermission(Error('secret permission error'));await localTest;
  assert.ok(element('micTestStatus').textContent.includes('许可被拒绝'));
  assert.ok(!element('micTestStatus').textContent.includes('secret'));
  localTest=element('micTest').onclick();await wait();resolvePermission(stream);await localTest;
  processor.onaudioprocess({inputBuffer:{getChannelData:()=>new Float32Array(2048).fill(.5)}});
  assert.ok(element('micTestStatus').textContent.includes('峰值 50%'));
  assert.ok(element('micTestStatus').textContent.includes('RMS 50%'));
  clock+=100;processor.onaudioprocess({inputBuffer:{getChannelData:()=>new Float32Array(2048).fill(1)}});
  assert.ok(element('micTestStatus').textContent.includes('削波 2048'));
  const activeTimer=Array.from(testTimers.values()).find(t=>t.delay===10000);
  const timeoutCount=stopped;activeTimer.callback();assert.equal(stopped,timeoutCount+1);
  assert.equal(processor.onaudioprocess,null);assert.equal(element('micTestStop').disabled,true);
  localTest=element('micTest').onclick();await wait();resolvePermission(stream);await localTest;
  const backgroundCount=stopped;document.hidden=true;documentEvents.visibilitychange();
  assert.equal(stopped,backgroundCount+1);document.hidden=false;
  localTest=element('micTest').onclick();await wait();resolvePermission(stream);await localTest;
  const blurCount=stopped;windowEvents.blur();assert.equal(stopped,blurCount+1);
  localTest=element('micTest').onclick();await wait();resolvePermission(stream);await localTest;
  const hideCount=stopped;windowEvents.pagehide();assert.equal(stopped,hideCount+1);
  // HTTPS restriction and absence of mediaDevices produce fixed local errors.
  context.window.isSecureContext=false;const noHttps=stopped;await element('micTest').onclick();
  assert.ok(element('micTestStatus').textContent.includes('HTTPS'));assert.equal(stopped,noHttps);
  context.window.isSecureContext=true;
  assert.equal(socket.sent.filter(v=>v instanceof ArrayBuffer).length,binaryBefore);
  assert.equal(commands().filter(v=>v==='pttStart').length,pttBefore);
  console.log('Mobile page tests passed: APRS search/reply/unread, FFT tone/silence, bounded playback recovery, microphone cancellation/ownership/resampling/background stop and isolated local-only mic tests, per-connection media preference, tile consent and measured low-bandwidth cadence.');
})().catch(error => { console.error(error); process.exitCode = 1; });
