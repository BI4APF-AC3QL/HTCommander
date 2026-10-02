String loginPage(String csrf, {bool failed = false}) =>
    '''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HTCommander 登录</title><style>body{font:18px system-ui;background:#101827;color:#eef4ff;margin:0;padding:8vh 24px}main{max-width:420px;margin:auto}input,button{box-sizing:border-box;width:100%;font:inherit;padding:14px;margin:12px 0;border-radius:10px}button{background:#67d4bc;border:0}small{color:#aabbd3}</style>
<main><h1>HTCommander</h1><p>连接 Windows 电台</p>
${failed ? '<p role="alert">密码错误，请重试 / Incorrect password</p>' : ''}
<form method="post" action="/login"><input type="hidden" name="csrf" value="$csrf">
<label for="password">远程访问密码 / Remote password</label>
<input id="password" name="password" type="password" required autocomplete="current-password" maxlength="1024">
<button>登录 / Sign in</button></form><small>密码在电脑的远程操控设置中配置。</small></main></html>''';

const remoteMobilePage = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>HTCommander 远程操控</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#101827;color:#eef4ff;font:16px system-ui}main{max-width:680px;margin:auto;padding:24px 18px 40px}header{display:flex;align-items:center;justify-content:space-between;gap:16px}h1{font-size:24px}h2{font-size:17px;margin:0 0 14px}.card{background:#1c293d;border:1px solid #33445e;border-radius:16px;padding:18px;margin:16px 0}.muted{color:#adbed5;font-size:14px;line-height:1.6}button,select,input{font:inherit}button,select{border:1px solid #40536f;background:#253752;color:inherit;border-radius:10px;padding:12px;min-height:48px}select{width:100%;margin:8px 0 12px}button{cursor:pointer}button:disabled{opacity:.45;cursor:default}a{color:#7fe3cf}label{display:block;margin:8px 0}.row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.row>*{flex:1}input[type=range]{width:100%;min-height:40px;accent-color:#79ddc7}#ptt{width:100%;min-height:112px;font-size:23px;background:#234c48;border:2px solid #70d7bc;touch-action:none;user-select:none;-webkit-user-select:none}#ptt.active{background:#963849;border-color:#ff849d}#notice{white-space:pre-wrap;color:#ffcea0;min-height:24px}#connection{font-size:14px;color:#79ddc7}#frequency{font:28px ui-monospace,monospace;margin:8px 0}footer{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-top:24px}
</style></head><body><main>
<header><h1>远程电台</h1><span id="connection" role="status">正在连接…</span></header>
<div id="notice" role="alert"></div>
<section class="card"><h2 id="radio">Windows 电台</h2><div id="frequency">— MHz</div><div id="status" class="muted">等待电脑连接电台</div>
<label for="channel">信道 A</label><select id="channel" disabled></select>
<div class="row"><button id="scan" disabled>开启扫描</button><button id="listen">开启收听</button></div>
<label for="volume">电台音量 <span id="volumeValue">0</span></label><input id="volume" type="range" min="0" max="15" step="1" disabled>
<label for="playback">手机播放音量</label><input id="playback" type="range" min="0" max="1" value="0.8" step="0.05">
<label for="audioBuffer">音频起始缓冲（毫秒）</label><input id="audioBuffer" type="range" min="80" max="300" value="120" step="20"><p class="muted">较小缓冲延迟低，较大缓冲适合网络抖动；积压超过半秒会清理旧音频。</p>
</section>
<section class="card"><h2>按住讲话 / PTT</h2><p id="txHint" class="muted">电脑需启用远程发射与“允许发射”。手机麦克风需要 HTTPS。</p><button id="ptt" disabled>按住讲话</button><p class="muted">松手、切到后台或断线即停止。连续讲话上限 60 秒。</p></section>
<section class="card"><h2>APRS 消息</h2><label for="aprsDestination">目标呼号 / SSID</label><input id="aprsDestination" maxlength="9" placeholder="CALL-7" autocomplete="off"><label for="aprsText">消息（最多 67 个 ASCII 字符）</label><input id="aprsText" maxlength="67" autocomplete="off"><button id="aprsSend" disabled>提交 APRS 消息</button><p class="muted">需电脑端授权 APRS 发送和允许发射。提交不等于对方收到；请勿重复点击。</p></section>
<section class="card"><h2>APRS 发送状态</h2><div id="aprsDeliveries" aria-live="polite"></div><p class="muted">等待确认表示已交给电脑发送流程，不代表射频发射成功。最多尝试三次；断线或撤销权限后取消。</p></section>
<section class="card"><h2>APRS 会话 <span id="aprsUnread"></span></h2><label for="aprsSearch">搜索呼号或消息</label><input id="aprsSearch" type="search"><button id="aprsRead">全部标为已读</button><div id="aprsMessages"></div><p class="muted">显示最近 100 条与本台有关的消息。点呼号填写回复目标；未读标记仅用于当前页面。</p></section>
<section class="card"><h2>APRS 网关诊断</h2><p id="gatewayMetrics">等待电脑数据</p><p class="muted">网络上行队列最多 32 条，30 秒过期；恢复后逐条处理。计数表示软件处理结果，不代表服务器或接收电台已确认。</p></section>
<section class="card"><h2>接收音频频谱 / 瀑布</h2><div class="row"><button id="spectrumPause">暂停图形</button><select id="spectrumRange" aria-label="频谱范围"><option value="4000">0–4 kHz</option><option value="8000" selected>0–8 kHz</option><option value="16000">0–16 kHz</option></select></div><label for="spectrumGain">显示增益（dB）</label><input id="spectrumGain" type="range" min="0" max="60" value="0"><canvas id="spectrum" width="512" height="128" style="width:100%" aria-label="接收音频频谱"></canvas><canvas id="waterfall" width="512" height="128" style="width:100%" aria-label="接收音频瀑布图"></canvas><p id="audioMetrics" class="muted">开启收听后显示。音频频谱不是射频扫频。</p></section>
<section class="card"><h2>APRS 地图</h2><label for="mapSource">地图源（当前手机）</label><select id="mapSource"></select><div class="row"><button id="mapZoomIn">放大＋</button><button id="mapZoomOut">缩小－</button></div><canvas id="stationMap" width="512" height="320" style="width:100%;touch-action:none" aria-label="APRS 台站地图，可拖动"></canvas><p id="mapAttribution" class="muted"></p><label for="mapSearch">查找当前视野呼号</label><input id="mapSearch" type="search" maxlength="9"><div id="mapStationList"></div><p id="mapInfo" class="muted">等待位置。灰色标记表示超过 30 分钟未更新；24 小时后清理。</p></section>
<footer><a href="/index.html">完整界面 · 地图/APRS</a><button id="logout">退出登录</button></footer>
</main><script>
'use strict';
const $=id=>document.getElementById(id);
let socket,clientId=-1,state={},channels=[],listSignature='',retry=null,failed=0;
let audio=null,gain=null,nextAudio=0,listening=false,micStream=null,micNode=null,micSource=null,micMute=null;
let pressed=false,transmitting=false,micPosition=0,selected=-1,micGeneration=0;
let aprsReadThrough=0,aprsMessageSignature='';
let mapLat=31.2,mapLon=121.5,mapZoom=6,mapDirty=true,mapSelected='',mapSourceId='',mapSourceSignature='',mapHits=[],mapDrag=null,mapDragged=false,mapTileErrors=0;
const mapTiles=new Map();let mapLoads=0,mapTileGeneration=0;
function mapProject(lat,lon,z){const scale=256*2**z,s=Math.sin(Math.max(-85.051129,Math.min(85.051129,lat))*Math.PI/180);return [(lon+180)/360*scale,(.5-Math.log((1+s)/(1-s))/(4*Math.PI))*scale];}
function mapUnproject(x,y,z){const scale=256*2**z;return [Math.atan(Math.sinh(Math.PI*(1-2*y/scale)))*180/Math.PI,((x/scale*360)%360+360)%360-180];}
function mapBounds(){const c=mapProject(mapLat,mapLon,mapZoom),sw=mapUnproject(c[0]-256,c[1]+160,mapZoom),ne=mapUnproject(c[0]+256,c[1]-160,mapZoom);return [sw[0],sw[1],ne[0],ne[1]];}
function updateMapState(){
 const sources=state.mapSources||[],signature=JSON.stringify(sources);if(signature!==mapSourceSignature){mapSourceSignature=signature;const selected=mapSourceId||state.mapSource;if(!sources.some(s=>s.id===selected))mapSourceId=state.mapSource||'';else mapSourceId=selected;$('mapSource').replaceChildren(...sources.map(s=>{const o=document.createElement('option');o.value=s.id;o.textContent=s.name;return o;}));$('mapSource').value=mapSourceId;mapTiles.clear();mapTileGeneration++;mapDirty=true;}
 mapDirty=true;const query=$('mapSearch').value.trim().toUpperCase();const rows=(state.mapStations||[]).filter(s=>!query||s.call.includes(query)).slice(0,20).map(s=>{const b=document.createElement('button');b.textContent=s.call+' · '+s.lat.toFixed(3)+', '+s.lon.toFixed(3);b.onclick=()=>{mapSelected=s.call;mapLat=s.lat;mapLon=s.lon;mapDirty=true;$('aprsDestination').value=s.call.replace(/-0$/,'');notice('已定位 '+s.call+' 并填写消息目标。');requestMap();};return b;});$('mapStationList').replaceChildren(...rows);
}
function requestMap(){send({op:'state',mapBounds:mapBounds()});}
function tileImage(source,z,x,y){
 const limit=2**z;if(y<0||y>=limit)return null;x=((x%limit)+limit)%limit;const key=source.id+'/'+z+'/'+x+'/'+y;
 if(mapTiles.has(key))return mapTiles.get(key);if(mapLoads>=8)return null;
 const image=new Image(),generation=mapTileGeneration;image.loaded=false;mapLoads++;
 image.onload=()=>{mapLoads--;if(generation!==mapTileGeneration)return;image.loaded=true;mapDirty=true;};image.onerror=()=>{mapLoads--;if(generation!==mapTileGeneration)return;mapTileErrors++;mapDirty=true;};
 mapTiles.set(key,image);while(mapTiles.size>64)mapTiles.delete(mapTiles.keys().next().value);
 const url=source.url.replaceAll('{z}',z).replaceAll('{x}',x).replaceAll('{y}',y).replaceAll('{s}','a');
 if(!/^https:\/\//i.test(url)){mapLoads--;mapTileErrors++;return image;}image.src=url;return image;
}
function drawMap(){
 if(document.hidden||!mapDirty)return;mapDirty=false;const canvas=$('stationMap'),ctx=canvas.getContext('2d');if(!ctx)return;
 const source=(state.mapSources||[]).find(s=>s.id===mapSourceId);ctx.fillStyle='#101827';ctx.fillRect(0,0,512,320);const center=mapProject(mapLat,mapLon,mapZoom),left=center[0]-256,top=center[1]-160;
 if(source){$('mapAttribution').textContent=source.attribution;for(let x=Math.floor(left/256);x<=Math.floor((left+512)/256);x++)for(let y=Math.floor(top/256);y<=Math.floor((top+320)/256);y++){const tile=tileImage(source,mapZoom,x,y);if(tile&&tile.loaded)ctx.drawImage(tile,x*256-left,y*256-top,256,256);}}
 const clusters=new Map();mapHits=[];for(const station of state.mapStations||[]){const p=mapProject(station.lat,station.lon,mapZoom),world=256*2**mapZoom;let x=p[0]-left;if(x>world/2+256)x-=world;if(x<-world/2+256)x+=world;const y=p[1]-top;if(x<0||x>512||y<0||y>320)continue;const key=Math.floor(x/40)+','+Math.floor(y/40);if(!clusters.has(key))clusters.set(key,[]);clusters.get(key).push({station,x,y});}
 for(const items of clusters.values()){const {station,x,y}=items[0];const stale=Date.now()-Date.parse(station.time)>1800000;ctx.fillStyle=stale?'#929da9':'#79ddc7';ctx.beginPath();ctx.arc(x,y,items.length>1?14:7,0,Math.PI*2);ctx.fill();ctx.fillStyle='#eef4ff';ctx.fillText(items.length>1?String(items.length):station.call,x+9,y-8);mapHits.push({x,y,items});
  if(station.call===mapSelected){ctx.strokeStyle='#ffcea0';ctx.beginPath();for(let i=0;i<(station.track||[]).length;i++){const p=mapProject(station.track[i][0],station.track[i][1],mapZoom);if(i===0)ctx.moveTo(p[0]-left,p[1]-top);else ctx.lineTo(p[0]-left,p[1]-top);}ctx.stroke();}}
 $('mapInfo').textContent='视野内 '+(state.mapStations||[]).length+' 台 · 缩放 '+mapZoom+' · 瓦片缓存 '+mapTiles.size+'/64 · 瓦片失败 '+mapTileErrors+'。灰色表示位置超过 30 分钟。';if(mapLoads)mapDirty=true;
}
const spectrumSamples=new Float32Array(1024),scheduledAudio=new Set();
let spectrumCursor=0,spectrumRate=32000,spectrumCount=0,spectrumPaused=false,audioResets=0,audioClips=0,audioPeak=0,spectrumDirty=false;
// Hann-windowed radix-2 FFT. All storage and canvas dimensions are bounded.
function spectrumDb(samples){
 const n=samples.length;if(n<2||(n&(n-1)))throw Error('FFT requires power-of-two samples');
 const real=new Float64Array(n),imag=new Float64Array(n);let windowSum=0;
 for(let i=0;i<n;i++){const w=.5-.5*Math.cos(2*Math.PI*i/(n-1));real[i]=samples[i]*w;windowSum+=w;}
 for(let i=1,j=0;i<n;i++){let bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){const t=real[i];real[i]=real[j];real[j]=t;}}
 for(let length=2;length<=n;length*=2){const angle=-2*Math.PI/length;for(let start=0;start<n;start+=length){for(let j=0;j<length/2;j++){const c=Math.cos(angle*j),s=Math.sin(angle*j),a=start+j,b=a+length/2,tr=real[b]*c-imag[b]*s,ti=real[b]*s+imag[b]*c;real[b]=real[a]-tr;imag[b]=imag[a]-ti;real[a]+=tr;imag[a]+=ti;}}}
 const db=new Float32Array(n/2);for(let i=0;i<db.length;i++)db[i]=20*Math.log10(Math.max(1e-6,Math.hypot(real[i],imag[i])*(i===0?1:2)/windowSum));return db;
}
function feedSpectrum(buffer,rate){
 if(rate!==spectrumRate){spectrumSamples.fill(0);spectrumCursor=0;spectrumCount=0;spectrumRate=rate;}
 const samples=buffer.getChannelData(0);audioPeak=0;
 for(const x of samples){spectrumSamples[spectrumCursor]=x;spectrumCursor=(spectrumCursor+1)%1024;spectrumCount=Math.min(1024,spectrumCount+1);audioPeak=Math.max(audioPeak,Math.abs(x));if(Math.abs(x)>=.999)audioClips++;}spectrumDirty=true;
}
function stopPlayback(){for(const source of scheduledAudio){try{source.stop();}catch(_){}}scheduledAudio.clear();nextAudio=0;}
function drawSpectrum(){
 if(document.hidden||spectrumPaused||!listening||!spectrumDirty||spectrumCount<1024)return;spectrumDirty=false;
 const samples=new Float32Array(1024);for(let i=0;i<1024;i++)samples[i]=spectrumSamples[(spectrumCursor+i)%1024];const db=spectrumDb(samples);
 const canvas=$('spectrum'),waterfall=$('waterfall'),ctx=canvas.getContext('2d'),wc=waterfall.getContext('2d');if(!ctx||!wc)return;
 const maxHz=Math.min(spectrumRate/2,Number($('spectrumRange').value)||8000),boost=Number($('spectrumGain').value)||0;
 ctx.fillStyle='#101827';ctx.fillRect(0,0,512,128);ctx.strokeStyle='#79ddc7';ctx.beginPath();wc.drawImage(waterfall,0,0,512,127,0,1,512,127);
 for(let x=0;x<512;x++){const bin=Math.min(db.length-1,Math.floor(x/512*maxHz*1024/spectrumRate));const level=Math.max(0,Math.min(1,(db[bin]+boost+100)/100));const y=128-level*118;if(x===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);wc.fillStyle='hsl('+(240-level*240)+',85%,'+(10+level*55)+'%)';wc.fillRect(x,0,1,1);}ctx.stroke();ctx.fillStyle='#adbed5';ctx.fillText('0 Hz',4,125);ctx.fillText((maxHz/1000)+' kHz',455,125);
 $('audioMetrics').textContent='峰值 '+(audioPeak?20*Math.log10(audioPeak):-120).toFixed(1)+' dBFS · 削波样本 '+audioClips+' · 缓冲恢复 '+audioResets+' · 排队 '+scheduledAudio.size+' · 图形 10 Hz';
}
function renderMessages(){
 const messages=state.aprsMessages||[];const query=$('aprsSearch').value.trim().toUpperCase();
 const unread=messages.filter(e=>e.incoming&&e.id>aprsReadThrough).length;
 $('aprsUnread').textContent=unread?'（'+unread+' 条未读）':'';
 const signature=JSON.stringify([messages,query,aprsReadThrough,state.aprsDeliveries]);if(signature===aprsMessageSignature)return;aprsMessageSignature=signature;
 const rows=[];for(const e of messages.slice().reverse()){
  if(query&&!(e.peer+' '+e.text).toUpperCase().includes(query))continue;
  const peer=document.createElement('button');peer.textContent=(e.incoming&&e.id>aprsReadThrough?'● ':'')+e.peer+' · '+(e.incoming?'收到':'提交');peer.onclick=()=>{$('aprsDestination').value=e.peer;notice('已填写回复目标，请编辑消息后发送。');};
  const text=document.createElement('p');text.textContent=e.text;
  const stamp=document.createElement('small');const delivery=(state.aprsDeliveries||[]).find(d=>d.source===e.source&&d.destination===e.destination&&d.sequence===e.sequence);stamp.textContent=e.time+(e.viaInternet?' · APRS-IS':' · RF')+(delivery?' · '+delivery.status:'');rows.push(peer,text,stamp);
 }$('aprsMessages').replaceChildren(...rows);
}
function notice(text){$('notice').textContent=text||'';}
function send(op){if(socket&&socket.readyState===WebSocket.OPEN){socket.send(typeof op==='string'?op:'remote:'+JSON.stringify(op));return true;}return false;}
function stopPtt(){pressed=false;transmitting=false;micGeneration++;send({op:'pttStop'});if(micStream)micStream.getTracks().forEach(t=>t.stop());if(micNode)micNode.disconnect();if(micSource)micSource.disconnect();if(micMute)micMute.disconnect();micStream=micNode=micSource=micMute=null;$('ptt').classList.remove('active');$('ptt').textContent='按住讲话';}
function open(){socket=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/websocket.aspx');socket.binaryType='arraybuffer';
 socket.onopen=()=>{failed=0;$('connection').textContent='已连接电脑';requestMap();if(listening)send('audioon');};
 socket.onmessage=event=>{if(typeof event.data!=='string'){playAudio(event.data);return;}
  if(event.data.startsWith('remote:')){const msg=JSON.parse(event.data.slice(7));if(msg.clientId!==undefined)clientId=msg.clientId;if(msg.error){notice(msg.error);stopPtt();}if(msg.state){state=msg.state;render();}}
 };
 socket.onclose=async()=>{stopPtt();stopPlayback();state={};render();$('connection').textContent='连接中断，正在重连';failed++;if(failed>=3){try{const r=await fetch('/remote.html',{cache:'no-store'});if(r.redirected){location.href='/login';return;}}catch(_){}}clearTimeout(retry);retry=setTimeout(open,3000);};
 socket.onerror=()=>socket.close();
}
function render(){
 updateMapState();
 const g=state.gatewayMetrics||{};$('gatewayMetrics').textContent='排队 '+(g.queueDepth||0)+' · 过期 '+(g.queueExpired||0)+' · 队列溢出 '+(g.queueOverflow||0)+' · 重复 '+((g.queueDuplicates||0)+(g.duplicateDrops||0))+' · 限速丢弃 '+(g.rateDrops||0)+' · 写入错误 '+(g.sendErrors||0);
 renderMessages();
 const labels={waiting:'等待 ACK',acknowledged:'已确认',rejected:'对方拒收',timedOut:'确认超时',cancelled:'已取消'};
 $('aprsDeliveries').replaceChildren(...(state.aprsDeliveries||[]).slice(-20).reverse().map(e=>{const row=document.createElement('p');row.textContent=e.destination+' · '+(labels[e.status]||e.status)+' · 尝试 '+e.attempts+'/3 · 序号 '+e.sequence;return row;}));
 $('aprsSend').disabled=state.connected!==true||state.aprsAllowed!==true||state.txOwner!=null||state.readOnly||state.emergencyStopped;
 const connected=state.connected===true;const s=state.settings||{};channels=state.channels||[];
 const sig=JSON.stringify(channels);if(sig!==listSignature){listSignature=sig;$('channel').replaceChildren(...channels.map(c=>{const o=document.createElement('option');o.value=c.channelId;o.textContent=(c.channelId+1)+' · '+(c.name||'未命名')+' · '+((c.rxFreq||0)/1e6).toFixed(5);return o;}));}
 selected=s.channelA??-1;$('channel').value=String(selected);$('channel').disabled=!connected||state.txOwner!=null||state.readOnly||state.emergencyStopped;
 const c=channels.find(c=>c.channelId===selected);$('frequency').textContent=c?((c.rxFreq||0)/1e6).toFixed(5)+' MHz':'— MHz';
 $('status').textContent=!connected?'请先在 Windows 连接电台':(state.audio?'音频通道已连接':'电脑尚未启用电台音频')+(s.scan?' · 扫描中':'');
 $('scan').textContent=s.scan?'停止扫描':'开启扫描';$('scan').disabled=!connected||state.txOwner!=null||state.readOnly||state.emergencyStopped;
 $('volume').disabled=!connected||state.txOwner!=null||state.readOnly||state.emergencyStopped;if(document.activeElement!==$('volume'))$('volume').value=state.volume||0;$('volumeValue').textContent=state.volume||0;
 const own=state.txOwner===clientId;const ready=connected&&state.audio&&state.txAllowed&&window.isSecureContext&&!state.readOnly&&!state.emergencyStopped;
 $('ptt').disabled=!ready||(state.txOwner!=null&&!own);
 $('txHint').textContent=state.emergencyStopped?'Windows 已紧急停止远程控制。':state.readOnly?'此客户端为只读；由 Windows 主机授予控制权。':!window.isSecureContext?'手机麦克风需要 HTTPS 地址；当前可控制与收听。':!state.txAllowed?'请在电脑启用远程发射和“允许发射”。':!state.audio?'请在电脑启用电台音频。':(state.txOwner!=null&&!own)?'其他客户端正在讲话。':'按住按钮讲话，松手停止。';
 if(pressed&&own){transmitting=true;$('ptt').classList.add('active');$('ptt').textContent='正在发射 · 松手停止';}else if(transmitting&&!own){stopPtt();notice('发射已停止。');}
}
async function context(){if(!audio){audio=new (window.AudioContext||window.webkitAudioContext)({sampleRate:32000});gain=audio.createGain();gain.gain.value=Number($('playback').value);gain.connect(audio.destination);}await audio.resume();return audio;}
function playAudio(data){if(!listening||!audio||audio.state!=='running')return;const v=new DataView(data);if(v.byteLength<6||v.getUint8(0)!==241)return;const n=v.getUint8(1),rate=v.getUint16(2,true);if(n<1||n>2||rate<8000||rate>48000)return;const frames=Math.floor((v.byteLength-4)/(2*n));if(!frames)return;const b=audio.createBuffer(n,frames,rate);for(let ch=0;ch<n;ch++){const a=b.getChannelData(ch);for(let i=0;i<frames;i++)a[i]=v.getInt16(4+(i*n+ch)*2,true)/32768;}
 feedSpectrum(b,rate);const now=audio.currentTime;if(nextAudio<now||nextAudio>now+.5||scheduledAudio.size>=32){if(scheduledAudio.size){audioResets++;stopPlayback();}nextAudio=now+Math.max(.08,Math.min(.3,(Number($('audioBuffer').value)||120)/1000));}const source=audio.createBufferSource();source.buffer=b;source.connect(gain);scheduledAudio.add(source);source.onended=()=>{scheduledAudio.delete(source);source.disconnect();};source.start(nextAudio);nextAudio+=frames/rate;
}
async function prepareMic(){const ctx=await context();if(!pressed)return false;if(micStream)return true;if(!window.isSecureContext||!navigator.mediaDevices)throw Error('麦克风需要 HTTPS');const generation=++micGeneration;
 const stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true},video:false});if(!pressed||generation!==micGeneration){stream.getTracks().forEach(t=>t.stop());return false;}micStream=stream;micSource=ctx.createMediaStreamSource(micStream);micNode=ctx.createScriptProcessor(2048,1,1);micMute=ctx.createGain();micMute.gain.value=0;micSource.connect(micNode);micNode.connect(micMute);micMute.connect(ctx.destination);
 micNode.onaudioprocess=event=>{if(!transmitting||!pressed||socket.readyState!==WebSocket.OPEN)return;if(socket.bufferedAmount>32768){stopPtt();notice('网络发送积压，已停止发射。');return;}const input=event.inputBuffer.getChannelData(0);const step=ctx.sampleRate/32000;const values=[];for(;micPosition<input.length;micPosition+=step){const j=Math.floor(micPosition);const fraction=micPosition-j;values.push(input[j]*(1-fraction)+(input[Math.min(j+1,input.length-1)]||0)*fraction);}micPosition-=input.length;const frame=new ArrayBuffer(4+values.length*2);const view=new DataView(frame);view.setUint8(0,242);view.setUint8(1,1);view.setUint16(2,32000,true);values.forEach((x,i)=>view.setInt16(4+i*2,Math.max(-32768,Math.min(32767,Math.round(x*32767))),true));socket.send(frame);};
return true;}
$('ptt').addEventListener('pointerdown',async event=>{event.preventDefault();if(pressed)return;pressed=true;$('ptt').setPointerCapture(event.pointerId);try{if(!await prepareMic()||!pressed)return;micPosition=0;send({op:'pttStart'});}catch(error){stopPtt();notice('麦克风失败：'+error.message);}});
for(const name of ['pointerup','pointercancel','lostpointercapture'])$('ptt').addEventListener(name,()=>stopPtt());
window.addEventListener('blur',stopPtt);document.addEventListener('visibilitychange',()=>{if(document.hidden)stopPtt();});window.addEventListener('pagehide',()=>{stopPtt();if(micStream)micStream.getTracks().forEach(t=>t.stop());});
$('channel').onchange=()=>send({op:'channel',value:Number($('channel').value),vfo:'A'});
$('scan').onclick=()=>send({op:'scan',value:!state.settings?.scan});
$('volume').onchange=()=>send({op:'volume',value:Number($('volume').value)});
$('playback').oninput=()=>{if(gain)gain.gain.value=Number($('playback').value);};
$('spectrumPause').onclick=()=>{spectrumPaused=!spectrumPaused;$('spectrumPause').textContent=spectrumPaused?'继续图形':'暂停图形';};
$('spectrumRange').onchange=()=>{spectrumDirty=true;};$('spectrumGain').oninput=()=>{spectrumDirty=true;};
function mapZoomBy(delta){mapZoom=Math.max(2,Math.min(18,mapZoom+delta));mapDirty=true;requestMap();}
$('mapZoomIn').onclick=()=>mapZoomBy(1);$('mapZoomOut').onclick=()=>mapZoomBy(-1);
$('mapSource').onchange=()=>{mapSourceId=$('mapSource').value;mapTiles.clear();mapTileGeneration++;mapDirty=true;};$('mapSearch').oninput=updateMapState;
$('stationMap').addEventListener('pointerdown',e=>{mapDrag={x:e.clientX,y:e.clientY,c:mapProject(mapLat,mapLon,mapZoom)};mapDragged=false;$('stationMap').setPointerCapture(e.pointerId);});
$('stationMap').addEventListener('pointermove',e=>{if(!mapDrag)return;const r=$('stationMap').getBoundingClientRect(),dx=(e.clientX-mapDrag.x)*512/r.width,dy=(e.clientY-mapDrag.y)*320/r.height;if(Math.abs(dx)+Math.abs(dy)>5)mapDragged=true;[mapLat,mapLon]=mapUnproject(mapDrag.c[0]-dx,mapDrag.c[1]-dy,mapZoom);mapDirty=true;});
$('stationMap').addEventListener('pointerup',e=>{mapDrag=null;if(!mapDragged){const r=$('stationMap').getBoundingClientRect(),x=(e.clientX-r.left)*512/r.width,y=(e.clientY-r.top)*320/r.height;const hit=mapHits.find(h=>Math.hypot(h.x-x,h.y-y)<20);if(hit){const s=hit.items[0].station;mapLat=s.lat;mapLon=s.lon;if(hit.items.length>1)mapZoomBy(1);else{mapSelected=s.call;$('aprsDestination').value=s.call.replace(/-0$/,'');notice('已选择 '+s.call+'，可发送 APRS 消息。');}}}mapDirty=true;requestMap();});
$('stationMap').addEventListener('pointercancel',()=>{mapDrag=null;});setInterval(drawMap,500);
setInterval(drawSpectrum,100);
$('listen').onclick=async()=>{try{await context();listening=!listening;send(listening?'audioon':'audiooff');$('listen').textContent=listening?'停止收听':'开启收听';if(!listening&&audio){gain.gain.value=0;stopPlayback();}else if(gain)gain.gain.value=Number($('playback').value);}catch(error){notice(error.message);}};
$('logout').onclick=async()=>{stopPtt();clearTimeout(retry);await fetch('/logout',{method:'POST'});location.href='/login';};
$('aprsSearch').oninput=renderMessages;
$('aprsRead').onclick=()=>{aprsReadThrough=Math.max(aprsReadThrough,...(state.aprsMessages||[]).map(e=>e.id));renderMessages();};
$('aprsSend').addEventListener('click',()=>{if($('aprsSend').disabled)return;send({op:'aprsMessage',destination:$('aprsDestination').value.trim().toUpperCase(),text:$('aprsText').value});notice('已提交请求，等待电脑处理；这不代表已发射或收到 ACK。');});
setInterval(()=>{if(!document.hidden)requestMap();},2000);open();
</script></body></html>''';
