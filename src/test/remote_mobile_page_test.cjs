// Runs the real mobile page script against a simulated DOM/audio/socket only.
// No microphone, network, Bluetooth, or radio is opened by this test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../lib/services/web/remote_mobile_page.dart'), 'utf8');
const script = source.split('<script>')[1].split('</script>')[0];
const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    value: id === 'playback' ? '0.8' : '', textContent: '', disabled: false,
    handlers: {}, classList: { add() {}, remove() {} },
    addEventListener(name, handler) { this.handlers[name] = handler; },
    replaceChildren(...children) { this.children = children; }, setPointerCapture() {},
  });
  return elements.get(id);
}
const documentEvents = {}, windowEvents = {};
let resolvePermission, stopped = 0, processor;
const stream = { getTracks: () => [{ stop() { stopped++; } }] };
const audioNode = () => ({ connect() {}, disconnect() {}, gain: { value: 1 } });
class AudioContext {
  constructor() { this.sampleRate = 48000; this.state = 'running'; this.currentTime = 0; this.destination = {}; }
  async resume() {}
  createGain() { return audioNode(); }
  createMediaStreamSource() { return audioNode(); }
  createScriptProcessor() { processor = audioNode(); return processor; }
}
class WebSocket {
  static OPEN = 1;
  static sockets = [];
  constructor() { this.readyState = 1; this.bufferedAmount = 0; this.sent = []; WebSocket.sockets.push(this); }
  send(data) { this.sent.push(data); }
  close() { this.readyState = 3; }
}
const document = { hidden: false, getElementById: element, createElement: () => ({}),
  addEventListener: (name, f) => documentEvents[name] = f };
const context = { document, WebSocket, ArrayBuffer, DataView, Float32Array,
  window: { isSecureContext: true, AudioContext, addEventListener: (name, f) => windowEvents[name] = f },
  location: { protocol: 'https:', host: 'radio.example' },
  navigator: { mediaDevices: { getUserMedia: () => new Promise(r => resolvePermission = r) } },
  setInterval() {}, setTimeout() {}, clearTimeout() {}, fetch: async () => ({ redirected: false }),
};
vm.runInNewContext(script, context);
const socket = WebSocket.sockets[0];
const state = { connected: true, audio: true, txAllowed: true, txOwner: null,
  settings: { channelA: 0 }, channels: [{ channelId: 0, name: 'Test', rxFreq: 145000000 }] };
function update(owner = null) { socket.onmessage({ data: 'remote:' + JSON.stringify({ clientId: 1, state: { ...state, txOwner: owner } }) }); }
const press = () => element('ptt').handlers.pointerdown({ preventDefault() {}, pointerId: 1 });
const wait = () => new Promise(r => setImmediate(r));
const commands = () => socket.sent.filter(v => typeof v === 'string' && v.startsWith('remote:')).map(v => JSON.parse(v.slice(7)).op);

(async () => {
  socket.onopen(); update();
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
  console.log('Mobile page tests passed: permission cancellation, ownership gating, PCM resampling and background stop.');
})().catch(error => { console.error(error); process.exitCode = 1; });
