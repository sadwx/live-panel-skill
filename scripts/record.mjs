// Usage: node record.mjs panel.html out.mp4 [seconds=20] [dark|light=dark]
// Needs: npm i playwright  (+ a Chromium: `npx playwright install chromium`, or set CHROME=/path/to/chrome) and ffmpeg on PATH.
// Captures frames with the Chrome DevTools screencast, then encodes an H.264 mp4 (X / LinkedIn / Keynote ready).
import { chromium } from 'playwright'; import { execSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'; import { resolve } from 'node:path';
const [,, inFile, outFile='panel.mp4', secs='20', theme='dark'] = process.argv;
const W=1200, H=960, dir=resolve('.frames'); rmSync(dir,{recursive:true,force:true}); mkdirSync(dir);
const b = await chromium.launch({ executablePath: process.env.CHROME || undefined });
const p = await b.newPage({ viewport:{width:W,height:H}, colorScheme:theme, deviceScaleFactor:2 });
await p.goto('file://'+resolve(inFile)); await p.waitForTimeout(800);
const cdp = await p.context().newCDPSession(p); const frames=[];
cdp.on('Page.screencastFrame', async ({data, sessionId, metadata}) => {
  const i=frames.length; writeFileSync(`${dir}/f${String(i).padStart(5,'0')}.jpg`, Buffer.from(data,'base64'));
  frames.push(metadata.timestamp); await cdp.send('Page.screencastFrameAck',{sessionId}).catch(()=>{});
});
await cdp.send('Page.startScreencast',{format:'jpeg',quality:92,maxWidth:W*2,maxHeight:H*2,everyNthFrame:1});
await p.waitForTimeout(+secs*1000); await cdp.send('Page.stopScreencast'); await b.close();
// concat list with real frame durations (screencast only emits frames when pixels change)
let list=''; for(let i=0;i<frames.length;i++){const d=i<frames.length-1?frames[i+1]-frames[i]:1/30; list+=`file 'f${String(i).padStart(5,'0')}.jpg'\nduration ${Math.max(d,1/60).toFixed(4)}\n`;}
writeFileSync(`${dir}/list.txt`, list);
execSync(`ffmpeg -y -f concat -safe 0 -i "${dir}/list.txt" -vf "fps=30,scale=${W*2}:-2" -c:v libx264 -pix_fmt yuv420p -crf 19 -movflags +faststart "${outFile}"`, {stdio:'pipe'});
console.log(`wrote ${outFile} (${frames.length} frames, ${secs}s)`);
