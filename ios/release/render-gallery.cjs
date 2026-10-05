const fs=require('fs'),path=require('path');
const {chromium}=require('playwright');
const shots=[
 ['store-07-live-bus-in-3d.png','01-live-bus.png','公車現在到哪了','點車牌，跟著這一輛看。'],
 ['store-08-bus-first-navigation.png','02-waiting.png','下一班還要等多久','先看官方時間，再看往站牌開來的車。'],
 ['store-12-in-app-walking.png','03-walking.png','走到站牌，不用換 App','路線、指引和剩餘時間，都在這裡。'],
 ['store-09-onboard-live-guidance.png','04-onboard.png','還剩幾站，多久下車','上車後繼續看同一輛公車的行程。'],
 ['store-02-trip-choices.png','05-plan.png','要去哪裡，先看怎麼搭','比較走路、候車和搭車的時間。'],
 ['store-03-route-keypad.png','06-search.png','常用路線，幾下就找到','用公車專用鍵盤找路線，也能搜站名。']
];
const escape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
(async()=>{
 const input=path.resolve(process.argv[2]),output=path.resolve(process.argv[3]);fs.mkdirSync(output,{recursive:true});
 const b=await chromium.launch({channel:'msedge',headless:true});const page=await b.newPage({viewport:{width:1320,height:2868},deviceScaleFactor:1});
 let manifest=[];
 for(const [raw,file,title,caption] of shots){
  const source=path.join(input,raw);if(!fs.existsSync(source))throw Error('Missing actual native capture '+raw);
  const png=fs.readFileSync(source);if(png.readUInt32BE(16)!==1320||png.readUInt32BE(20)!==2868)throw Error('Unexpected capture dimensions '+raw);
  const html=`<!DOCTYPE html><html lang="zh-Hant"><meta charset="utf-8"><style>
  *{box-sizing:border-box}html,body{margin:0;width:1320px;height:2868px;overflow:hidden;background:#f4f7fa}
  body{font-family:"Microsoft JhengHei UI","Microsoft JhengHei",sans-serif;color:#152334}
  .brand{position:absolute;left:96px;top:65px;font-size:30px;letter-spacing:1px;color:#627082;font-weight:500}
  h1{position:absolute;left:92px;top:121px;width:1140px;margin:0;font-size:80px;line-height:1.28;letter-spacing:-2px;font-weight:700}
  .caption{position:absolute;left:96px;top:246px;width:1128px;font-size:35px;line-height:1.4;color:#536377}
  .phone{position:absolute;left:104px;top:376px;width:1112px;height:2416px;border-radius:56px;overflow:hidden;box-shadow:0 18px 50px #283f581e,0 0 0 2px #ccd5e1;background:white}
  img{display:block;width:1112px;height:2416px;object-fit:contain}
  </style><div class="brand">台北公車動態</div><h1>${escape(title)}</h1><div class="caption">${escape(caption)}</div><div class="phone"><img src="data:image/png;base64,${png.toString('base64')}"></div></html>`;
  fs.writeFileSync(path.join(output,file.replace('.png','.html')),html);
  await page.setContent(html);await page.evaluate(()=>document.fonts.ready);await page.locator('img').evaluate(el=>el.decode());
  const result=path.join(output,file);await page.screenshot({path:result,type:'png'});
  manifest.push({file,title,caption,source:raw,source_sha256:require('crypto').createHash('sha256').update(png).digest('hex'),width:1320,height:2868});
 }
 fs.writeFileSync(path.join(output,'manifest.json'),JSON.stringify(manifest,null,2));await b.close();process.stdout.write('Rendered '+shots.length+' store artboards from unchanged native captures.\n');
})().catch(e=>{process.stderr.write(e.message);process.exitCode=1});
