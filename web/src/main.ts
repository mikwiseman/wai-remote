import './style.css';
import {b64,unb64,bytes,identity,keyID,sign,verify,proof} from './crypto';
import type {Identity} from './crypto';
import type {HostState,Mode,Operation,Point,Stroke} from './protocol';
import {iceConfiguration} from './ice';
import {installQRScanner} from './qr';

document.querySelector<HTMLDivElement>('#app')!.innerHTML=`
  <section id="welcome" class="welcome">
    <header class="wordmark">WAI Remote</header>
    <div class="intro"><h1>Подключиться к Mac</h1><p>На другом Mac откройте WAI Remote и выберите «Поделиться экраном».</p></div>
    <form id="connectForm" class="connect-form">
      <label for="invite">Приглашение</label>
      <textarea id="invite" rows="2" placeholder="Вставьте приглашение из WAI Remote" spellcheck="false" autocomplete="off"></textarea>
      <div class="form-row"><label for="deviceName">Название этого устройства</label><input id="deviceName" maxlength="50" value="Мой браузер" autocomplete="off"></div>
      <div class="connect-actions"><button id="connect" class="primary" type="submit">Подключиться</button><button id="scanQR" type="button">Сканировать QR-код</button></div>
      <a id="openNative" class="hidden" href="#">Открыть в приложении WAI Remote</a>
      <p id="connectStatus" class="status" role="status"></p><button id="cancelRetry" type="button" class="hidden">Отменить ожидание</button>
    </form>
  </section>
  <section id="session" class="session hidden">
    <header class="session-header"><div class="brand">WAI Remote</div><div id="connectionLabel" class="connection-label" role="status">Подключение…</div><button id="disconnect" class="quiet">Отключиться</button></header>
    <main id="viewport" class="viewport">
      <div id="screen" class="screen" aria-label="Удалённый экран"><video id="video" autoplay muted playsinline></video><canvas id="ink" aria-label="Рисование и управление удалённым экраном" tabindex="0"></canvas><div id="pauseBanner" class="pause-banner hidden" role="status">Управление приостановлено на Mac</div></div>
      <div id="waiting" class="waiting">Ждём изображение…</div>
    </main>
    <div id="typingPanel" class="typing-panel hidden"><label for="typing">Текст на Mac</label><textarea id="typing" rows="1" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Печатайте здесь…"></textarea><button id="hideKeyboard" class="quiet">Готово</button></div>
    <nav class="dock" aria-label="Пульт управления">
      <div class="mode-switch" role="group" aria-label="Режим"><button id="control" class="selected" aria-pressed="true">↖ <span>Управлять</span></button><button id="draw" aria-pressed="false">✎ <span>Рисовать</span></button></div>
      <div id="drawTools" class="tools hidden" role="group" aria-label="Рисование"><select id="tool" aria-label="Инструмент"><option value="pen">Перо</option><option value="marker">Маркер</option><option value="arrow">Стрелка</option><option value="laser">Лазер</option><option value="eraser">Ластик</option><option value="select">Выделить</option></select><button id="color" class="color" aria-label="Цвет: коралловый" title="Следующий цвет"></button><select id="width" aria-label="Толщина"><option value="2">Тонко</option><option value="4" selected>Средне</option><option value="8">Толсто</option></select><button id="deleteObject" class="hidden" title="Удалить выбранный объект (Delete)">Удалить</button><button id="undo" title="Отменить действие" aria-label="Отменить действие">↶</button><button id="redo" title="Повторить действие" aria-label="Повторить действие">↷</button><button id="clear" title="Удалить свои рисунки">Очистить</button></div>
      <div id="controlTools" class="tools"><button id="keyboard" aria-label="Открыть клавиатуру">⌨ <span>Клавиатура</span></button><select id="touchMode" aria-label="Управление касанием"><option value="direct">Касание</option><option value="trackpad">Трекпад</option></select><button id="rightClick" title="Правый клик">Правый клик</button></div>
      <button id="fit" class="fit" title="Вписать экран">Вписать</button>
    </nav>
    <div id="hint" class="session-hint">Перемещайте курсор одним пальцем, прокручивайте двумя. Удерживайте палец для перетаскивания.</div>
  </section>`;

function el<T extends HTMLElement=HTMLElement>(id:string){return document.getElementById(id) as T;}
const video=el<HTMLVideoElement>('video'),canvas=el<HTMLCanvasElement>('ink'),ctx=canvas.getContext('2d')!;
const typing=el<HTMLTextAreaElement>('typing');
const colors=['#E05A47','#2B77D1','#E3AE32','#4A9B71'];
let colorIndex=0;
let device:Identity;
let ws:WebSocket|undefined,pc:RTCPeerConnection|undefined,channel:RTCDataChannel|undefined;
let host:HostState|undefined,mode:Mode='control',generation=0,sequence=0;
let hostKey='',hostID='',pairSecret='',nonce='',connectionToken=0;
let heartbeat:number|undefined,ping:number|undefined,connectTimeout:number|undefined;
let retryTimer:number|undefined,interruptionTimer:number|undefined,retryDelay=1000,recoveryURL:string|undefined,lastReply=0,hasHeartbeatAck=false;
let strokes=new Map<string,Stroke>(),snapshot:Map<string,Stroke>|undefined,preview:Stroke|undefined;
let pendingStrokes=new Map<string,Stroke>();
let selectedID:string|undefined,erasePoint:Point|undefined;
const erasingIDs=new Set<string>(),pendingEraseIDs=new Set<string>();
let live=false,zoom=1,lastCursor:Point={x:.5,y:.5},activePointer:number|undefined;
let currentStrokeID:string|undefined;
let laserTrail:Array<Point & {time:number}>=[],laserFrame=0;
const touchPointers=new Map<number,{x:number;y:number}>();
let touchStart:{x:number;y:number;t:number}|undefined,dragging=false,dragButton=0,longPress:number|undefined;
let pinchDistance=0,pinchZoom=1,touchMoved=false;
let navigationGesture:'pending'|'pan'|'zoom'|undefined,navigationStart:Point|undefined;
let invalidated=false;
// Chromium reports PointerEvent.detail as 0 on pointerdown, so count clicks
// here, where they happen. Network delay must not merge or split them.
let lastPress:{x:number;y:number;t:number;button:number;count:number}|undefined;
function clickCount(event:PointerEvent,button:number){
  const now=performance.now(),slop=event.pointerType==='touch'?22:4;
  const count=lastPress&&lastPress.button===button&&now-lastPress.t<=500&&Math.hypot(event.clientX-lastPress.x,event.clientY-lastPress.y)<=slop?Math.min(lastPress.count+1,3):1;
  lastPress={x:event.clientX,y:event.clientY,t:now,button,count};return count;
}
const pressedPhysical=new Set<string>();

function updateConnectButton(){
  const text=el<HTMLTextAreaElement>('invite').value.trim();
  el<HTMLButtonElement>('connect').disabled=!text;
  const link=el<HTMLAnchorElement>('openNative');link.classList.add('hidden');
  void invitationURL(text).then(url=>{
    if(el<HTMLTextAreaElement>('invite').value.trim()!==text)return;
    link.href='wai-remote://connect?invite='+encodeURIComponent(url.href);link.classList.remove('hidden');
  }).catch(()=>{});
}
async function invitationURL(text:string){
  if(text.length>8192)throw new Error('Приглашение слишком длинное.');
  let url=new URL(text.trim());
  if(url.protocol==='wai-remote:'){
    const entries=[...url.searchParams.entries()];
    if(url.hostname!=='connect'||url.username||url.password||url.port||url.pathname||url.hash||entries.length!==1||entries[0][0]!=='invite')throw new Error('Некорректное приглашение.');
    url=new URL(entries[0][1]);
  }
  if(url.href.length>4096||url.username||url.password||url.search||!['http:','https:'].includes(url.protocol))throw new Error('Некорректное приглашение.');
  if(url.origin!==location.origin||url.pathname.replace(/\/$/,'')!==location.pathname.replace(/\/$/,''))throw new Error('Откройте приглашение в браузере по указанному в нём адресу.');
  const fields=new URLSearchParams(url.hash.slice(1)),names=[...fields.keys()];
  if(new Set(names).size!==names.length)throw new Error('Некорректное приглашение.');
  const key=fields.get('key')??'',host=fields.get('host')??'',secret=fields.get('secret');
  if(!key||unb64(key).length!==65||await keyID(key)!==host||(secret!==null&&unb64(secret).length!==32))throw new Error('Ссылка повреждена. Скопируйте новое приглашение на Mac.');
  return url;
}
el('invite').addEventListener('input',updateConnectButton);
function readInvitation(){if(location.hash){el<HTMLTextAreaElement>('invite').value=location.href;history.replaceState(null,'',location.pathname);updateConnectButton();}}
const initialHash=location.hash;
if(initialHash){readInvitation();}
else {const saved=localStorage.getItem('wai-last-host');if(saved)el<HTMLTextAreaElement>('invite').value=saved;}
window.addEventListener('hashchange',readInvitation);
updateConnectButton();
const scanQR=installQRScanner(async text=>{
  try{return (await invitationURL(text)).href;}catch{return undefined;}
},invitation=>{
  el<HTMLTextAreaElement>('invite').value=invitation;updateConnectButton();void connect();
});
el('scanQR').addEventListener('click',()=>{void scanQR();});
el<HTMLInputElement>('deviceName').value=localStorage.getItem('wai-device-name')||(matchMedia('(pointer:coarse)').matches?'Мой телефон':'Мой браузер');

function status(text:string){el('connectStatus').textContent=text;el('connectionLabel').textContent=text;}
class RetryableConnectionError extends Error {}
function fail(error:unknown){cleanup();status(error instanceof Error && !(error instanceof TypeError) && !(error instanceof DOMException) && !(error instanceof SyntaxError) && !(error instanceof RangeError)?error.message:'Не удалось подключиться. Проверьте приглашение и повторите попытку.');el<HTMLButtonElement>('connect').disabled=false;}
function recover(text:string){
  const target=recoveryURL;
  if(!target){fail(new Error(text+' Попробуйте подключиться снова.'));return;}
  cleanup(false);status(text);el<HTMLButtonElement>('connect').disabled=true;
  el('cancelRetry').classList.remove('hidden');
  const delay=retryDelay;retryDelay=Math.min(15000,retryDelay*2);
  retryTimer=window.setTimeout(()=>{retryTimer=undefined;el<HTMLTextAreaElement>('invite').value=target;void connect(true);},delay);
}
function cleanup(cancelRecovery=true){
  clearTimeout(retryTimer);retryTimer=undefined;clearTimeout(interruptionTimer);interruptionTimer=undefined;
  if(cancelRecovery){recoveryURL=undefined;retryDelay=1000;}
  hasHeartbeatAck=false;el('cancelRetry').classList.add('hidden');
  connectionToken++;live=false;host=undefined;invalidated=false;
  clearInterval(heartbeat);clearInterval(ping);clearTimeout(connectTimeout);clearTimeout(longPress);
  channel?.close();channel=undefined;pc?.close();pc=undefined;ws?.close();ws=undefined;
  video.srcObject=null;strokes.clear();pendingStrokes.clear();preview=undefined;snapshot=undefined;
  activePointer=undefined;currentStrokeID=undefined;touchPointers.clear();dragging=false;pressedPhysical.clear();selectedID=undefined;erasingIDs.clear();pendingEraseIDs.clear();laserTrail=[];
  el('session').classList.add('hidden');el('welcome').classList.remove('hidden');
  el<HTMLButtonElement>('connect').disabled=false;el('typingPanel').classList.add('hidden');
}
function signal(type:string,body?:unknown){if(ws?.readyState===WebSocket.OPEN)ws.send(JSON.stringify({type,body}));}

el('cancelRetry').addEventListener('click',()=>{cleanup();status('Вы отключились');});
el('connectForm').addEventListener('submit',event=>{event.preventDefault();void connect();});
async function connect(retrying=false){
  cleanup(!retrying);const token=connectionToken;
  try{
    const url=await invitationURL(el<HTMLTextAreaElement>('invite').value);
    if(token!==connectionToken)return;
    const fragment=new URLSearchParams(url.hash.slice(1));
    hostKey=fragment.get('key')??'';hostID=fragment.get('host')??'';pairSecret=fragment.get('secret')??'';
    if(!pairSecret)recoveryURL=url.href;
    el('cancelRetry').classList.remove('hidden');
    el<HTMLButtonElement>('connect').disabled=true;status('Подключаемся…');
    device=await identity();if(token!==connectionToken)return;
    const name=el<HTMLInputElement>('deviceName').value.trim()||'Моё устройство';localStorage.setItem('wai-device-name',name);
    const socket=new WebSocket(new URL('signal',location.href).href.replace(/^http/,'ws'));ws=socket;
    connectTimeout=window.setTimeout(()=>{if(token===connectionToken)recover('Ожидаем Mac…');},110000);
    socket.onmessage=async event=>{
      if(token!==connectionToken)return;
      try{
        if(typeof event.data!=='string'||event.data.length>180000)throw new Error('Некорректный ответ сервера');
        const m=JSON.parse(event.data);
        if(m.type==='challenge'){
          const signature=await sign(device,'wai-remote/signal/v1',bytes(`viewer\n${hostID}\n${device.id}\n${m.nonce}`));
          if(token===connectionToken)socket.send(JSON.stringify({type:'hello',role:'viewer',hostID,peerID:device.id,publicKey:device.publicKey,signature,iceVersion:2}));
        }else if(m.type==='ready'){
          ping=window.setInterval(()=>signal('ping'),20000);await createOffer(name,token,iceConfiguration(m.ice));
        }else if(m.type==='answer'&&m.from===hostID){
          const payload=unb64(m.body.payload);
          if(!await verify(hostKey,'wai-remote/answer/v1',payload,m.body.signature))throw new Error('Ключ Mac не совпал. Подключение остановлено.');
          const answer=JSON.parse(new TextDecoder().decode(payload));
          if(token!==connectionToken)return;
          if(answer.nonce!==nonce||answer.hostID!==hostID||answer.peerID!==device.id)throw new Error('Ответ не относится к этому подключению');
          await pc!.setRemoteDescription({type:'answer',sdp:answer.sdp});
          status(answer.lab?'Проверка изображения':'Подключаемся…');
          const saved=new URL(location.pathname,location.origin);saved.hash=new URLSearchParams({host:hostID,key:hostKey}).toString();localStorage.setItem('wai-last-host',saved.href);
          el<HTMLTextAreaElement>('invite').value=saved.href;pairSecret='';recoveryURL=saved.href;
        }else if(m.type==='reject'){
          if(m.body?.reason==='busy'||m.body?.reason==='network'){recover(m.body.reason==='busy'?'Mac занят. Ожидаем освобождения…':'Восстанавливаем соединение…');return;}
          throw new Error(m.body?.reason==='busy'?'На Mac уже подключено устройство. Отключите его в WAI Remote.':m.body?.reason==='new-invite-required'?'Создайте новое приглашение в WAI Remote на Mac.':'Mac отклонил подключение.');
        }else if(m.type==='unavailable'){recover('Ожидаем Mac…');return;}
      }catch(error){if(token===connectionToken){if(error instanceof RetryableConnectionError)recover(error.message);else fail(error);}}
    };
    socket.onerror=()=>{if(token===connectionToken&&!live)recover('Сервер временно недоступен…');};
    socket.onclose=()=>{if(token===connectionToken&&!live)recover('Восстанавливаем соединение…');};
  }catch(error){if(token===connectionToken){if(error instanceof RetryableConnectionError)recover(error.message);else fail(error);}}
}

async function createOffer(name:string,token:number,configuration:RTCConfiguration){
  const peer=new RTCPeerConnection(configuration);pc=peer;
  peer.addTransceiver('video',{direction:'recvonly'});
  const data=peer.createDataChannel('interaction',{ordered:true});channel=data;
  data.onmessage=event=>{if(token===connectionToken)receive(event.data);};
  data.onclose=()=>{if(token===connectionToken)recover('Восстанавливаем соединение…');};
  peer.ontrack=event=>{if(token!==connectionToken)return;video.srcObject=event.streams[0]??new MediaStream([event.track]);void video.play().catch(()=>{});};
  peer.onconnectionstatechange=()=>{
    if(token!==connectionToken)return;
    if(peer.connectionState==='failed')recover('Восстанавливаем соединение…');
    // Pause output until the host's next state; the host keeps the epoch.
    if(peer.connectionState==='disconnected'){lift();invalidated=true;el('connectionLabel').textContent='Восстанавливаем соединение…';if(!interruptionTimer)interruptionTimer=window.setTimeout(()=>{if(token===connectionToken)recover('Восстанавливаем соединение…');},5000);}
  };
  await peer.setLocalDescription(await peer.createOffer());
  await new Promise<void>((resolve,reject)=>{
    const started=performance.now();
    function finish(){
      clearInterval(timer);peer.removeEventListener('icegatheringstatechange',change);
      if(peer.localDescription?.sdp.includes('a=candidate:'))resolve();
      else reject(new RetryableConnectionError('Ищем сетевой маршрут…'));
    }
    function change(){if(peer.iceGatheringState==='complete')finish();}
    const timer=window.setInterval(()=>{
      const elapsed=performance.now()-started,sdp=peer.localDescription?.sdp??'';
      const usable=configuration.iceTransportPolicy==='relay'?sdp.includes(' typ relay'):sdp.includes('a=candidate:');
      if(elapsed>=12000||elapsed>=2000&&usable)finish();
    },100);
    peer.addEventListener('icegatheringstatechange',change);change();
  });
  if(token!==connectionToken)return;
  nonce=b64(crypto.getRandomValues(new Uint8Array(32)));
  const payload=bytes(JSON.stringify({hostID,peerID:device.id,publicKey:device.publicKey,nonce,expiresAt:Date.now()+100000,name,sdp:peer.localDescription!.sdp}));
  const body={payload:b64(payload),signature:await sign(device,'wai-remote/offer/v1',payload),proof:pairSecret?await proof(pairSecret,payload):undefined};
  if(token!==connectionToken)return;signal('offer',body);status(pairSecret?'Подтвердите подключение в WAI Remote на Mac.':'Подключаемся к Mac…');
}

function send(type:string,fields:Record<string,unknown>={}):boolean{
  if(!host||!channel||channel.readyState!=='open'||invalidated)return false;
  if(channel.bufferedAmount>128000){invalidated=true;channel.close();return false;}
  const op:Operation={v:1,type,sessionID:host.sessionID,controllerEpoch:host.controllerEpoch,inputEpoch:host.inputEpoch,modeGeneration:generation,
    surfaceID:host.surface.id,geometryRevision:host.surface.revision,layerEpoch:host.layerEpoch,operationID:crypto.randomUUID(),sequence:sequence++,...fields};
  channel.send(JSON.stringify(op));return true;
}
function receive(raw:unknown){
  if(typeof raw!=='string'||raw.length>65000){fail(new Error('Некорректное сообщение Mac'));return;}
  try{
    const m=JSON.parse(raw);lastReply=performance.now();
    if(m.type==='heartbeatAck'){hasHeartbeatAck=true;return;}
    if(m.type==='state'){
      clearTimeout(interruptionTimer);interruptionTimer=undefined;retryDelay=1000;
      const next=m.state as HostState;
      if(!Number.isSafeInteger(next.inputEpoch)||next.surface.width<=0||next.surface.height<=0||next.surface.width>32768||next.surface.height>32768)throw new Error('Некорректный экран');
      const changed=!host||next.inputEpoch!==host.inputEpoch||next.sessionID!==host.sessionID||next.controllerEpoch!==host.controllerEpoch;
      const layerChanged=host&&host.layerEpoch!==next.layerEpoch;
      if(changed){sequence=next.nextSequence;generation=next.modeGeneration;mode=next.mode;cancelGesture(false);pendingStrokes.clear();}
      else{sequence=Math.max(sequence,next.nextSequence);if(next.modeGeneration>=generation){generation=next.modeGeneration;mode=next.mode;}}
      if(layerChanged){cancelGesture(false);pendingStrokes.clear();}
      host=next;invalidated=false;
      if(!live){live=true;clearTimeout(connectTimeout);el('welcome').classList.add('hidden');el('session').classList.remove('hidden');heartbeat=window.setInterval(()=>{if(document.hidden)return;if(hasHeartbeatAck&&performance.now()-lastReply>8000)recover('Восстанавливаем соединение…');else send('heartbeat');},500);send('heartbeat');}
      updateMode();layout();
      el('connectionLabel').textContent=m.lab?'Проверка изображения':next.permissions.control?'':'Только просмотр';
    }else if(m.type==='ink'){
      const op=m.op;const id=op.strokeID as string;
      if(op.type==='strokeBegin')strokes.set(id,{id,author:m.author,tool:op.tool,color:op.color,width:op.width,points:op.points,complete:false});
      if(op.type==='strokeAppend'){const s=strokes.get(id);if(s){if(s.tool==='arrow')s.points=[s.points[0],op.points.at(-1)];else s.points.push(...op.points);}}
      if(op.type==='strokeEnd'){const s=strokes.get(id);if(s)s.complete=true;pendingStrokes.delete(id);}
      if(op.type==='strokeCancel'){strokes.delete(id);pendingStrokes.delete(id);}
      render();
    }else if(m.type==='laser'){if(activePointer===undefined)showLaser(m.point);}
    else if(m.type==='snapshotBegin'){snapshot=new Map();}
    else if(m.type==='snapshotStroke'){snapshot?.set(m.stroke.id,m.stroke);}
    else if(m.type==='snapshotPoints'){snapshot?.get(m.id)?.points.push(...m.points);}
    else if(m.type==='snapshotEnd'){if(snapshot){for(const stroke of snapshot.values())stroke.complete=true;strokes=snapshot;snapshot=undefined;}pendingEraseIDs.clear();if(selectedID&&!strokes.has(selectedID))selectedID=undefined;updateTools();render();}
  }catch(error){fail(error);}
}

function updateMode(){
  for(const value of ['control','draw'] as const){el(value).classList.toggle('selected',mode===value);el(value).setAttribute('aria-pressed',String(mode===value));}
  el('control').textContent=host?.permissions.control?'Управлять':'Смотреть';
  el<HTMLButtonElement>('control').disabled=!host||mode==='paused';
  el<HTMLButtonElement>('draw').disabled=!host?.permissions.annotate||mode==='paused';
  el('drawTools').classList.toggle('hidden',mode!=='draw');el('controlTools').classList.toggle('hidden',mode!=='control'||!host?.permissions.control);
  el('pauseBanner').classList.toggle('hidden',mode!=='paused');canvas.classList.toggle('drawing',mode==='draw');
  el('hint').textContent=mode==='paused'?'Управление приостановлено на Mac.':mode==='control'&&host?.permissions.control?'Коснитесь экрана для щелчка. Прокручивайте двумя пальцами, удерживайте палец для перетаскивания.':'';
  if(mode!=='draw')selectedID=undefined;updateTools();
  if(mode!=='control'){typing.blur();el('typingPanel').classList.add('hidden');}
}
function switchMode(next:Mode){
  if(!host||mode==='paused'||(next==='draw'&&!host.permissions.annotate))return;
  cancelGesture(true);mode=next;generation++;send('mode',{mode:next});updateMode();
}
el('control').onclick=()=>switchMode('control');el('draw').onclick=()=>switchMode('draw');
el('tool').onchange=()=>{cancelGesture(true);selectedID=undefined;updateTools();render();};
el('deleteObject').onclick=()=>{if(selectedID)eraseObjects([selectedID]);};
el('undo').onclick=()=>{cancelGesture(true);send('undo');};el('redo').onclick=()=>{cancelGesture(true);send('redo');};el('clear').onclick=()=>{cancelGesture(true);send('clear');};
el('color').onclick=()=>{colorIndex=(colorIndex+1)%colors.length;el('color').style.backgroundColor=colors[colorIndex];el('color').setAttribute('aria-label','Цвет: '+['коралловый','синий','жёлтый','зелёный'][colorIndex]);};
el('disconnect').onclick=()=>{release();cleanup();status('');};
el('fit').onclick=()=>{zoom=1;layout();};
el('keyboard').onclick=()=>{if(mode==='control'){el('typingPanel').classList.remove('hidden');typing.focus();}};
el('hideKeyboard').onclick=()=>{typing.blur();el('typingPanel').classList.add('hidden');};
el('rightClick').onclick=()=>{if(mode==='control'){send('pointer',{action:'down',...lastCursor,button:2});send('pointer',{action:'up',...lastCursor,button:2});}};

function layout(){
  if(!host)return;
  const area=el('viewport'),screen=el('screen'),ratio=host.surface.width/host.surface.height;
  const width=Math.max(1,Math.min(area.clientWidth-32,(area.clientHeight-32)*ratio))*zoom;
  screen.style.width=width+'px';screen.style.height=width/ratio+'px';
  const dpr=Math.min(devicePixelRatio,2);canvas.width=Math.round(width*dpr);canvas.height=Math.round(width/ratio*dpr);render();
}
new ResizeObserver(layout).observe(el('viewport'));
video.addEventListener('loadeddata',()=>el('waiting').classList.add('hidden'));
function paint(stroke:Stroke){
  if(!stroke.points.length||!host)return;
  ctx.beginPath();ctx.strokeStyle=stroke.color;ctx.fillStyle=stroke.color;ctx.globalAlpha=stroke.tool==='marker'?.32:1;
  ctx.lineWidth=stroke.width*canvas.width/host.surface.width*(stroke.tool==='marker'?3:1);ctx.lineCap='round';ctx.lineJoin='round';
  const points=stroke.points;ctx.moveTo(points[0].x*canvas.width,points[0].y*canvas.height);
  for(const point of points.slice(1))ctx.lineTo(point.x*canvas.width,point.y*canvas.height);
  if(points.length===1)ctx.lineTo(points[0].x*canvas.width+.1,points[0].y*canvas.height);ctx.stroke();
  if(stroke.tool==='arrow'&&points.length>1){const a=points[0],b=points.at(-1)!;const x=b.x*canvas.width,y=b.y*canvas.height,angle=Math.atan2((b.y-a.y)*canvas.height,(b.x-a.x)*canvas.width),len=Math.max(10*devicePixelRatio,ctx.lineWidth*4);ctx.beginPath();ctx.moveTo(x-len*Math.cos(angle-.45),y-len*Math.sin(angle-.45));ctx.lineTo(x,y);ctx.lineTo(x-len*Math.cos(angle+.45),y-len*Math.sin(angle+.45));ctx.stroke();}
  ctx.globalAlpha=1;
}
function render(){ctx.clearRect(0,0,canvas.width,canvas.height);for(const stroke of strokes.values())if(!pendingStrokes.has(stroke.id)&&preview?.id!==stroke.id&&!erasingIDs.has(stroke.id)&&!pendingEraseIDs.has(stroke.id))paint(stroke);for(const stroke of pendingStrokes.values())if(preview?.id!==stroke.id)paint(stroke);if(preview)paint(preview);
  if(selectedID){const stroke=strokes.get(selectedID);if(stroke&&!pendingEraseIDs.has(selectedID))paintSelection(stroke);}
  const now=performance.now();laserTrail=laserTrail.filter(p=>now-p.time<800);
  for(const p of laserTrail){ctx.globalAlpha=1-(now-p.time)/800;ctx.fillStyle=colors[0];ctx.beginPath();ctx.arc(p.x*canvas.width,p.y*canvas.height,Math.max(3,5*canvas.width/(host?.surface.width??1280)),0,2*Math.PI);ctx.fill();}ctx.globalAlpha=1;
  if(laserTrail.length&&!laserFrame)laserFrame=requestAnimationFrame(()=>{laserFrame=0;render();});
}
function showLaser(p:Point){laserTrail.push({...p,time:performance.now()});if(laserTrail.length>50)laserTrail.shift();render();}
function updateTools(){
  const tool=el<HTMLSelectElement>('tool').value,inkTool=['pen','marker','arrow'].includes(tool);
  el('color').classList.toggle('hidden',!inkTool);el('width').classList.toggle('hidden',!inkTool);
  el('deleteObject').classList.toggle('hidden',!selectedID);
  canvas.classList.toggle('selecting',mode==='draw'&&tool==='select');
  if(mode==='draw')el('hint').textContent=tool==='eraser'?'Проведите по рисунку, чтобы удалить его целиком. Для отмены нажмите ⌘Z.':tool==='select'?'Коснитесь рисунка и нажмите «Удалить». Нажмите Esc, чтобы снять выделение.':'Меняйте масштаб двумя пальцами. Для отмены рисунка нажмите ⌘Z.';
}
function segmentDistance(p:Point,a:Point,b:Point){
  const dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy;
  const t=length?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)):0;
  return Math.hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);
}
function hitObject(p:Point):Stroke|undefined{
  if(!host)return;
  const r=canvas.getBoundingClientRect(),point={x:p.x*r.width,y:p.y*r.height};
  for(const stroke of [...strokes.values()].reverse()){
    if(stroke.author!==device.id||!stroke.complete||erasingIDs.has(stroke.id)||pendingEraseIDs.has(stroke.id))continue;
    const pts=stroke.points.map(q=>({x:q.x*r.width,y:q.y*r.height}));
    const width=stroke.width*r.width/host.surface.width*(stroke.tool==='marker'?3:1),radius=10+width/2;
    if(pts.length===1&&Math.hypot(point.x-pts[0].x,point.y-pts[0].y)<=radius)return stroke;
    if(stroke.tool==='arrow'&&pts.length>1){const a=pts[0],b=pts.at(-1)!,angle=Math.atan2(b.y-a.y,b.x-a.x),length=Math.max(10,width*4);pts.push({x:b.x-length*Math.cos(angle-.45),y:b.y-length*Math.sin(angle-.45)},b,{x:b.x-length*Math.cos(angle+.45),y:b.y-length*Math.sin(angle+.45)});}
    for(let i=1;i<pts.length;i++)if(segmentDistance(point,pts[i-1],pts[i])<=radius)return stroke;
  }
}
function eraseAt(p:Point){
  const from=erasePoint??p,r=canvas.getBoundingClientRect(),steps=Math.max(1,Math.ceil(Math.hypot((p.x-from.x)*r.width,(p.y-from.y)*r.height)/5));
  for(let i=1;i<=steps&&erasingIDs.size<50;i++){const hit=hitObject({x:from.x+(p.x-from.x)*i/steps,y:from.y+(p.y-from.y)*i/steps});if(hit)erasingIDs.add(hit.id);}
  erasePoint=p;render();
}
function eraseObjects(ids:string[]){
  if(mode!=='draw'||!ids.length)return;
  if(send('erase',{strokeIDs:ids})){for(const id of ids)pendingEraseIDs.add(id);selectedID=undefined;updateTools();render();}
}
function paintSelection(stroke:Stroke){
  if(!stroke.points.length)return;
  let left=1,top=1,right=0,bottom=0;for(const p of stroke.points){left=Math.min(left,p.x);top=Math.min(top,p.y);right=Math.max(right,p.x);bottom=Math.max(bottom,p.y);}
  const scale=canvas.width/canvas.getBoundingClientRect().width,padding=12*scale;
  ctx.save();ctx.strokeStyle='#2B77D1';ctx.lineWidth=1.5*scale;ctx.setLineDash([5*scale,4*scale]);
  ctx.strokeRect(left*canvas.width-padding,top*canvas.height-padding,(right-left)*canvas.width+padding*2,(bottom-top)*canvas.height+padding*2);ctx.restore();
}
function locationPoint(event:PointerEvent):Point{const r=canvas.getBoundingClientRect();return{x:Math.min(1,Math.max(0,(event.clientX-r.left)/r.width)),y:Math.min(1,Math.max(0,(event.clientY-r.top)/r.height))};}
function cancelGesture(notify:boolean){
  clearTimeout(longPress);
  if(currentStrokeID&&notify)send('strokeCancel',{strokeID:currentStrokeID});
  if(dragging&&notify)send('pointer',{action:'up',...lastCursor,button:dragButton});
  if(activePointer!==undefined&&canvas.hasPointerCapture(activePointer))canvas.releasePointerCapture(activePointer);
  activePointer=undefined;currentStrokeID=undefined;preview=undefined;dragging=false;touchPointers.clear();touchStart=undefined;navigationGesture=undefined;navigationStart=undefined;erasingIDs.clear();erasePoint=undefined;render();
}
// The explicit release starts a new host epoch; only disconnect uses it.
function release(){if(host&&live){cancelGesture(true);send('release');invalidated=true;pressedPhysical.clear();}}
// Focus loss ends only what this viewer holds and keeps the session valid,
// so the first click after returning needs no round trip to the host.
function lift(){if(host&&live){cancelGesture(true);for(const key of pressedPhysical)send('key',{action:'up',key,modifiers:[]});pressedPhysical.clear();}}
canvas.addEventListener('contextmenu',event=>event.preventDefault());
canvas.addEventListener('pointerdown',event=>{
  if(!host||mode==='paused'||invalidated)return;event.preventDefault();
  canvas.setPointerCapture(event.pointerId);
  if(event.pointerType==='touch'){
    touchPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
    if(touchPointers.size>=2){clearTimeout(longPress);erasingIDs.clear();erasePoint=undefined;activePointer=undefined;touchStart=undefined;touchMoved=true;if(currentStrokeID&&preview){pendingStrokes.set(preview.id,preview);send('strokeEnd',{strokeID:currentStrokeID});preview=undefined;currentStrokeID=undefined;render();}if(dragging){send('pointer',{action:'up',...lastCursor,button:0});dragging=false;}const p=[...touchPointers.values()];pinchDistance=Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y);pinchZoom=zoom;navigationGesture='pending';navigationStart={x:(p[0].x+p[1].x)/2,y:(p[0].y+p[1].y)/2};return;}
  }
  activePointer=event.pointerId;
  if(mode==='draw'){
    canvas.focus({preventScroll:true});const tool=el<HTMLSelectElement>('tool').value;
    if(tool==='select'){selectedID=hitObject(locationPoint(event))?.id;updateTools();render();return;}
    selectedID=undefined;updateTools();
    if(tool==='eraser'){eraseAt(locationPoint(event));return;}
    if(tool==='laser'){const p=locationPoint(event);showLaser(p);send('laser',p as unknown as Record<string,unknown>);return;}
    const p=locationPoint(event);currentStrokeID=crypto.randomUUID();
    preview={id:currentStrokeID,author:device.id,tool:el<HTMLSelectElement>('tool').value as Stroke['tool'],color:colors[colorIndex],width:Number(el<HTMLSelectElement>('width').value),points:[p],complete:false};
    if(!send('strokeBegin',{strokeID:preview.id,tool:preview.tool,color:preview.color,width:preview.width,points:[p]})){cancelGesture(false);return;}render();
  }else if(event.pointerType==='touch'){
    touchStart={x:event.clientX,y:event.clientY,t:performance.now()};touchMoved=false;
    if(el<HTMLSelectElement>('touchMode').value==='direct')lastCursor=locationPoint(event);
    longPress=window.setTimeout(()=>{if(touchPointers.size===1&&mode==='control'){dragging=true;dragButton=0;send('pointer',{action:'down',...lastCursor,button:0});}},400);
  }else{
    if(!matchMedia('(pointer:coarse)').matches){el('typingPanel').classList.add('hidden');typing.focus({preventScroll:true});}
    lastCursor=locationPoint(event);send('pointer',{action:'down',...lastCursor,button:event.button,modifiers:modifiers(event),clickCount:clickCount(event,event.button)});dragging=true;dragButton=event.button;
  }
});
canvas.addEventListener('pointermove',event=>{
  if(!host||mode==='paused'||invalidated)return;
  const old=touchPointers.get(event.pointerId);
  if(old){
    touchPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
    if(touchPointers.size>=2){
      const p=[...touchPointers.values()];const distance=Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y);
      if(navigationGesture==='pending'){
        if(pinchDistance&&Math.abs(distance/pinchDistance-1)>.08)navigationGesture='zoom';
        else if(navigationStart&&Math.hypot((p[0].x+p[1].x)/2-navigationStart.x,(p[0].y+p[1].y)/2-navigationStart.y)>8)navigationGesture='pan';
        else return;
      }
      if(navigationGesture==='zoom'){zoom=Math.max(1,Math.min(3,pinchZoom*distance/pinchDistance));layout();}
      else if(mode==='control')send('pointer',{action:'scroll',...lastCursor,deltaX:(old.x-event.clientX)*1.5,deltaY:(old.y-event.clientY)*1.5});
      else {el('viewport').scrollLeft+=old.x-event.clientX;el('viewport').scrollTop+=old.y-event.clientY;}return;
    }
    if(navigationGesture)return; // A remaining finger must lift before beginning a new click or stroke.
  }
  if(mode==='draw'&&el<HTMLSelectElement>('tool').value==='eraser'&&activePointer===event.pointerId){eraseAt(locationPoint(event));}
  else if(mode==='draw'&&el<HTMLSelectElement>('tool').value==='laser'&&activePointer===event.pointerId){const p=locationPoint(event);showLaser(p);send('laser',p as unknown as Record<string,unknown>);}
  else if(mode==='draw'&&preview&&activePointer===event.pointerId){
    const points=(event.getCoalescedEvents?.()??[event]).map(locationPoint);if(!points.length)points.push(locationPoint(event));
    if(preview.tool==='arrow')preview.points=[preview.points[0],points.at(-1)!];else preview.points.push(...points);
    for(let start=0;start<points.length;start+=128)send('strokeAppend',{strokeID:preview.id,points:points.slice(start,start+128)});render();
  }else if(mode==='control'){
    if(old){
      if(touchStart&&Math.hypot(event.clientX-touchStart.x,event.clientY-touchStart.y)>6){touchMoved=true;if(!dragging)clearTimeout(longPress);}
      if(el<HTMLSelectElement>('touchMode').value==='direct')lastCursor=locationPoint(event);
      else {const r=canvas.getBoundingClientRect();lastCursor={x:Math.min(1,Math.max(0,lastCursor.x+(event.clientX-old.x)/r.width)),y:Math.min(1,Math.max(0,lastCursor.y+(event.clientY-old.y)/r.height))};}
    }else if(event.pointerType!=='touch')lastCursor=locationPoint(event);else return;
    send('pointer',{action:'move',...lastCursor,modifiers:modifiers(event)});
  }
});
canvas.addEventListener('pointerup',event=>{
  clearTimeout(longPress);const count=touchPointers.size;touchPointers.delete(event.pointerId);
  if(!touchPointers.size){navigationGesture=undefined;navigationStart=undefined;}
  if(activePointer===event.pointerId){
    if(mode==='draw'&&el<HTMLSelectElement>('tool').value==='eraser'){const ids=[...erasingIDs];erasingIDs.clear();erasePoint=undefined;eraseObjects(ids);}
    else if(preview){const stroke=preview;pendingStrokes.set(stroke.id,stroke);send('strokeEnd',{strokeID:stroke.id});preview=undefined;currentStrokeID=undefined;}
    else if(mode==='control'&&count<2){
      if(event.pointerType==='touch'&&!dragging&&!touchMoved&&touchStart&&performance.now()-touchStart.t<500){send('pointer',{action:'down',...lastCursor,button:0,clickCount:clickCount(event,0)});send('pointer',{action:'up',...lastCursor,button:0});}
      else if(dragging)send('pointer',{action:'up',...lastCursor,button:event.pointerType==='touch'?0:event.button,modifiers:modifiers(event)});
    }
    activePointer=undefined;dragging=false;touchStart=undefined;
  }
  if(canvas.hasPointerCapture(event.pointerId))canvas.releasePointerCapture(event.pointerId);render();
});
canvas.addEventListener('pointercancel',()=>lift());
canvas.addEventListener('wheel',event=>{if(mode==='control'&&host){event.preventDefault();send('pointer',{action:'scroll',...locationPoint(event as unknown as PointerEvent),deltaX:Math.max(-2000,Math.min(2000,event.deltaX)),deltaY:Math.max(-2000,Math.min(2000,event.deltaY)),modifiers:modifiers(event)});}},{passive:false});

function sendText(text:string){
  if(text.includes('\0'))return;
  let chunk='';
  for(const scalar of text){
    if(chunk.length+scalar.length>4096){if(!send('text',{text:chunk}))return;chunk='';}
    chunk+=scalar;
  }
  if(chunk)send('text',{text:chunk});
}
let composing=false,skipComposition:string|undefined;
typing.addEventListener('compositionstart',()=>{composing=true;});
typing.addEventListener('compositionend',event=>{composing=false;if(mode==='control'&&event.data){sendText(event.data);skipComposition=event.data;}typing.value='';});
typing.addEventListener('beforeinput',event=>{
  if(mode!=='control'||composing||event.isComposing)return;
  if(event.inputType==='insertText'||event.inputType==='insertFromPaste'||event.inputType==='insertCompositionText'){
    event.preventDefault();if(event.data&&event.data!==skipComposition)sendText(event.data);skipComposition=undefined;typing.value='';
  }
  if(event.inputType==='deleteContentBackward'||event.inputType==='insertLineBreak'||event.inputType==='insertParagraph'){
    event.preventDefault();const key=event.inputType==='deleteContentBackward'?'Backspace':'Enter';send('key',{action:'down',key,modifiers:[]});send('key',{action:'up',key,modifiers:[]});
  }
});
typing.addEventListener('paste',event=>{event.preventDefault();const text=event.clipboardData?.getData('text/plain');if(mode==='control'&&text)sendText(text);});
const modifiers=(event:KeyboardEvent|MouseEvent)=>[event.metaKey?'Meta':'',event.ctrlKey?'Control':'',event.altKey?'Alt':'',event.shiftKey?'Shift':''].filter(Boolean);
typing.addEventListener('keydown',event=>{
  if(mode!=='control'||composing||event.isComposing||event.key==='Dead'||event.key==='Unidentified')return;
  if(event.key.length>1||event.metaKey||event.ctrlKey||event.altKey){
    if(event.code==='KeyV'&&(event.metaKey||event.ctrlKey))return;
    event.preventDefault();if(send('key',{action:'down',key:event.code,modifiers:modifiers(event)}))pressedPhysical.add(event.code);
  }
});
typing.addEventListener('keyup',event=>{if(pressedPhysical.has(event.code)){event.preventDefault();send('key',{action:'up',key:event.code,modifiers:modifiers(event)});pressedPhysical.delete(event.code);}});
document.addEventListener('keydown',event=>{
  if(!live||mode!=='draw')return;
  if((event.metaKey||event.ctrlKey)&&event.code==='KeyZ'){event.preventDefault();cancelGesture(true);send(event.shiftKey?'redo':'undo');}
  else if(event.key==='Delete'||event.key==='Backspace'){event.preventDefault();if(selectedID)eraseObjects([selectedID]);}
  else if(event.key==='Escape'){event.preventDefault();if(activePointer!==undefined){cancelGesture(true);}else if(selectedID){selectedID=undefined;updateTools();render();}else switchMode('control');}
});
window.addEventListener('blur',()=>lift());document.addEventListener('visibilitychange',()=>{if(document.hidden)lift();});window.addEventListener('pagehide',()=>{release();cleanup();});
