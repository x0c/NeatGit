// NeatGit 网页差异视图的独立验收脚本（主控的测试工具，不进仓库）。
// 用法：PW_CORE=<playwright-core 目录> node lead-verify.cjs <产物目录> <输出目录>
// 只做验收：起临时本地静态服务（仅回环），无头浏览器加载构建产物，逐项记录读数，带总时限。
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PW_CORE);

const root = path.resolve(process.argv[2] || '');
const outDir = path.resolve(process.argv[3] || '/tmp/swarm-neatgit/diffweb-verify/out');
fs.mkdirSync(outDir, { recursive: true });

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
const server = http.createServer((req, res) => {
  const file = path.join(root, decodeURIComponent(req.url.split('?')[0]));
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});

const results = [];
const record = (id, ok, note) => {
  results.push({ id, ok, note });
  console.log((ok ? '通过' : '未通过') + ' | ' + id + ' | ' + note);
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 样本：n 行，三处改动（第 10 行改、第 80 行删、第 120 行后插一行）。
function makeSample(lineCount) {
  const original = [];
  for (let index = 1; index <= lineCount; index += 1) {
    original.push('    func example' + index + '(_ value: Int) -> String { return "value ' + index + '" }');
  }
  const modified = original.slice();
  modified[9] = modified[9].replace('Int', 'Double');
  modified.splice(79, 1);
  modified.splice(120, 0, '    // 新增的一行');
  return { original: original.join('\n'), modified: modified.join('\n') };
}

// 高重复度样本：只用 20 种行内容反复填充，改动其中 21 行。
function makeRepetitive(lineCount, changedCount) {
  const pool = [];
  for (let index = 0; index < 20; index += 1) pool.push('    return value_' + index + ' + offset');
  const original = [];
  for (let index = 0; index < lineCount; index += 1) original.push(pool[index % pool.length]);
  const modified = original.slice();
  for (let index = 0; index < changedCount; index += 1) modified[index * Math.floor(lineCount / changedCount)] += ' // 改动 ' + index;
  return { original: original.join('\n'), modified: modified.join('\n') };
}

const payloadFor = (sample, languageHint) => ({
  filePath: 'Sources/Example.swift',
  modeTitle: '未暂存',
  originalLabel: 'Index',
  modifiedLabel: 'Working Tree',
  originalText: sample.original,
  modifiedText: sample.modified,
  languageHint,
});

async function withPage(browser, label, options, body) {
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 }, ...options });
  const page = await context.newPage();
  const errors = [];
  const requests = [];
  await page.addInitScript(() => {
    window.__leadWorkers = 0;
    const Native = window.Worker;
    window.Worker = class extends Native { constructor(...args) { window.__leadWorkers += 1; super(...args); } };
  });
  page.on('pageerror', (error) => errors.push(String(error.message).slice(0, 160)));
  page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text().slice(0, 160)); });
  page.on('request', (request) => requests.push(request.url()));
  try {
    await body(page, errors, requests);
  } catch (error) {
    record(label, false, '执行异常：' + String(error && error.message ? error.message : error).slice(0, 200));
  } finally {
    await context.close().catch(() => {});
  }
}

async function applyDiff(page, payload) {
  await page.evaluate((value) => window.neatGit.setDiff(value), payload);
  await page.waitForFunction(() => document.querySelectorAll('.cm-line').length > 20, null, { timeout: 20000 });
  await sleep(250);
}


// 取页面上所有编辑器视图（CodeMirror 把视图挂在编辑器根节点的 cmView 上）；取不到时返回空数组而不是抛错。

const count = (page, selector) => page.evaluate((value) => document.querySelectorAll(value).length, selector);

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port + '/index.html';
  const timer = setTimeout(() => { console.log('总时限已到，强制结束'); process.exit(2); }, 240000);
  const browser = await chromium.launch({ channel: 'chrome', headless: true });

  // —— 1 至 6、9：小样本，并排 ——
  await withPage(browser, '1a', {}, async (page, errors) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(200), 'swift'));
    const sides = await count(page, '.cm-mergeViewEditor');
    const editors = await count(page, '.cm-editor');
    record('1a 默认并排', sides === 2 && editors === 2, '并排栏 ' + sides + '，编辑器 ' + editors);
    await page.screenshot({ path: path.join(outDir, '01-并排-浅色.png') });

    await page.setViewportSize({ width: 800, height: 800 });
    await sleep(500);
    const narrowEditors = await count(page, '.cm-editor');
    const narrowHasInsert = await page.evaluate(async () => {
      const scroller = document.querySelector('.cm-scroller');
      const inserted = new Set();
      for (let top = 0; top <= scroller.scrollHeight; top += 400) {
        scroller.scrollTop = top;
        await new Promise((resolve) => setTimeout(resolve, 100));
        document.querySelectorAll('.cm-insertedLine').forEach((node) => inserted.add(node.textContent));
      }
      scroller.scrollTop = 0;
      return Array.from(inserted).some((text) => text.includes('新增的一行'));
    });
    record('1b 窄屏自动单栏', narrowEditors === 1 && narrowHasInsert, '编辑器 ' + narrowEditors + '，内容保留 ' + narrowHasInsert);
    await page.screenshot({ path: path.join(outDir, '02-单栏-窄屏.png') });
    await page.setViewportSize({ width: 1200, height: 800 });
    await sleep(500);
    record('1c 放宽后切回并排', (await count(page, '.cm-editor')) === 2, '编辑器 ' + (await count(page, '.cm-editor')));

    // 2 行号 / 整行底色 / 行前标记 / 行内高亮
    const marks = await page.evaluate(() => {
      const selectors = ['.cm-lineNumbers .cm-gutterElement', '.cm-changedLine', '.cm-deletedLine', '.cm-insertedLine',
        '.cm-changedLineGutter', '.cm-deletedLineGutter', '.cm-insertedLineGutter', '.cm-insertedChunk', '.cm-deletedChunk', '.cm-changedText'];
      const out = {};
      for (const selector of selectors) out[selector] = document.querySelectorAll(selector).length;
      const chunks = Array.from(document.querySelectorAll('.cm-insertedChunk, .cm-deletedChunk, .cm-changedText'));
      out.chunkTexts = chunks.map((node) => node.textContent);
      const gutter = document.querySelector('.cm-changedLineGutter, .cm-insertedLineGutter');
      const plain = Array.from(document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).find((node) => /^\s*\d+\s*$/.test(node.textContent) && !/changed|inserted|deleted/.test(node.className));
      out.gutterChangedBackground = gutter ? getComputedStyle(gutter).backgroundColor : null;
      out.gutterPlainBackground = plain ? getComputedStyle(plain).backgroundColor : null;
      const changed = document.querySelector('.cm-changedLine');
      out.changedLineBackground = changed ? getComputedStyle(changed).backgroundColor : null;
      return out;
    });
    const hasLineNumbers = marks['.cm-lineNumbers .cm-gutterElement'] > 10;
    const hasChanged = marks['.cm-changedLine'] + marks['.cm-deletedLine'] + marks['.cm-insertedLine'] >= 4;
    const hasInline = marks.chunkTexts.length > 0 && marks.chunkTexts.every((text) => text.length < 40);
    const gutterMarked = marks.gutterChangedBackground && marks.gutterChangedBackground !== marks.gutterPlainBackground;
    record('2a 行号', hasLineNumbers, '行号格 ' + marks['.cm-lineNumbers .cm-gutterElement']);
    record('2b 增删改整行底色', hasChanged && Boolean(marks.changedLineBackground), JSON.stringify({ 改: marks['.cm-changedLine'], 删: marks['.cm-deletedLine'], 增: marks['.cm-insertedLine'], 底色: marks.changedLineBackground }));
    record('2c 行前标记', Boolean(gutterMarked), JSON.stringify({ 改动格: marks.gutterChangedBackground, 普通格: marks.gutterPlainBackground }));
    record('2d 行内高亮', hasInline, '行内片段 ' + JSON.stringify(marks.chunkTexts).slice(0, 160));

    // 3 只读、等宽
    const readOnly = await page.evaluate(() => {
      const content = document.querySelector('.cm-content');
      return {
        editorCount: document.querySelectorAll('.cm-editor').length,
        role: content.getAttribute('role'),
        fontFamily: getComputedStyle(content).fontFamily,
      };
    });
    await page.click('.cm-content');
    await page.keyboard.press('End');
    await page.keyboard.type('ZZZ');
    await sleep(250);
    const typedLeaked = await page.evaluate(() => Array.from(document.querySelectorAll('.cm-line')).some((node) => node.textContent.includes('ZZZ')));
    const monospace = /mono|Menlo|Monaco|Courier|SF Mono/i.test(readOnly.fontFamily || '');
    record('3a 只读', !typedLeaked && readOnly.role === 'textbox', JSON.stringify({ 编辑器: readOnly.editorCount, 角色: readOnly.role, 输入泄漏: typedLeaked }));
    record('3b 等宽字体', monospace, readOnly.fontFamily);

    // 4 外观
    const appearance = await page.evaluate(async () => {
      // 背景色：从给定元素向上找到第一个不透明背景；元素不存在时返回 null。
      const backgroundOf = (node) => {
        while (node) {
          const color = getComputedStyle(node).backgroundColor;
          if (color && !/rgba\(\d+, \d+, \d+, 0(\.0+)?\)/.test(color)) return color;
          node = node.parentElement;
        }
        return null;
      };
      window.__leadContent = document.querySelector('.cm-content');
      const read = () => {
        const line = document.querySelector('.cm-line');
        const changed = document.querySelector('.cm-insertedLine') || document.querySelector('.cm-changedLine') || document.querySelector('.cm-deletedLine');
        return {
          appearance: document.documentElement.dataset.appearance,
          highContrast: document.documentElement.dataset.highContrast,
          background: line ? backgroundOf(line) : null,
          text: line ? getComputedStyle(line).color : null,
          inserted: changed ? backgroundOf(changed) : null,
        };
      };
      window.neatGit.setAppearance('dark', false);
      await new Promise((resolve) => setTimeout(resolve, 250));
      const dark = read();
      window.neatGit.setAppearance('dark', true);
      await new Promise((resolve) => setTimeout(resolve, 250));
      const darkHigh = read();
      window.neatGit.setAppearance('light', false);
      await new Promise((resolve) => setTimeout(resolve, 250));
      const light = read();
      return { dark, darkHigh, light, kept: window.__leadContent === document.querySelector('.cm-content') && window.__leadContent.isConnected };
    });
    // 对比度（相对亮度）
    const luminance = (rgb) => {
      const values = rgb.match(/[\d.]+/g).map(Number);
      const channels = values.slice(0, 3).map((value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); });
      return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
    };
    const contrast = (a, b) => { const x = luminance(a); const y = luminance(b); return ((Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)).toFixed(2); };
    const textContrastNormal = contrast(appearance.dark.text, appearance.dark.background);
    const textContrastHigh = contrast(appearance.darkHigh.text, appearance.darkHigh.background);
    record('4a 深浅两套与属性', appearance.dark.appearance === 'dark' && appearance.light.appearance === 'light' && appearance.dark.background !== appearance.light.background, JSON.stringify({ 深色底: appearance.dark.background, 浅色底: appearance.light.background }));
    record('4b 切外观不重建视图', appearance.kept, '内容节点保持 ' + appearance.kept);
    record('4c 高对比提高对比度', Number(textContrastHigh) >= Number(textContrastNormal) && appearance.darkHigh.highContrast === 'true', '文字对比度 普通 ' + textContrastNormal + ' / 高对比 ' + textContrastHigh + '；高对比属性 ' + appearance.darkHigh.highContrast);
    // 4e：深色 + 高对比必须仍然是深色背景（系统「增强对比度」不应把深色模式变成白底）。
    const toLuminance = (rgb) => { const values = (rgb || '').match(/[\d.]+/g).map(Number); if (values.length < 3) return NaN; const channels = values.slice(0, 3).map((value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }); return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]; };
    const darkHighIsDark = toLuminance(appearance.darkHigh.background) < 0.1;
    record('4e 深色高对比仍为深色背景', darkHighIsDark, JSON.stringify({ 深色高对比背景: appearance.darkHigh.background, 文字: appearance.darkHigh.text }));
    await page.evaluate(() => window.neatGit.setAppearance('dark', true));
    await sleep(250);
    await page.screenshot({ path: path.join(outDir, '03-并排-深色高对比.png') });
    await page.evaluate(() => window.neatGit.setAppearance('dark', false));
    await sleep(250);
    await page.screenshot({ path: path.join(outDir, '08-并排-深色.png') });

    // 6 无障碍标签
    const labels = await page.evaluate(() => Array.from(document.querySelectorAll('.cm-content')).map((node) => node.getAttribute('aria-label') || ''));
    record('6 无障碍标签', labels.length === 2 && labels.every((text) => text.includes('只读') && text.includes('Example.swift')) && labels[0] !== labels[1], JSON.stringify(labels));
    record('1-6 运行期无报错', errors.length === 0, errors.slice(0, 3).join(' ；'));
  });

  // —— 5：新页面里定位到第一处差异 ——
  await withPage(browser, '5', {}, async (page) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(200), 'swift'));
    const firstDiff = await page.evaluate(() => Array.from(document.querySelectorAll('.cm-editor')).map((editor) => {
      const scroller = editor.querySelector('.cm-scroller').getBoundingClientRect();
      const numbers = Array.from(editor.querySelectorAll('.cm-lineNumbers .cm-gutterElement'))
        .filter((node) => /^\s*\d+\s*$/.test(node.textContent))
        .map((node) => ({ number: Number(node.textContent.trim()), top: node.getBoundingClientRect().top }))
        .filter((item) => item.top >= scroller.top - 2 && item.top < scroller.bottom)
        .map((item) => item.number);
      return numbers.length ? Math.min(...numbers) : null;
    }));
    record('5 定位第一处差异', firstDiff.length === 2 && firstDiff.every((item) => item !== null && item <= 10), '两侧视口顶部行号 ' + JSON.stringify(firstDiff) + '（第一处差异在第 10 行）');
    await page.screenshot({ path: path.join(outDir, '07-打开后定位.png') });
  });

  // 4d 跟随系统深浅色（从未调用 setAppearance）
  await withPage(browser, '4d', { colorScheme: 'dark' }, async (page) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(60), 'swift'));
    const appearance = await page.evaluate(() => document.documentElement.dataset.appearance);
    record('4d 未调用时跟随系统深色', appearance === 'dark', '外观 ' + appearance);
  });

  // —— 7：1 MB 文本 ——
  await withPage(browser, '7', {}, async (page, errors) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    const big = makeSample(16000);
    const bytes = big.original.length;
    const started = Date.now();
    await applyDiff(page, payloadFor(big, 'swift'));
    const elapsed = Date.now() - started;
    const heap = await page.evaluate(() => (performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : null));
    record('7 1 MB 文本', bytes > 950000 && errors.length === 0, '原文 ' + (bytes / 1048576).toFixed(2) + ' MB，显示耗时 ' + elapsed + ' 毫秒，脚本堆 ' + heap + ' MB');
  });

  // —— 8：差异精度 ——
  await withPage(browser, '8', {}, async (page) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    const sample = makeRepetitive(10000, 21);
    await applyDiff(page, payloadFor(sample, 'swift'));
    const marked = await count(page, '.cm-changedLine, .cm-deletedLine, .cm-insertedLine');
    record('8 高重复度万行不误标', marked > 0 && marked <= 60, '被标为改动的行 ' + marked + '（真实 21 行，并排两侧合计）');
  });


  // —— 11：只看变更折叠 ——
  await withPage(browser, '11', {}, async (page, errors) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(200), 'swift'));
    const before = await count(page, '.ng-collapsedLines');
    await page.evaluate(() => window.neatGit.setChangesOnly(true));
    await sleep(500);
    const labels = await page.evaluate(() => Array.from(document.querySelectorAll('.ng-collapsedLines')).map((node) => node.getAttribute('aria-label') || node.title || ''));
    const hidden = labels.map((text) => Number((text.match(/(\d+)\s*行未展开/) || [0, -1])[1]));
    // 样本的真实边界（主控按样本构造方式逐行复算）：新增行在改后文档的第 121 行，位于原文第 120 行之后。
    // 未变更段：原文 1–9 / 11–79 / 81–120 / 121–200，各留 3 行后应隐藏 6 / 63 / 35 / 76。
    const expected = [6, 63, 35, 76];
    const oneSide = hidden.slice(0, 4);
    const otherSide = hidden.slice(4, 8);
    record('11a 折叠未变更区域', before === 0 && hidden.length === 8 && JSON.stringify(oneSide) === JSON.stringify(expected) && JSON.stringify(otherSide) === JSON.stringify(expected), '开启前 ' + before + ' 个；各段隐藏行数 ' + JSON.stringify(hidden) + '，按规则应为 ' + JSON.stringify(expected) + ' ×2 栏');
    // 点击「还有 63 行未展开」的那个占位：应变成还有 43 行。
    await page.evaluate(() => { const target = Array.from(document.querySelectorAll('.ng-collapsedLines')).find((node) => /63\s*行未展开/.test(node.getAttribute('aria-label') || '')); target.click(); });
    await sleep(400);
    const afterHidden = await page.evaluate(() => Array.from(document.querySelectorAll('.ng-collapsedLines')).map((node) => Number((node.getAttribute('aria-label').match(/(\d+)\s*行未展开/) || [0, -1])[1])));
    record('11b 点击展开 20 行', afterHidden.slice(0, 4).includes(43), '点击「还有 63 行」后各段隐藏行数 ' + JSON.stringify(afterHidden.slice(0, 4)) + '（该段应变为 43）');
    await page.evaluate(() => window.neatGit.setChangesOnly(false));
    await sleep(400);
    record('11c 关闭后全部展开', (await count(page, '.ng-collapsedLines')) === 0, '占位 ' + (await count(page, '.ng-collapsedLines')) + ' 个');
    record('11 运行期无报错', errors.length === 0, errors.slice(0, 3).join(' ；'));
  });

  // —— 12：语法高亮 ——
  await withPage(browser, '12', {}, async (page) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(200), 'swift'));
    const colored = await count(page, '[class*="ng-syn-"]');
    record('12a 按文件类型高亮', colored > 20, '高亮片段 ' + colored);
    await page.screenshot({ path: path.join(outDir, '05-语法高亮-并排.png') });
    await applyDiff(page, payloadFor(makeSample(200), null));
    const plain = await count(page, '[class*="ng-syn-"]');
    record('12b 未知语言回退纯文本', plain === 0, '高亮片段 ' + plain);
  });

  // —— 13：查找 ——
  await withPage(browser, '13', {}, async (page) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    await applyDiff(page, payloadFor(makeSample(200), 'swift'));
    await page.click('.cm-content', { position: { x: 150, y: 60 } });
    await sleep(200);
    const focused = await page.evaluate(() => { const active = document.activeElement; return active ? String(active.className || active.tagName).slice(0, 30) : '无'; });
    await page.keyboard.press('Meta+f');
    await sleep(400);
    const opened = await page.evaluate(() => ({
      panel: document.querySelectorAll('.cm-search').length,
      replaceField: document.querySelectorAll('.cm-search input[name="replace"]').length,
      buttons: Array.from(document.querySelectorAll('.cm-search button')).map((node) => node.name || node.getAttribute('aria-label') || node.title || '').slice(0, 8),
    }));
    await page.keyboard.type('Double');
    await sleep(500);
    const matches = await count(page, '.cm-searchMatch');
    await page.screenshot({ path: path.join(outDir, '06-查找面板.png') });
    record('13a 点击差异文本后 ⌘F 可用', opened.panel === 1 && matches >= 1, JSON.stringify({ 点击后焦点: focused, ...opened, 匹配: matches }));
    record('13b 查找不含替换入口', opened.replaceField === 0, '替换输入框 ' + opened.replaceField + ' 个；按钮 ' + JSON.stringify(opened.buttons));
    await page.keyboard.press('Escape');
    await sleep(300);
    record('13c Esc 关闭面板', (await count(page, '.cm-search')) === 0, '面板 ' + (await count(page, '.cm-search')) + ' 个');
  });

  // —— 9、10：重复调用不重渲染；无 Worker、无外部请求 ——
  await withPage(browser, '9', {}, async (page, errors, requests) => {
    await page.goto(base);
    await page.waitForFunction(() => typeof window.neatGit?.setDiff === 'function', null, { timeout: 15000 });
    const payload = payloadFor(makeSample(200), 'swift');
    await applyDiff(page, payload);
    await page.evaluate(() => { window.__leadFirstLine = document.querySelector('.cm-line'); });
    await page.evaluate((value) => window.neatGit.setDiff(value), payload);
    await sleep(400);
    const kept = await page.evaluate(() => window.__leadFirstLine === document.querySelector('.cm-line') && window.__leadFirstLine.isConnected);
    record('9 相同内容不重渲染', kept, '首个行节点保持 ' + kept);
    const workers = await page.evaluate(() => window.__leadWorkers);
    const external = requests.filter((url) => !url.startsWith('http://127.0.0.1:') && !url.startsWith('data:'));
    record('10a 无 Web Worker', workers === 0, 'Worker 数 ' + workers);
    record('10b 无外部请求', external.length === 0, '请求共 ' + requests.length + ' 个，外部 ' + external.length + ' 个');
  });

  await browser.close();
  clearTimeout(timer);
  server.close();
  fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(results, null, 2));
  const failed = results.filter((item) => !item.ok).length;
  console.log('合计：' + results.length + ' 项，未通过 ' + failed + ' 项');
  process.exit(0);
})().catch((error) => { console.log('验收脚本失败：' + String(error && error.stack ? error.stack : error).slice(0, 600)); process.exit(1); });
