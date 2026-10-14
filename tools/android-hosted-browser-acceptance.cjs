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
  const errors = [];
  const resources = {};
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('response', (response) => {
    const pathname = new URL(response.url()).pathname;
    if (pathname.endsWith('/main.dart.js')) resources.mainDartJs = response.status();
    if (pathname.endsWith('/canvaskit.wasm')) resources.canvaskitWasm = response.status();
    if (pathname.endsWith('/flutter_bootstrap.js')) resources.flutterBootstrap = response.status();
  });

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
      ['menuRadio', 'radio', '电台控制'],
      ['menuAprs', 'aprs', 'APRS 消息与定位'],
      ['menuMap', 'map', '台站地图'],
      ['menuAudio', 'audio', '音频与频谱'],
      ['menuMore', 'more', '诊断与设置'],
    ];
    for (const [button, key, heading] of pages) {
      await page.locator(`#${button}`).click();
      assert.equal(await page.locator('#pageTitle').innerText(), heading);
      const visiblePages = await page.locator('[data-page]:not([hidden])').evaluateAll(
        (items) => [...new Set(items.map((item) => item.dataset.page))],
      );
      assert.deepEqual(visiblePages, [key], `${key} menu should show only its page`);
      assert.ok(
        await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
        `${key} menu must fit the phone viewport`,
      );
    }
    evidence.mobileMenu = pages.map(([, key]) => key);
    await page.locator('#menuRadio').click();
    await page.screenshot({ path: path.join(outputDir, 'android-remote-mobile.png'), fullPage: true });

    const appResponse = await page.goto(new URL('/index.html', base).toString(), {
      waitUntil: 'domcontentloaded',
      timeout: 15000,
    });
    assert.equal(appResponse.status(), 200, 'APK-hosted Flutter app must load');
    await page.waitForFunction(
      () => Boolean(document.querySelector('flutter-view, flt-glass-pane')),
      null,
      { timeout: 120000 },
    );
    const startupText = await page.locator('body').innerText();
    if (/could not start|无法启动|Unsupported operation/i.test(startupText)) {
      throw new Error('Flutter app startup failed: ' +
        startupText.replace(/\s+/g, ' ').slice(0, 600));
    }
    await page.waitForFunction(
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
    await page.waitForTimeout(1000);
    assert.equal(resources.flutterBootstrap, 200, 'Flutter bootstrap must load from APK');
    assert.equal(resources.mainDartJs, 200, 'compiled Flutter app must load from APK');
    assert.equal(resources.canvaskitWasm, 200, 'CanvasKit renderer must load from APK');
    assert.deepEqual(errors, [], 'hosted Flutter app must have no uncaught JavaScript errors');
    const canvas = await page.evaluate(() => {
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
      customView: await page.locator('flutter-view, flt-glass-pane').count(),
      canvas,
      resources,
      pageErrors: errors,
      horizontalOverflow: await page.evaluate(() => document.documentElement.scrollWidth > innerWidth),
    };
    assert.equal(evidence.flutter.horizontalOverflow, false);
    await page.screenshot({ path: path.join(outputDir, 'android-hosted-flutter.png'), fullPage: true });
    fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2));
    console.log(`Android APK browser acceptance passed. Evidence: ${evidencePath}`);
  } catch (error) {
    evidence.failure = error.message;
    evidence.resources = resources;
    evidence.pageErrors = errors;
    try {
      evidence.currentPath = new URL(page.url()).pathname;
      evidence.visibleText = (await page.locator('body').innerText()).slice(0, 1200);
      await page.screenshot({ path: path.join(outputDir, 'failure.png'), fullPage: true });
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
