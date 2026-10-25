// CavFi X post image: node postcard.js card.json out.png   (1600x900, brand colours, live numbers passed in)
// card.json: {eyebrow, title, sub, big, bigLabel, stats:[[label,value],...], art: 'pup'|emoji, foot}
const {chromium} = require('/tmp/claude-0/e2e/node_modules/playwright');
const fs = require('fs'), path = require('path');
const FS = path.join(__dirname, 'fonts');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')), out = process.argv[3];
const e = s => String(s ?? '').replace(/[&<>]/g, x => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'}[x]));
const pup = fs.readFileSync(path.join(__dirname, 'pup.svg'), 'utf8');
const art = !c.art || c.art === 'pup' ? `<div class="art">${pup}</div>` : /^<svg/.test(c.art) ? `<div class="art">${c.art}</div>` : `<div class="art emo">${e(c.art)}</div>`;
const html = `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{font-family:Gloock;src:url(file://${FS}/gloock-latin-400-normal.woff2)}
@font-face{font-family:Manrope;font-weight:800;src:url(file://${FS}/manrope-latin-800-normal.woff2)}
@font-face{font-family:Manrope;font-weight:600;src:url(file://${FS}/manrope-latin-600-normal.woff2)}
html,body{margin:0}
.c{width:1600px;height:900px;box-sizing:border-box;padding:72px 90px 56px;background:#11101A;color:#F1EEE8;font-family:Manrope;position:relative;overflow:hidden;
  background-image:radial-gradient(1100px 640px at 82% 38%,#3A2219 0%,transparent 70%),radial-gradient(700px 360px at 6% 112%,#2A1A14 0%,transparent 70%);
  display:grid;grid-template-columns:minmax(0,1fr) 420px;grid-template-rows:1fr auto;column-gap:56px}
.eb{display:inline-block;font:800 24px Manrope;letter-spacing:.12em;text-transform:uppercase;color:#E7B73C;margin-bottom:26px}
h1{font:400 ${c.titleSize || 84}px/1.04 Gloock;margin:0 0 22px;letter-spacing:-.01em}
h1 em{font-style:normal;color:#D46A38}
.sub{font:600 32px/1.35 Manrope;color:#CFCBD8;margin:0 0 30px;max-width:900px}
.big{display:flex;align-items:baseline;gap:18px;margin-bottom:28px}.big b{font:400 104px/1 Gloock;color:#E7B73C}.big span{font:800 30px Manrope;color:#CFCBD8}
.stats{display:flex;gap:14px;flex-wrap:nowrap}
.stats div{border:2px solid #2F2D42;border-radius:18px;padding:14px 20px}
.stats span{display:block;font:800 17px Manrope;letter-spacing:.1em;text-transform:uppercase;color:#9C99AF;margin-bottom:6px}
.stats b{font:800 32px Manrope;white-space:nowrap;color:#FFF4E2}
.art{width:420px;height:420px;border-radius:50%;background:#FFF4E2;display:grid;place-items:center;align-self:center;box-shadow:0 40px 100px -24px rgba(0,0,0,.65)}
.art svg{width:340px;height:340px}.art.emo{font-size:230px;line-height:1}
.ft{grid-column:1/-1;display:flex;justify-content:space-between;align-items:center;border-top:2px solid #2F2D42;padding-top:26px;font:800 28px Manrope}
.ft .u{color:#E7B73C}.ft .n{color:#9C99AF;font-weight:600;font-size:22px}
.logo{display:flex;align-items:center;gap:14px}.logo svg{width:52px;height:52px}.logo b{font:400 40px Gloock}.logo b i{font-style:normal;color:#D46A38}
</style></head><body><div class="c" id="c">
<div>${c.eyebrow ? `<span class="eb">${e(c.eyebrow)}</span>` : ''}<h1>${c.titleHtml || e(c.title)}</h1>${c.sub ? `<p class="sub">${e(c.sub)}</p>` : ''}
${c.big ? `<div class="big"><b>${e(c.big)}</b><span>${e(c.bigLabel)}</span></div>` : ''}
${(c.stats || []).length ? `<div class="stats">${c.stats.map(([l, v]) => `<div><span>${e(l)}</span><b>${e(v)}</b></div>`).join('')}</div>` : ''}</div>
${art}
<div class="ft"><span class="logo">${pup}<b>Cav<i>Fi</i></b></span><span class="u">${e(c.url || 'cavfi.com')}</span><span class="n">${e(c.foot || 'DogeOS testnet · tokens have no value')}</span></div>
</div></body></html>`;
(async () => {
  const b = await chromium.launch({executablePath: '/opt/pw-browsers/chromium', args: ['--headless=new']}); const p = await b.newPage({viewport: {width: 1600, height: 900}});
  const tmp = path.join(__dirname, '.card.html'); fs.writeFileSync(tmp, html); await p.goto('file://' + tmp, {waitUntil: 'load'}); await p.evaluate(() => document.fonts.ready);
  await (await p.$('#c')).screenshot({path: out}); await b.close(); console.log('wrote', out);
})();
