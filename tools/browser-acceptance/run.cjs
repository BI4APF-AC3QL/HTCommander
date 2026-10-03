const path = require('node:path');
const fs = require('node:fs'), assert = require('node:assert/strict');
const {chromium} = require('playwright');
const os=require('node:os'),{spawn}=require('node:child_process');
const sourceRoot=path.resolve(__dirname,'../..');
const outputParent=process.env.HTC_BROWSER_OUTPUT||path.join(os.tmpdir(),'htc-browser-acceptance');fs.mkdirSync(outputParent,{recursive:true});
const outputRoot=fs.mkdtempSync(path.join(outputParent,'run-'));console.log('Isolated browser evidence: '+outputRoot);
const headless=process.argv.includes('--headless');
const browserChannel=process.env.HTC_BROWSER_CHANNEL||'chromium';
const statusPath=path.join(outputRoot,'status.json'),commandPath=path.join(outputRoot,'command.json');
const state=()=>JSON.parse(fs.readFileSync(statusPath,'utf8'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn,timeout=10000){const start=Date.now();while(Date.now()-start<timeout){if(await fn())return;await sleep(100);}throw Error('Condition timed out');}
async function host(data){await until(()=>!fs.existsSync(commandPath));fs.writeFileSync(commandPath,JSON.stringify(data));await until(()=>!fs.existsSync(commandPath));}
async function bounded(promise,ms){let timer;try{return await Promise.race([promise,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('Browser operation timeout')),ms))]);}finally{clearTimeout(timer);}}
async function main(){
 const log=fs.createWriteStream(path.join(outputRoot,'fixture.log'));
 const env={...process.env,HTC_BROWSER_STATUS:statusPath,HTC_BROWSER_COMMAND:commandPath,HTC_BROWSER_FIXTURE:path.join(__dirname,'host_fixture.dart'),HTC_FLUTTER_BINARY:process.env.HTC_FLUTTER_BINARY||'flutter'};
 const hostProcess=process.platform==='win32'
  ?spawn('powershell.exe',['-NoProfile','-NonInteractive','-Command','& $env:HTC_FLUTTER_BINARY test $env:HTC_BROWSER_FIXTURE --reporter expanded; exit $LASTEXITCODE'],{cwd:path.join(sourceRoot,'src'),env,windowsHide:true})
  :spawn(env.HTC_FLUTTER_BINARY,['test',env.HTC_BROWSER_FIXTURE,'--reporter','expanded'],{cwd:path.join(sourceRoot,'src'),env});
 hostProcess.stdout.pipe(log);hostProcess.stderr.pipe(log);
 let ended=false;const finished=new Promise((resolve,reject)=>{hostProcess.on('error',reject);hostProcess.on('exit',code=>{ended=true;resolve(code);});});
 try{
  await until(()=>{if(ended)throw Error('Fixture failed; inspect fixture.log');return fs.existsSync(statusPath);},60000);
  await exercise();
 }finally{
  if(!ended){fs.writeFileSync(commandPath,JSON.stringify({op:'stop'}));try{await bounded(finished,15000);}catch(_){hostProcess.kill();}}
  log.end();
 }
 assert.equal(await finished,0,'Fixture must close successfully');
}
async function exercise(){

 const profileRoot=path.join(outputRoot,'browser-profiles');fs.mkdirSync(profileRoot,{recursive:true});
 const profileDir=fs.mkdtempSync(path.join(profileRoot,'acceptance-'));
 const context=await chromium.launchPersistentContext(profileDir,{channel:browserChannel,headless,viewport:{width:390,height:844},geolocation:{latitude:31.2,longitude:121.5,accuracy:15},args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-sync','--no-pings']});
 const browser=context.browser();
 const page=await context.newPage();const errors=[],frames=[];
 page.on('pageerror',e=>errors.push(e.message));
 page.on('websocket',ws=>ws.on('framesent',e=>frames.push(e.payload)));
 const base=state().url,evidence={realBrowser:`${browserChannel} ${headless?'headless':'headed'}`,width:390,browserVersion:browser.version(),productionHttpWebSocket:true,physicalRadio:false,physicalMicrophone:false,syntheticBrowserMicrophone:true};
 try{
  await page.goto(base+'/login');await page.locator('input[type=password]').fill('synthetic-test-password');await page.locator('form button').click();
  await until(()=>state().clients.length===1);await page.waitForFunction(()=>state.readOnly===true);
  assert.equal(await page.locator('#ptt').isDisabled(),true);
  await page.locator('#micTest').click();await page.waitForFunction(()=>document.querySelector('#micTestStatus').textContent.includes('本机输入')&&!document.querySelector('#micTestStatus').textContent.includes('峰值 0%'));
  const micText=await page.locator('#micTestStatus').innerText();assert.ok(micText.includes('峰值'));assert.ok(micText.includes('RMS'));
  assert.equal(await page.locator('#ptt').isDisabled(),true);await page.locator('#micTest').locator('xpath=../..').screenshot({path:path.join(outputRoot,'microphone.png')});
  await page.locator('#micTestStop').click();assert.equal(await page.evaluate(()=>micTestStream===null&&micTestNode===null),true);
  await page.locator('#micTest').click();await page.waitForFunction(()=>document.querySelector('#micTestStatus').textContent.includes('本机输入')&&!document.querySelector('#micTestStatus').textContent.includes('峰值 0%'));
  const track=await page.evaluateHandle(()=>micTestStream.getTracks()[0]);
  await page.waitForFunction(()=>!micTestBusy,{},{timeout:14000});assert.equal(await track.evaluate(t=>t.readyState),'ended');
  assert.equal(frames.filter(f=>Buffer.isBuffer(f)).length,0);assert.ok(!frames.some(f=>typeof f==='string'&&f.includes('"op":"pttStart"')));assert.deepEqual(state().events,[]);
  evidence.localMicrophone={status:micText,readonlyAllowed:true,stoppedTrack:true,tenSecondCleanup:true,zeroUpstreamBinary:true,zeroPttStart:true};
  // Use the browser's native permission/geolocation path with synthetic coords.
  const session=await context.newCDPSession(page);const browserCDP=await browser.newBrowserCDPSession();const bcId=(await browserCDP.send('Target.getBrowserContexts')).browserContextIds[0];
  await browserCDP.send('Browser.setPermission',{permission:{name:'geolocation'},setting:'denied',origin:base,browserContextId:bcId});
  await page.locator('#positionAcquire').click();await page.waitForFunction(()=>document.querySelector('#notice').textContent.includes('定位失败'));
  assert.deepEqual(state().events,[]);evidence.locationDeniedNoRequest=true;
  await browserCDP.send('Browser.setPermission',{permission:{name:'geolocation'},setting:'granted',origin:base,browserContextId:bcId});
  await page.locator('#positionAcquire').click();await page.waitForFunction(()=>document.querySelector('#positionPreview').textContent.includes('31.20000'));
  assert.deepEqual(state().events,[]);assert.equal(await page.locator('#positionSend').isDisabled(),true);
  const client=state().clients[0].id;
  await host({op:'role',id:client,readOnly:false});await host({op:'grant',id:client});
  await page.waitForFunction(()=>state.controlOwner===clientId&&!state.readOnly);
  assert.equal(await page.locator('#aprsSend').isDisabled(),true);assert.equal(await page.locator('#ptt').isDisabled(),true);
  await page.locator('#positionAcquire').click();await page.waitForFunction(()=>!document.querySelector('#positionSend').disabled);
  await page.locator('#positionSend').click();await page.locator('#positionCancel').click();assert.deepEqual(state().events,[]);
  await page.locator('#positionSend').click();await host({op:'emergency'});
  await page.waitForFunction(()=>state.emergencyStopped===true);assert.equal(await page.locator('#positionConfirm').isDisabled(),true);assert.deepEqual(state().events,[]);
  await host({op:'resume'});await host({op:'grant',id:client});await page.waitForFunction(()=>!state.emergencyStopped&&state.controlOwner===clientId);
  await page.locator('#positionAcquire').click();await page.waitForFunction(()=>!document.querySelector('#positionSend').disabled);
  await page.locator('#positionSend').click();await page.locator('#positionConfirm').click();
  await until(()=>state().events.length===1);assert.deepEqual(state().events,['TransmitDataFrame']);
  evidence.nativeGeolocation={permissionDeniedAndGranted:true,syntheticCoordinates:true,previewCancelAndEmergencyZeroFrames:true,confirmedMockFrameRequests:1,voiceAndAprsMessageDenied:true};
  // Validate actual browser service-worker/manifest/icon decoding; do not infer
  // a phone installation from this inspection.
  await page.evaluate(()=>navigator.serviceWorker.ready);
  const manifest=await session.send('Page.getAppManifest');
  evidence.pwa={manifestUrl:manifest.url,errors:manifest.errors};assert.equal(manifest.url,base+'/remote.webmanifest');assert.ok(!manifest.errors.some(e=>e.critical));
  try{evidence.pwa.installability=await session.send('Page.getInstallabilityErrors');}catch(e){evidence.pwa.installabilityUnsupported=true;}
  const manifestId=base+'/remote.html';let installed=false;
  try{
   // Install from the authenticated visible page, as the user install path does.
   // Installed-state lookup alone is insufficient: the headed Windows gate
   // must still observe a real standalone application window.
   await bounded(session.send('PWA.install',{manifestId}),30000);installed=true;
   evidence.pwa.installSource='Authenticated current-page native manifest';
   evidence.pwa.installedState=await browserCDP.send('PWA.getOsAppState',{manifestId});
   if(!headless){
    // Register a caught listener before launch. A failed launch must not leave
    // an unhandled page-event promise that bypasses uninstall/cleanup.
    const appPagePromise=context.waitForEvent('page',{timeout:30000}).catch(()=>null);
    const launch=await bounded(browserCDP.send('PWA.launch',{manifestId}),25000);
    const appPage=await appPagePromise;
    if(!appPage)throw Error('No installed application window was observed');
    await appPage.waitForLoadState('domcontentloaded');await appPage.waitForFunction(()=>clientId>0);
    evidence.pwa.launchTarget=launch.targetId;evidence.pwa.appUrl=appPage.url();
    evidence.pwa.standalone=await appPage.evaluate(()=>matchMedia('(display-mode: standalone)').matches);
    assert.equal(evidence.pwa.standalone,true);assert.equal(appPage.url(),manifestId);
    await appPage.screenshot({path:path.join(outputRoot,'standalone.png'),fullPage:true});await appPage.close();
   }else{evidence.pwa.standaloneSkipped='Headless cannot prove an installed application window.';}
  }finally{
   if(installed){await bounded(browserCDP.send('PWA.uninstall',{manifestId}),20000);evidence.pwa.uninstalledAfterTest=true;}
  }
  await page.locator('#fullscreen').click();await page.waitForFunction(()=>document.fullscreenElement!==null);
  evidence.fullscreenEntered=true;await page.locator('#fullscreen').click();await page.waitForFunction(()=>document.fullscreenElement===null);
  evidence.fullscreenExited=true;
  evidence.pwa.icons=await page.evaluate(async()=>{
   const m=await (await fetch('/remote.webmanifest')).json();const result=[];
   for(const icon of m.icons){const r=await fetch(icon.src);const bitmap=await createImageBitmap(await r.blob());result.push({size:icon.sizes,width:bitmap.width,height:bitmap.height,status:r.status});bitmap.close();}return result;
  });
  assert.deepEqual(evidence.pwa.icons.map(i=>i.width),[192,512]);
  evidence.scrollWidth=await page.evaluate(()=>document.documentElement.scrollWidth);assert.ok(evidence.scrollWidth<=390);
  evidence.consoleErrors=errors;assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(outputRoot,'evidence.json'),JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
 }catch(e){evidence.failure=e.message;evidence.consoleErrors=errors;evidence.visibleStatus=await page.locator('#notice').innerText();evidence.positionPreview=await page.locator('#positionPreview').innerText();fs.writeFileSync(path.join(outputRoot,'failure.json'),JSON.stringify(evidence,null,2));throw e;}finally{await context.close();const target=path.resolve(profileDir),root=path.resolve(profileRoot)+path.sep;if(!target.startsWith(root))throw Error('Unsafe profile cleanup');fs.rmSync(target,{recursive:true,force:true});}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
