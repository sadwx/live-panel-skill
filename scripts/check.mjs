// Usage: node check.mjs <panel.html> [shots=1]
// Renders the panel at 1240px dark and light, 400px and 792px (a Confluence page column), then prints per viewport:
//   errors  the renderer's spec validation (unknown node, a flow step with no edge, an edge in no flow, log/step
//           count mismatch, a side trigger no flow fires); must be []
//   out     a box that overflows, text running past a box's content edge, overlapping boxes, a label on a box or
//           on another label; must be []
//   h       the stage height; at 792px, h + 32 is the iframe height for a Confluence embed
// Screenshots go to .check/ beside the panel. Look at them: the checks prove fit, not that the diagram is right.
// Needs: npm i playwright-core (or playwright); set CHROME=/path/to/chrome, else Chrome's default Windows path.
import { chromium } from 'playwright-core'; import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, basename, dirname, join } from 'node:path'; import { pathToFileURL } from 'node:url';
const [,, file, shots = '1'] = process.argv;
const slug = basename(file, '.html'), out = join(dirname(resolve(file)), '.check'); mkdirSync(out, { recursive: true });
const src = readFileSync(file, 'utf8'), wrapped = join(out, `wrapped-${slug}.html`);
writeFileSync(wrapped, /<!doctype/i.test(src) ? src : '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' + src.replace('</style>', '</style></head><body>') + '</body></html>');
const b = await chromium.launch({ executablePath: process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe' });

function inspect() {
  const out = [], name = e => e.dataset.id || 'side', hit = (a, c) => a.left < c.right && c.left < a.right && a.top < c.bottom && c.top < a.bottom;
  const pairs = (xs, f) => { for (let i = 0; i < xs.length; i++) for (let j = i + 1; j < xs.length; j++) f(xs[i], xs[j]); };
  const boxes = [...document.querySelectorAll('.node,.side')];
  boxes.forEach(e => {
    if (e.scrollWidth > e.clientWidth + 1 || e.scrollHeight > e.clientHeight + 1) out.push('overflow ' + name(e));
    // measure the text itself against the content edge (border + padding), so full-bleed rows need no exception
    const r = e.getBoundingClientRect(), cs = getComputedStyle(e), k = r.width / e.offsetWidth;
    const right = r.right - (parseFloat(cs.borderRightWidth) + parseFloat(cs.paddingRight)) * k + 1, bottom = r.bottom - parseFloat(cs.borderBottomWidth) * k + 1;
    const walk = document.createTreeWalker(e, NodeFilter.SHOW_TEXT), range = document.createRange();
    for (let t; (t = walk.nextNode());) { if (!t.textContent.trim()) continue; range.selectNodeContents(t); const tr = range.getBoundingClientRect();
      if (tr.width && (tr.right > right || tr.bottom > bottom)) out.push(`text past edge in ${name(e)}: ${t.textContent.trim().slice(0, 30)}`); }
  });
  pairs(boxes, (a, c) => { if (hit(a.getBoundingClientRect(), c.getBoundingClientRect())) out.push(`overlap ${name(a)}/${name(c)}`); });
  const labels = [...document.querySelectorAll('.elabel,.hub')];
  labels.forEach(l => boxes.forEach(bx => { if (hit(l.getBoundingClientRect(), bx.getBoundingClientRect())) out.push(`label over box: ${l.textContent.slice(0, 30)} / ${name(bx)}`); }));
  pairs(labels, (l, m) => { if (hit(l.getBoundingClientRect(), m.getBoundingClientRect())) out.push(`label overlap: ${l.textContent.slice(0, 20)} / ${m.textContent.slice(0, 20)}`); });
  return { errors: window.__panelErrors || [], out, docW: document.documentElement.scrollWidth, h: Math.round(document.getElementById('stage').getBoundingClientRect().height) };
}

const views = [[1240, 'dark'], [1240, 'light'], [400, 'dark'], [792, 'light']];
const results = await Promise.all(views.map(async ([w, t]) => {
  const p = await b.newPage({ viewport: { width: w, height: 1000 }, colorScheme: t }); const pageErr = []; p.on('pageerror', e => pageErr.push(e.message));
  await p.goto(pathToFileURL(wrapped).href); await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(1200);
  const r = { ...(await p.evaluate(inspect)), pageErr };
  const n = w === 1240 && t === 'dark' ? +shots : 1;
  for (let i = 0; i < n; i++) { if (i) await p.waitForTimeout(2300); await p.screenshot({ path: join(out, `${slug}-${w}-${t}-${i}.png`), fullPage: true }); }
  await p.close();
  return { w, t, r, failed: r.errors.length || r.out.length || pageErr.length || r.docW > w };
}));
await b.close();
results.forEach(({ w, t, r }) => console.log(w, t, JSON.stringify(r)));
const failed = results.some(x => x.failed);
console.log(failed ? 'FAIL' : 'ok', '· screenshots in', out);
process.exitCode = failed ? 1 : 0;
