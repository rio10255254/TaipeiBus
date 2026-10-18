const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { chromium } = require('playwright');
const { pathToFileURL } = require('url');
const root = path.resolve(process.argv[2] || path.join(__dirname, '../../work/store-gallery-proposal'));
const config = JSON.parse(fs.readFileSync(path.join(root, process.argv[3] || 'proposal-1.8.9.json'), 'utf8'));
const escape = text => String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const outputName = config.exports_directory || 'exports';
const output = path.join(root, outputName);
fs.mkdirSync(output, { recursive: true });

(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  const page = await browser.newPage({ viewport: { width: 1320, height: 2868 }, deviceScaleFactor: 1 });
  const results = [];
  for (const slide of config.slides) {
    const source = path.join(root, 'sources', slide.source);
    const bytes = fs.readFileSync(source);
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== slide.source_sha256) throw Error('Source changed: ' + slide.source);
    const mime = path.extname(source).toLowerCase() === '.jpg' ? 'image/jpeg' : 'image/png';
    let content = `<div class="screen"><img alt="${escape(slide.title)}的實際 App 畫面" src="data:${mime};base64,${bytes.toString('base64')}"></div>`;
    let extraStyle = '';
    let secondary;
    if (slide.source_crop_top) {
      const scale = 1128 / slide.source_dimensions[0];
      const croppedHeight = (slide.source_dimensions[1] - slide.source_crop_top) * scale;
      extraStyle = `.screen{height:${croppedHeight}px;overflow:hidden}.screen img{position:absolute;top:${-slide.source_crop_top * scale}px;width:1128px;height:${slide.source_dimensions[1] * scale}px;object-fit:fill}`;
    }
    if (slide.layout === 'live-activity-polished') {
      secondary = fs.readFileSync(path.join(root, 'sources', slide.secondary_source));
      if (crypto.createHash('sha256').update(secondary).digest('hex') !== slide.secondary_source_sha256) throw Error('Secondary capture changed');
      const [x, y, width, height] = slide.crop;
      const scale = 880 / width;
      const secondaryScale = 920 / slide.secondary_source_dimensions[0];
      const secondaryHeight = (slide.secondary_source_dimensions[1] - slide.secondary_crop_top) * secondaryScale;
      extraStyle = `.island-window{position:absolute;top:370px;left:220px;width:880px;height:${height * scale}px;border-radius:${height * scale / 2}px;overflow:hidden;box-shadow:0 8px 24px #00000018;background:#000}.island-window img{position:absolute;left:${-x * scale}px;top:${-y * scale}px;width:${slide.source_dimensions[0] * scale}px;height:${slide.source_dimensions[1] * scale}px;max-width:none;object-fit:fill}.benefit{position:absolute;top:575px;left:96px;width:1128px}.benefit h2{margin:0 0 10px;font-size:46px;font-weight:600;line-height:1.25;letter-spacing:-.7px}.benefit p{margin:0;font-size:34px;line-height:1.5;color:#505c68}.benefit small{display:block;margin-top:7px;font-size:26px;line-height:1.4;color:#636e79}.screen{left:200px;top:804px;width:920px;height:${secondaryHeight}px;overflow:hidden}.screen img{position:absolute;left:0;top:${-slide.secondary_crop_top * secondaryScale}px;width:920px;height:${slide.secondary_source_dimensions[1] * secondaryScale}px;max-width:none;object-fit:fill}.screen-label{position:absolute;left:200px;top:765px;font-size:24px;color:#636e79}`;
      content = `<div class="island-window"><img alt="實際動態島顯示 630 路線與剩餘 20 站" src="data:${mime};base64,${bytes.toString('base64')}"></div><section class="benefit"><h2>${escape(slide.benefit_title)}</h2><p>${escape(slide.benefit_caption)}</p><small>${escape(slide.benefit_note)}</small></section><div class="screen-label">${escape(slide.secondary_label)}</div><div class="screen"><img alt="Pro 功能與月費 39、年費 390 的實際方案畫面" src="data:image/png;base64,${secondary.toString('base64')}"></div>`;
    }
    if (slide.layout === 'live-activity') {
      secondary = fs.readFileSync(path.join(root, 'sources', slide.secondary_source));
      if (crypto.createHash('sha256').update(secondary).digest('hex') !== slide.secondary_source_sha256) throw Error('Secondary capture changed');
      const [x, y, width, height] = slide.crop;
      const scale = 1030 / width;
      extraStyle = `.island-window{position:absolute;top:378px;left:145px;width:1030px;height:${height * scale}px;border-radius:110px;overflow:hidden;box-shadow:0 10px 30px #0002;background:#000}.island-window img{position:absolute;left:${-x * scale}px;top:${-y * scale}px;width:${slide.source_dimensions[0] * scale}px;height:${slide.source_dimensions[1] * scale}px;max-width:none;object-fit:fill}.benefit{position:absolute;top:628px;left:96px;width:1128px}.benefit h2{margin:0 0 14px;font-size:48px;font-weight:600;letter-spacing:-.7px}.benefit p{margin:0;font-size:34px;line-height:1.5;color:#626d79}.benefit small{display:block;margin-top:10px;font-size:24px;color:#77818b}.screen{left:216px;top:840px;width:888px;height:1934px}.screen-label{position:absolute;left:216px;top:802px;font-size:22px;color:#77818b}`;
      content = `<div class="island-window"><img alt="實際動態島顯示 630 路線與剩餘 20 站" src="data:${mime};base64,${bytes.toString('base64')}"></div><section class="benefit"><h2>${escape(slide.benefit_title)}</h2><p>${escape(slide.benefit_caption)}</p><small>${escape(slide.benefit_note)}</small></section><div class="screen-label">App 內的搭車資訊</div><div class="screen"><img alt="630 公車行程的實際 App 畫面" src="data:image/jpeg;base64,${secondary.toString('base64')}"></div>`;
    }
    const html = `<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><title>${escape(slide.title)}</title>
      <style>
      *{box-sizing:border-box}html,body{margin:0;width:1320px;height:2868px;overflow:hidden;background:#f5f5f7;color:#17212a}
      body{font-family:"Microsoft JhengHei UI","Microsoft JhengHei","Segoe UI",sans-serif}
      .brand{position:absolute;top:64px;left:96px;font-size:32px;font-weight:500;letter-spacing:1px;color:#68717c}
      .pro{position:absolute;top:58px;right:96px;padding:7px 17px;font-size:25px;font-weight:600;color:#51677c;border:1px solid #bfcad5;border-radius:30px}
      h1{position:absolute;top:135px;left:92px;width:1136px;margin:0;font-size:74px;font-weight:600;line-height:1.22;letter-spacing:-1.4px;white-space:nowrap}
      .caption{position:absolute;top:255px;left:96px;width:1128px;margin:0;font-size:36px;line-height:1.5;color:#505c68;white-space:nowrap}
      .screen{position:absolute;left:96px;top:360px;width:1128px;height:2450px;box-shadow:0 12px 38px #1e2b3815;outline:1px solid #d7dce2;background:#f5f5f7}
      img{display:block;width:100%;height:100%;object-fit:contain}
      ${extraStyle}
      </style><div class="brand">台北公車動態</div>${slide.pro ? '<div class="pro">Pro</div>' : ''}
      <h1>${escape(slide.title)}</h1><p class="caption">${escape(slide.caption)}</p>
      ${content}</html>`;
    const htmlFile = path.join(output, slide.file.replace('.png', '.html'));
    fs.writeFileSync(htmlFile, html);
    await page.goto(pathToFileURL(htmlFile).href);
    await page.evaluate(() => document.fonts.ready);
    await page.locator('img').evaluateAll(images => Promise.all(images.map(image => image.decode())));
    const geometry = await page.evaluate(() => ({
      image: [document.querySelector('img').naturalWidth, document.querySelector('img').naturalHeight],
      clipping: ['h1', '.caption', '.benefit', '.screen-label'].some(selector => { const node = document.querySelector(selector); return node && node.scrollWidth > node.clientWidth; }),
      screen: document.querySelector('.screen').getBoundingClientRect().toJSON(),
      textBounds: [...document.querySelectorAll('h1,.caption,.brand,.pro,.benefit,.screen-label')].map(node => ({text: node.textContent, rect: node.getBoundingClientRect().toJSON()})),
      sources: [...document.images].map(image => [image.naturalWidth,image.naturalHeight])
    }));
    if (JSON.stringify(geometry.image) !== JSON.stringify(slide.source_dimensions) || geometry.clipping || geometry.screen.bottom > 2868) throw Error('Layout mismatch: ' + slide.file);
    for (const node of geometry.textBounds) if (node.rect.left < 0 || node.rect.top < 0 || node.rect.right > 1320 || node.rect.bottom > 2868) throw Error('Text outside artboard: ' + slide.file);
    if (slide.secondary_source && JSON.stringify(geometry.sources[1]) !== JSON.stringify(slide.secondary_source_dimensions)) throw Error('Secondary image dimensions changed');
    await page.screenshot({ path: path.join(output, slide.file), type: 'png' });
    results.push({ ...slide, width: 1320, height: 2868, geometry_verified: true, render_sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(output, slide.file))).digest('hex') });
  }
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({ ...config, sources_unchanged: true, slides: results }, null, 2));
  const tiles = results.map((slide, index) => `<figure><a href="${outputName}/${escape(slide.file)}" target="_blank"><img src="${outputName}/${escape(slide.file)}" alt="${escape(slide.title)}"></a><figcaption><b>${String(index + 1).padStart(2, '0')} · ${escape(slide.title)}</b><span>${slide.attachment_number === 7 ? '你的動態島画面' : slide.attachment_number ? '你的第 ' + slide.attachment_number + ' 張' : '補充畫面'}</span></figcaption></figure>`).join('');
  const gallery = `<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>台北公車宣傳圖預覽</title>
    <style>*{box-sizing:border-box}body{margin:0;padding:36px;background:#f5f5f7;color:#17212a;font-family:"Microsoft JhengHei UI","Segoe UI",sans-serif}header{max-width:1170px;margin:0 auto 28px}h1{font-size:28px;margin:0 0 8px}p{color:#697480;margin:0;line-height:1.6}.grid{max-width:1170px;margin:auto;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:28px}figure{margin:0;min-width:0}figure img{width:100%;display:block;box-shadow:0 4px 16px #1e2b3813}figcaption{padding:12px 1px 0;font-size:14px;line-height:1.7}figcaption b{display:block;font-weight:600}figcaption span{color:#6e7985;font-size:12px}@media(max-width:700px){body{padding:22px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}}@media(max-width:430px){.grid{grid-template-columns:1fr}}</style>
    <header><h1>台北公車 · 宣傳圖預覽</h1><p>${config.overview_caption || (results.length === 10 ? '先看 3D 公車、列車與動態島，再看搭車流程。原先六張全部保留，另補動態島與三張功能畫面。' : '先看 3D 公車與列車，再看搭車流程。你的六張全部保留，另加三張補充畫面。')}</p></header><main class="grid">${tiles}</main></html>`;
  const galleryFile = path.join(root, config.preview_file || 'preview.html');
  fs.writeFileSync(galleryFile, gallery.replaceAll('動態島画面', '動態島畫面'));
  await page.setViewportSize({ width: 1242, height: 2560 });
  await page.goto(pathToFileURL(galleryFile).href);
  await page.locator('.grid img').evaluateAll(images => Promise.all(images.map(image => image.decode())));
  if (await page.locator('.grid img').count() !== results.length) throw Error('Missing gallery slide');
  await page.screenshot({ path: path.join(root, config.overview_file || 'overview.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw Error('Mobile gallery overflows');
  const href = await page.locator('figure a').first().getAttribute('href');
  await page.locator('figure a').first().evaluate(node => node.removeAttribute('target'));
  await page.locator('figure a').first().click();
  await page.waitForURL('**/01-3d-bus.png');
  await browser.close();
  console.log(`Rendered and checked ${results.length} artboards; source pixels retained; desktop/mobile preview and full-size opening passed.`);
})().catch(error => { console.error(error.message); process.exitCode = 1; });
