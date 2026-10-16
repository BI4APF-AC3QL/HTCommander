'use strict';

// Exercise the pages and Flutter web bundle served by the installed Android
// APK through adb forward. The test uses only a synthetic integration-test
// password and a synthetic radio; it never opens physical devices or RF.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require('./browser-acceptance/node_modules/playwright');

const outputParent = process.env.HTC_ANDROID_BROWSER_OUTPUT ||
  path.join(os.tmpdir(), 'htcommander-android-browser-acceptance');
fs.mkdirSync(outputParent, { recursive: true });
const outputDir = fs.mkdtempSync(path.join(outputParent, 'run-'));
const evidencePath = path.join(outputDir, 'evidence.json');
const failurePath = path.join(outputDir, 'failure.json');
const base = new URL(process.argv[2] || 'http://127.0.0.1:18735');
assert.equal(base.protocol, 'http:');
assert.equal(base.hostname, '127.0.0.1');

async function main() {
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
  });
  const page = await context.newPage();
  let flutterPage;
  const errors = [];
  const consoleDiagnostics = [];
  const resources = {};
  const resourceHeaders = {};

  const evidence = {
    source: 'installed Android APK via adb forward',
    browser: `Chromium ${browser.version()}`,
    viewport: { width: 390, height: 844 },
    physicalRadio: false,
    physicalBluetooth: false,
    rfTransmit: false,
  };

  try {
    const loginResponse = await page.goto(new URL('/login', base).toString(), {
      waitUntil: 'domcontentloaded',
      timeout: 15000,
    });
    assert.equal(loginResponse.status(), 200, 'Android login page must load');
    assert.match(await page.title(), /HTCommander 登录/);
    await page.locator('#password').fill('AndroidIntegrationTestPassword');
    await Promise.all([
      page.waitForURL((url) => url.pathname === '/remote.html', { timeout: 15000 }),
      page.locator('form button').click(),
    ]);
    assert.match(await page.title(), /HTCommander 远程操控/);
    await page.locator('#connection').waitFor({ state: 'visible' });
    await page.waitForFunction(
      () => document.querySelector('#connection')?.textContent === '已连接主机',
      null,
      { timeout: 15000 },
    );

    const pages = [
      ['menuRadio', 'radio', '电台控制', [
        '#channel', '#scan', '#squelch', '#satelliteStart', '#controlRequest', '#ptt',
      ]],
      ['menuAprs', 'aprs', 'APRS 消息与定位', [
        '#aprsDestination', '#aprsText', '#aprsSend', '#aprsDeliveries',
        '#aprsSearch', '#positionAcquire', '#positionSend',
      ]],
      ['menuMap', 'map', '台站地图', [
        '#mapSource', '#stationMap', '#mapZoomIn', '#mapRetry', '#mapSearch',
      ]],
      ['menuAudio', 'audio', '音频与频谱', [
        '#playback', '#audioBuffer', '#micTest', '#spectrumPause',
        '#spectrumRange', '#spectrumGain', '#spectrum', '#waterfall',
      ]],
      ['menuMore', 'more', '诊断与设置', [
        '#networkMode', '#dashboardRadio', '#gatewayMetrics', '#linkDiagnostics',
        '#beaconTask', '#auditEvents', '#installApp',
      ]],
    ];
    const mobileFeatureCoverage = {};
    for (const [button, key, heading, selectors] of pages) {
      await page.locator(`#${button}`).click();
      assert.equal(await page.locator('#pageTitle').innerText(), heading);
      const visiblePages = await page.locator('[data-page]:not([hidden])').evaluateAll(
        (items) => [...new Set(items.map((item) => item.dataset.page))],
      );
      assert.deepEqual(visiblePages, [key], `${key} menu should show only its page`);
      for (const selector of selectors) {
        const control = page.locator(selector);
        assert.equal(await control.count(), 1, `${key} menu is missing ${selector}`);
        assert.equal(
          await control.evaluate((element) => element.closest('[data-page]')?.dataset.page),
          key,
          `${selector} should be grouped under the ${key} menu`,
        );
      }
      mobileFeatureCoverage[key] = selectors;
      assert.ok(
        await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
        `${key} menu must fit the phone viewport`,
      );
    }
    evidence.mobileMenu = pages.map(([, key]) => key);
    evidence.mobileFeatureCoverage = mobileFeatureCoverage;
    await page.locator('#menuRadio').click();
    await page.waitForFunction(
      () => document.querySelector('#status')?.textContent.includes('音频通道已连接'),
      null,
      { timeout: 10000 },
    );
    assert.equal(await page.locator('#frequency').innerText(), '145.60000 MHz');
    assert.equal(await page.locator('#squelch').inputValue(), '5');
    await page.locator('[data-page="radio"] summary')
      .filter({ hasText: '电台音量与静噪' })
      .click();
    await page.locator('[data-page="radio"] summary')
      .filter({ hasText: '操作权' })
      .click();
    await page.locator('#controlRequest').click();
    await page.waitForFunction(
      () => document.querySelector('#controlStatus')?.textContent.includes('你持有操作权'),
      null,
      { timeout: 10000 },
    );
    assert.equal(await page.locator('#channel').isEnabled(), true);
    assert.equal(await page.locator('#squelch').isEnabled(), true);
    assert.equal(await page.locator('#volume').isEnabled(), true);
    assert.equal(await page.locator('#ptt').isDisabled(), true,
      'the Android acceptance radio must remain receive-only');
    await page.locator('#squelch').evaluate((element) => {
      element.value = '6';
      element.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.locator('#volume').evaluate((element) => {
      element.value = '8';
      element.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(
      () => {
        const events = document.querySelector('#auditEvents')?.textContent || '';
        return events.includes('设备静噪 · 请求接受') &&
          events.includes('调电台音量 · 请求接受');
      },
      null,
      { timeout: 10000 },
    );
    await page.locator('[data-page="radio"] summary')
      .filter({ hasText: '卫星多普勒' })
      .click();
    await page.waitForFunction(
      () => document.querySelector('#satelliteStatus')?.textContent.includes('主机观测位置已就绪'),
      null,
      { timeout: 10000 },
    );
    assert.equal(await page.locator('#satellite option').count(), 1);
    assert.equal(await page.locator('#satellite option').first().innerText(), 'ISS test satellite');
    assert.match(await page.locator('#satellitePreview').innerText(), /修正 .* MHz/);
    assert.equal(await page.locator('#satelliteStart').isEnabled(), true);
    await page.locator('#satelliteStart').click();
    await page.waitForFunction(
      () => {
        const events = document.querySelector('#auditEvents')?.textContent || '';
        return events.includes('接收多普勒开始 · 请求接受');
      },
      null,
      { timeout: 10000 },
    );
    await page.waitForFunction(
      () => document.querySelector('#satelliteStop')?.disabled === false,
      null,
      { timeout: 10000 },
    );
    await page.locator('#satelliteStop').click();
    await page.waitForFunction(
      () => {
        const events = document.querySelector('#auditEvents')?.textContent || '';
        return events.includes('接收多普勒停止 · 请求接受');
      },
      null,
      { timeout: 10000 },
    );
    await page.waitForFunction(
      () => document.querySelector('#satelliteStop')?.disabled === true,
      null,
      { timeout: 10000 },
    );
    await page.locator('#menuAprs').click();
    assert.equal(await page.locator('#aprsSend').isEnabled(), true,
      'the synthetic Android host should expose its explicitly enabled APRS permission');
    await page.locator('#aprsDestination').fill('BI4APF-7');
    await page.locator('#aprsText').fill('Android test message');
    await page.locator('#aprsSend').click();
    assert.equal(await page.locator('#aprsConfirmation').isVisible(), true,
      'APRS submission must require a preview and confirmation');
    assert.match(await page.locator('#aprsPreview').innerText(), /BI4APF-7/);
    assert.match(await page.locator('#aprsPreview').innerText(), /Android test message/);
    await page.locator('#aprsConfirm').click();
    await page.waitForFunction(
      () => {
        const events = document.querySelector('#auditEvents')?.textContent || '';
        return events.includes('APRS 消息请求 · 请求接受');
      },
      null,
      { timeout: 10000 },
    );
    await page.waitForFunction(
      () => (document.querySelector('#aprsDeliveries')?.textContent || '')
        .includes('BI4APF-7 · 等待 ACK'),
      null,
      { timeout: 10000 },
    );
    assert.equal(await page.locator('#ptt').isDisabled(), true,
      'APRS message access must not enable voice PTT');
    evidence.radioControls = {
      frequency: await page.locator('#frequency').innerText(),
      channelOptions: await page.locator('#channel option').allTextContents(),
      squelch: await page.locator('#squelch').inputValue(),
      volume: await page.locator('#volume').inputValue(),
      satellite: await page.locator('#satellite option').first().innerText(),
      satelliteReceiveOnly: true,
      pttDisabled: await page.locator('#ptt').isDisabled(),
      acceptedActions: ['squelch', 'volume', 'satelliteStart', 'satelliteStop'],
      physicalRadio: false,
      rfTransmit: false,
    };
    evidence.aprs = {
      previewRequired: true,
      confirmedThroughHostedPage: true,
      deliveryState: await page.locator('#aprsDeliveries').innerText(),
      radioPttDisabled: await page.locator('#ptt').isDisabled(),
      physicalRadio: false,
      rfTransmit: false,
    };
    await page.screenshot({ path: path.join(outputDir, 'android-remote-mobile.png'), fullPage: true });
    // Release the authenticated remote page's WebSocket before loading the
    // much larger Flutter bundle. The HTTP byte-count assertion in the Android
    // integration test covers the server independently; this keeps adb
    // forwarding and Chromium's large response transfer isolated here.
    await page.close();
    const serverProbe = await context.request.get(new URL('/login', base).toString());
    assert.equal(
      serverProbe.status(),
      200,
      'Android web server must stay available after the last remote client disconnects',
    );
    await serverProbe.dispose();

    // Load the complete hosted Flutter client in a separate page after the
    // remote control session has closed.
    flutterPage = await context.newPage();
    flutterPage.on('pageerror', (error) => errors.push(error.message));
    flutterPage.on('console', (message) => {
      if ((message.type() === 'error' || message.type() === 'warning') &&
          consoleDiagnostics.length < 40) {
        consoleDiagnostics.push(`${message.type()}: ${message.text()}`);
      }
    });
    flutterPage.on('requestfailed', (request) => {
      if (consoleDiagnostics.length < 40) {
        consoleDiagnostics.push(`request failed: ${request.url()} (${request.failure()?.errorText || 'unknown'})`);
      }
    });
    flutterPage.on('response', (response) => {
      const pathname = new URL(response.url()).pathname;
      if (pathname.endsWith('/main.dart.js')) {
        resources.mainDartJs = response.status();
        const headers = response.headers();
        resourceHeaders.mainDartJs = {
          contentLength: Number(headers['content-length']) || null,
          contentEncoding: headers['content-encoding'] || null,
        };
      }
      if (pathname.endsWith('/canvaskit.wasm')) resources.canvaskitWasm = response.status();
      if (pathname.endsWith('/flutter_bootstrap.js')) resources.flutterBootstrap = response.status();
    });
    const appResponse = await flutterPage.goto(new URL('/index.html', base).toString(), {
      waitUntil: 'domcontentloaded',
      timeout: 15000,
    });
    assert.equal(appResponse.status(), 200, 'APK-hosted Flutter app must load');
    await flutterPage.waitForFunction(
      () => Boolean(document.querySelector('flutter-view, flt-glass-pane')),
      null,
      { timeout: 60000 },
    );
    const startupText = await flutterPage.locator('body').innerText();
    if (/could not start|无法启动|Unsupported operation/i.test(startupText)) {
      throw new Error('Flutter app startup failed: ' +
        startupText.replace(/\s+/g, ' ').slice(0, 600));
    }
    await flutterPage.waitForFunction(
      () => {
        const pending = [document];
        while (pending.length > 0) {
          const root = pending.pop();
          if (root.querySelector('canvas')) return true;
          for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot) pending.push(element.shadowRoot);
          }
        }
        return false;
      },
      null,
      { timeout: 60000 },
    );
    await flutterPage.waitForTimeout(1000);
    assert.equal(resources.flutterBootstrap, 200, 'Flutter bootstrap must load from APK');
    assert.equal(resources.mainDartJs, 200, 'compiled Flutter app must load from APK');
    assert.equal(resources.canvaskitWasm, 200, 'CanvasKit renderer must load from APK');
    assert.deepEqual(errors, [], 'hosted Flutter app must have no uncaught JavaScript errors');
    assert.deepEqual(
      consoleDiagnostics.filter((entry) => entry.startsWith('error:')),
      [],
      'hosted Flutter app must not report browser console errors',
    );
    const canvas = await flutterPage.evaluate(() => {
      const pending = [document];
      let element;
      while (pending.length > 0 && !element) {
        const root = pending.pop();
        element = root.querySelector('canvas');
        if (!element) {
          for (const child of root.querySelectorAll('*')) {
            if (child.shadowRoot) pending.push(child.shadowRoot);
          }
        }
      }
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return { bitmapWidth: element.width, bitmapHeight: element.height, width: rect.width, height: rect.height };
    });
    assert.ok(canvas && canvas.bitmapWidth > 0 && canvas.bitmapHeight > 0 &&
      canvas.width > 0 && canvas.height > 0, 'Flutter must create a visible, sized render surface');
    evidence.flutter = {
      servedFromApk: true,
      customView: await flutterPage.locator('flutter-view, flt-glass-pane').count(),
      canvas,
      resources,
      resourceHeaders,
      pageErrors: errors,
      horizontalOverflow: await flutterPage.evaluate(() => document.documentElement.scrollWidth > innerWidth),
    };
    assert.equal(evidence.flutter.horizontalOverflow, false);
    await flutterPage.screenshot({ path: path.join(outputDir, 'android-hosted-flutter.png'), fullPage: true });
    fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2));
    console.log(`Android APK browser acceptance passed. Evidence: ${evidencePath}`);
  } catch (error) {
    evidence.failure = error.message;
    evidence.resources = resources;
    evidence.resourceHeaders = resourceHeaders;
    evidence.pageErrors = errors;
    evidence.consoleDiagnostics = consoleDiagnostics;
    try {
      const diagnosticPage = flutterPage || page;
      evidence.currentPath = new URL(diagnosticPage.url()).pathname;
      evidence.visibleText = (await diagnosticPage.locator('body').innerText()).slice(0, 1200);
      await diagnosticPage.screenshot({ path: path.join(outputDir, 'failure.png'), fullPage: true });
    } catch (_) {
      // Keep diagnostics available even if Chromium exited before rendering.
    }
    fs.writeFileSync(failurePath, JSON.stringify(evidence, null, 2));
    throw error;
  } finally {
    await context.close();
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
