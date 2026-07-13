const port = Number(process.argv[2] || 9223);
const targetUrl = process.argv[3];
const clickTexts = process.argv[4]?.split('|||').filter(Boolean) ?? [];
const promptValue = process.argv[5];
const probePaths = process.argv[6]?.split('|||').filter(Boolean) ?? [];
const writeRoot = process.argv[7];
const grantLocalNetwork = process.argv.includes('--grant-local-network');
if (!targetUrl) throw new Error('usage: node edge-smoke.mjs <port> <url>');

const deadline = Date.now() + 15000;
let version;
while (Date.now() < deadline) {
  try {
    version = await fetch(`http://127.0.0.1:${port}/json/version`).then(r => r.json());
    break;
  } catch {
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}
if (!version) throw new Error('Edge debugging endpoint did not start');

const target = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent('about:blank')}`, {method:'PUT'}).then(r => r.json());
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, {once:true});
  ws.addEventListener('error', reject, {once:true});
});

let id = 0;
const pending = new Map();
const failures = [];
const responses = [];
const dialogs = [];
ws.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    const {resolve, reject} = pending.get(message.id);
    pending.delete(message.id);
    message.error ? reject(new Error(message.error.message)) : resolve(message.result);
  }
  if (message.method === 'Network.loadingFailed') failures.push(message.params);
  if (message.method === 'Page.javascriptDialogOpening') {
    dialogs.push(message.params);
    if (promptValue != null) void send('Page.handleJavaScriptDialog', {accept:true, promptText:promptValue});
  }
  if (message.method === 'Network.responseReceived' && message.params.response.url.includes('rsp.tail681937.ts.net')) {
    responses.push({url:message.params.response.url,status:message.params.response.status,headers:message.params.response.headers});
  }
});
function send(method, params={}) {
  const messageId = ++id;
  return new Promise((resolve, reject) => {
    pending.set(messageId, {resolve, reject});
    ws.send(JSON.stringify({id:messageId, method, params}));
  });
}

await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');
if (grantLocalNetwork) {
  await send('Browser.setPermission', {
    permission:{name:'localNetwork'},
    setting:'granted',
    origin:new URL(targetUrl).origin,
  });
}
await send('Page.navigate', {url:targetUrl});
for (const clickText of clickTexts) {
  await new Promise(resolve => setTimeout(resolve, 1500));
  await send('Runtime.evaluate', {
    expression: `(() => { const token=${JSON.stringify(clickText)}; const button = token.startsWith('title:') ? (() => { const [title,scope]=token.slice(6).split('|'); const buttons=[...document.querySelectorAll('button')].filter(x=>x.title===title); return scope ? buttons.find(x=>x.closest('article')?.innerText.includes(scope)) : buttons[0]; })() : [...document.querySelectorAll('button')].find(x => x.innerText.includes(token)); if (button) { button.click(); return 'button'; } const card = [...document.querySelectorAll('article')].find(x => x.innerText.includes(token)); if (card) { card.dispatchEvent(new MouseEvent('dblclick', {bubbles:true})); return 'card'; } throw new Error('target not found'); })()`,
    awaitPromise: true,
  });
}
await new Promise(resolve => setTimeout(resolve, 12000));
let probes = [];
if (probePaths.length) {
  const result = await send('Runtime.evaluate', {
    expression: `Promise.all(${JSON.stringify(probePaths)}.map(async path => { const response = await fetch(path, {headers:{Range:'bytes=0-63'}}); const body = await response.arrayBuffer(); return {path,status:response.status,type:response.headers.get('content-type'),range:response.headers.get('content-range'),bytes:body.byteLength}; }))`,
    awaitPromise: true,
    returnByValue: true,
  });
  probes = result.result.value;
}
let writes = null;
if (writeRoot) {
  const result = await send('Runtime.evaluate', {
    expression: `(async () => {
      const root = ${JSON.stringify(writeRoot)};
      const json = async (path, body) => { const r = await fetch('/api/v1'+path,{method:'POST',headers:{'Content-Type':'application/json','X-MyNAS-Request':'1'},body:JSON.stringify(body)}); return {status:r.status,body:await r.text()}; };
      const out = {}; try {
      const testName = 'browser-'+Date.now()+'.txt'; const created = await json('/uploads',{path:root,name:testName,size:12}); out.create=created.status;
      const session = JSON.parse(created.body);
      const chunk = await fetch('/api/v1/uploads/'+session.id,{method:'PATCH',headers:{'X-MyNAS-Request':'1','X-Upload-Offset':'0'},body:'from browser'}); out.chunk=chunk.status;
      for(let i=0;i<20;i++){ const s=await fetch('/api/v1/uploads/'+session.id).then(r=>r.json()); if(s.status==='completed') break; await new Promise(r=>setTimeout(r,100)); }
      const source=root+'/'+testName;
      out.copy=(await json('/operations',{action:'copy',from:source,to:root+'/copy.txt',conflict:'rename'})).status;
      out.rename=(await json('/operations',{action:'rename',from:root+'/copy.txt',to:root+'/renamed.txt',conflict:'rename'})).status;
      out.move=(await json('/operations',{action:'move',from:root+'/renamed.txt',to:root+'/浏览器新建目录/renamed.txt',conflict:'rename'})).status;
      out.delete=(await json('/operations',{action:'delete',from:source})).status;
      const trash=await fetch('/api/v1/trash').then(r=>r.json()); const item=trash.find(x=>x.original===source); out.trash=!!item;
      out.restore=(await json('/trash',{id:item.id,action:'restore'})).status;
      out.deleteAgain=(await json('/operations',{action:'delete',from:source})).status;
      const trashAgain=await fetch('/api/v1/trash').then(r=>r.json()); const itemAgain=trashAgain.find(x=>x.original===source); out.purge=(await json('/trash',{id:itemAgain.id,action:'purge'})).status;
      } catch (error) { out.error = String(error); } return out;
    })()`,
    awaitPromise: true,
    returnByValue: true,
  });
  writes = result.result.value;
}
const evaluated = await send('Runtime.evaluate', {
  expression:`JSON.stringify({url:location.href,title:document.title,text:document.body?.innerText||'',script:document.querySelector('script')?.src||'',cards:[...document.querySelectorAll('article')].map(x=>({text:x.innerText,className:x.className}))})`,
  returnByValue:true,
});
const page = JSON.parse(evaluated.result.value);
console.log(JSON.stringify({page,probes,writes,responses,dialogs,failures:failures.slice(-10)}, null, 2));
await send('Browser.close').catch(() => {});
