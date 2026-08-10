/* Wall playback — shared core: time model, fleet, procedural scenes, strings.
   One composited stream is the architecture, so nothing here is per-cell playback state —
   only per-cell AVAILABILITY, which is the field we are asking the backend for. */
const S=1000,MIN=60*S,HR=60*MIN,DAY=24*HR;
const NOW=new Date(2026,7,10,11,53,3).getTime();
const dayStart=t=>{const d=new Date(t);d.setHours(0,0,0,0);return d.getTime();};
const TODAY=dayStart(NOW),RET=35,RET0=TODAY-(RET-1)*DAY;
const pad=(n,w)=>String(n).padStart(w||2,'0');
const hms=t=>{const d=new Date(t);return pad(d.getHours())+':'+pad(d.getMinutes())+':'+pad(d.getSeconds());};
const hm=t=>{const d=new Date(t);return pad(d.getHours())+':'+pad(d.getMinutes());};
const ms3=t=>pad(new Date(t).getMilliseconds(),3);
const MO={EN:['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
  RU:['янв','фев','мар','апр','май','июн','июл','авг','сен','окт','ноя','дек']};
const WD={EN:['Sun','Mon','Tue','Wed','Thu','Fri','Sat'],RU:['Вс','Пн','Вт','Ср','Чт','Пт','Сб']};
const WD1={EN:['S','M','T','W','T','F','S'],RU:['В','П','В','С','Ч','П','С']};
const dmy=(t,L)=>{const d=new Date(t);return d.getDate()+' '+MO[L][d.getMonth()]+' '+d.getFullYear();};
const dm=(t,L)=>{const d=new Date(t);return d.getDate()+' '+MO[L][d.getMonth()];};
const wdy=(t,L)=>WD[L][new Date(t).getDay()];
const durTxt=(x,L)=>{const s=Math.max(0,Math.round(x/1000)),h=s/3600|0,m=(s%3600)/60|0,ss=s%60;
  return (h?h+(L==='RU'?'ч ':'h '):'')+(h||m?m+(L==='RU'?'м ':'m '):'')+ss+(L==='RU'?'с':'с'==='с'?'s':'s');};
const ruPl=(n,a,b,c)=>{const m=n%100;if(m>=11&&m<=14)return c;const d=n%10;return d===1?a:(d>=2&&d<=4)?b:c;};

/* ── fleet ── */
const M={A:'HiWatch DS-I202(E)',B:'HiWatch DS-I456Z(B)',C:'HiWatch DS-I402(D)',D:'HiWatch DS-I453M(C)',E:'HiWatch DS-I259M(C)'};
const OUT=[135,147,148,149,150,151,152,153,154,155,156,157,161,163];
const LIFT=[158,159,160];
const INS=[101,103,104,106,107,108,109,132,133,134,137,138,139,140,141,142,143,144,145,146,162,170];
function mk(oct,g){const i=oct%5;return {oct,group:g,ip:'192.168.1.'+oct,
  model:g==='outside'?(i<2?M.B:i<4?M.C:M.D):g==='lift'?M.E:M.A};}
const ROSTER=[...INS.map(o=>mk(o,'inside')),...LIFT.map(o=>mk(o,'lift')),...OUT.map(o=>mk(o,'outside'))]
  .sort((a,b)=>a.oct-b.oct);
const GROUPS=[{id:'all',n:ROSTER.length},{id:'inside',n:INS.length},{id:'lift',n:LIFT.length},
  {id:'outside',n:OUT.length},{id:'roof',n:0}];
const WALL_DEFAULT=[155,147,153,163,150,152,154,156,149,157,148,135,161,151,null,null];
const segCache=new Map();

/* motion-triggered recording: short runs, long dead air. This is why 12 of 16 cells are dark.
   Parameterised by DUTY CYCLE, not gap probability — the lit-cell ratio is the thing the design
   is answering for, so it has to be the thing the data model controls. */
function segsFor(oct,a,b,density){
  const key=oct+'|'+a+'|'+b+'|'+density;if(segCache.has(key))return segCache.get(key);
  const duty=density==='sparse'?0.12:density==='busy'?0.55:0.28;
  let s=(oct*2654435761+Math.floor(a/MIN))%2147483647,r=()=>((s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff);
  const out=[];let t=a-r()*12*MIN;
  while(t<b){const on=(10+r()*90)*S;
    const gap=on*(1/duty-1)*(0.45+r()*1.1);
    if(t+on>a)out.push([Math.max(a,t),Math.min(b,t+on)]);
    t+=on+gap;}
  const res=out.filter(([x,y])=>y>x);segCache.set(key,res);return res;}

const motCache=new Map();
function motionFor(oct,a,b,density){
  const key=oct+'|'+a+'|'+b+'|'+density;if(motCache.has(key))return motCache.get(key);
  const n=density==='quiet'?7:density==='heavy'?52:20;
  let s=(oct*40503+Math.floor(a/MIN)*7)%2147483647,r=()=>((s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff);
  const out=[];for(let i=0;i<n;i++){const at=a+r()*(b-a);out.push([at,at+(2+r()*40)*S,.35+r()*.65]);}
  out.sort((x,y)=>x[0]-y[0]);motCache.set(key,out);return out;}

const DAYS_ON=new Set([RET-1,RET-2,RET-3,RET-4,RET-5,RET-6,RET-7,RET-9,RET-12]);
const dayCache=new Map();
function wallDays(density){
  const key='d|'+density;if(dayCache.has(key))return dayCache.get(key);
  const out=[];for(let i=0;i<RET;i++){const d0=RET0+i*DAY;
    let s=(i*2246822519+7)%2147483647,r=()=>((s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff);
    const on=DAYS_ON.has(i);
    const frac=on?Math.min(1,(density==='sparse'?.18:density==='busy'?.72:.42)*(.55+r()*.9)):0;
    out.push({t:d0,i,has:on,frac,mins:Math.round(frac*24*60),today:d0===dayStart(NOW)});}
  dayCache.set(key,out);return out;}

const litAt=(segs,t)=>!!segs&&segs.some(([a,b])=>t>=a&&t<=b);
/* the dormant cell's whole value: where IS this camera's footage, relative to now */
function nearestSeg(segs,t){if(!segs||!segs.length)return null;
  let best=null,bd=Infinity;
  segs.forEach(([a,b])=>{const d=t<a?a-t:t>b?t-b:0;if(d<bd&&d>0){bd=d;best={at:t<a?a+500:b-1500,dir:t<a?1:-1,gap:d};}});
  return best;}

/* procedural camera frame — stands in for a cell of the composited mosaic */
const Scene=React.memo(function Scene({oct,t,motion}){
  let s=(oct*7919)%2147483647,r=()=>((s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff);
  const out=oct>=147&&oct<=163&&oct!==161&&oct!==135;
  const sky='hsl('+(196+r()*14)+','+(18+r()*14)+'%,'+(30+r()*12)+'%)';
  const grd=out?'hsl('+(84+r()*26)+','+(11+r()*10)+'%,'+(19+r()*9)+'%)':'hsl('+(32+r()*10)+',8%,'+(17+r()*7)+'%)';
  const wall=out?'hsl('+(36+r()*12)+','+(12+r()*8)+'%,'+(33+r()*10)+'%)':'hsl('+(30+r()*12)+',7%,'+(30+r()*9)+'%)';
  const a=r(),b=r(),ph=(t%16000)/16000,sway=Math.sin(t/1300);
  return React.createElement('span',{className:'im',
    style:{background:'linear-gradient(178deg,'+sky+' 0%,'+sky+' '+(20+a*14)+'%,'+wall+' '+(20+a*14)+'%,'+wall+' '+(50+b*10)+'%,'+grd+' '+(50+b*10)+'%,'+grd+' 100%)'}},
    React.createElement('i',{style:{left:(4+a*10)+'%',top:(16+b*10)+'%',width:(16+a*20)+'%',height:(30+b*22)+'%',background:'rgba(255,255,255,.045)'}}),
    React.createElement('i',{style:{left:(52+b*22)+'%',top:(12+a*8)+'%',width:'2px',height:(46+a*20)+'%',background:'rgba(0,0,0,.34)'}}),
    React.createElement('i',{style:{left:'0%',top:(62+b*8)+'%',width:'100%',height:'2px',background:'rgba(255,255,255,.07)'}}),
    out?React.createElement('i',{style:{left:(12+a*16)+'%',top:(56+b*8)+'%',width:(24+b*22)+'%',height:(9+a*7)+'%',background:'rgba(142,185,107,.13)'}}):null,
    React.createElement('i',{style:{left:(26+a*30)+'%',top:(70+b*6)+'%',width:(30+b*26)+'%',height:'3px',background:'rgba(0,0,0,.3)'}}),
    motion?React.createElement('i',{style:{left:(38+ph*20+sway*1.4)+'%',top:(46+b*7)+'%',width:'7%',height:(26+a*8)+'%',background:'rgba(16,14,12,.72)',filter:'blur(.3px)'}}):null,
    React.createElement('i',{style:{left:0,top:0,width:'100%',height:'100%',background:'rgba(255,255,255,.008)'}})
  );});

const SPANS=[['15m',15*MIN,'15M'],['1h',HR,'1H'],['6h',6*HR,'6H'],['12h',12*HR,'12H'],['24h',DAY,'24H']];
function tickStep(span){
  if(span<=15*MIN)return [MIN,5*MIN];
  if(span<=HR)return [5*MIN,15*MIN];
  if(span<=6*HR)return [30*MIN,HR];
  if(span<=12*HR)return [HR,2*HR];
  return [HR,3*HR];}

const T={EN:{title:'Wall playback',search:'Search cameras, groups, views, clips, events…',
  pOnline:'ONLINE',pOffline:'OFFLINE',pNotRec:'NOT REC',checkIn:'Check in',
  pillT:l=>'Fleet-wide — opens the Live wall filtered to '+l.toLowerCase(),
  rLive:'LIVE',rGroups:'GROUPS',rViews:'VIEWS',rEvents:'EVENTS',rHealth:'HEALTH',
  sync:(a,b)=>'1 STREAM · '+a+'/'+b+' RECORDING',
  syncT:'Every cell is the same instant by construction — one composited stream. Hold T to stamp every cell.',
  noRec:'NOTHING RECORDED',noneInWin:'none in this window',jumpT:'Jump to this camera’s nearest footage',
  motionNow:'MOTION',swapT:'Swap this cell’s camera (right-click)',dragT:'Drag to rearrange',
  addCam:'ADD CAMERA',
  wallCams:n=>n+(n===1?' camera':' cameras'),synced:'synchronized',editCams:'EDIT CAMERAS',
  group:'GROUP',allCams:'All cameras',gInside:'Inside',gLift:'Лифты',gOutside:'Снаружи',gRoof:'Roof',
  gEmpty:'No cameras in this group',custom:'Custom selection',
  window:'WINDOW',rolling:'ROLLING',calday:'CALENDAR DAY',
  rollSub:(a,b)=>'Ends now — the far left is '+a+' at '+b,
  calSub:'Midnight to midnight, clamped to now',
  covered:'of the window has footage',
  rollCall:'ROLL CALL',recNow:'RECORDING',dormNow:'nothing at this instant',
  footage:'FOOTAGE',daysW:n=>n+' days w/ footage',lastN:n=>'last '+n+'d',hasFoot:'has footage',today:'today',
  play:'Play  Space',pause:'Pause  Space',b10:'Back 10 s  ←',f10:'Forward 10 s  →',
  lastHour:'Last hour',last15:'Last 15 min',fit:'FIT',events:'EVENTS',
  spanT:l=>'Rolling window — the last '+l.toLowerCase()+', ending now',
  exportSel:'Export selection',retLive:'Return to live',
  covLbl:'COVERAGE',motLbl:'MOTION',warming:'WARMING',
  archive:'ARCHIVE',dayHas:(d,n)=>d+' · '+n+(n===1?' camera':' cameras'),dayNone:'no footage this day',
  ribT:(d,m)=>d+' · '+m+' recorded across the wall',winHere:'loaded window',
  hoverT:'Click to seek · drag to mark a range',
  inOut:(a,b)=>'IN '+a+' → OUT '+b,
  selSpansGap:'spans a gap — some cameras have no footage inside it',
  chooseTtl:'Choose camera for this tile',
  chooseSub:c=>'Replaces '+c+' · the wall re-composites',
  assignTtl:'Assign cameras',assignSub:'The wall re-composites at the current moment',
  searchCam:'Search name, IP or group…',onWall:'ON WALL',useLive:'Use live wall',cancel:'Cancel',
  applyN:n=>'Apply · '+n+(n===1?' camera':' cameras'),cap:'16 maximum',capHit:'16 of 16 — deselect one first',
  expTtl:'Export this moment',expSub:'One clip per camera plus one synchronized grid clip, exported as a single wall moment',
  expRange:'Range',expCams:'Cameras',expGrid:'Synchronized grid clip',expGridNo:'backend endpoint not shipped — this part will fail honestly',
  expGo:'Export',
  tagPend:'PLAYBACK',pendT:'Synchronized wall playback — backend compositing pending.',
  pendS:'The server-composited grid stream (E1) isn’t live yet. Live tiles are unaffected — use Return to live.',
  failT:'Couldn’t composite the synchronized grid for this window.',
  failS:'The server didn’t return frames in time. Try a different time, or Return to live.',
  tagGroup:'GROUP',egT:'“Roof” has no cameras to play back.',
  egS:'A wall cannot be composited from an empty group. Pick another group, or use EDIT CAMERAS.',
  tagFoot:'FOOTAGE',nfT:'No footage anywhere on this wall in this window.',
  nfS:'Not one of these cameras recorded here. Pick a day with a dot, or widen the window.'},
RU:{title:'Запись стены',search:'Поиск камер, групп, видов, клипов, событий…',
  pOnline:'ОНЛАЙН',pOffline:'НЕ В СЕТИ',pNotRec:'НЕ ПИШУТ',checkIn:'Отметиться',
  pillT:l=>'По всему объекту — открывает эфирную стену с фильтром «'+l.toLowerCase()+'»',
  rLive:'ЭФИР',rGroups:'ГРУППЫ',rViews:'ВИДЫ',rEvents:'СОБЫТИЯ',rHealth:'СОСТОЯНИЕ',
  sync:(a,b)=>'1 ПОТОК · ПИШУТ '+a+'/'+b,
  syncT:'Все ячейки — один и тот же момент по построению: единый composited-поток. Удерживайте T, чтобы проштамповать каждую ячейку.',
  noRec:'НЕ ЗАПИСЫВАЛОСЬ',noneInWin:'нет в этом окне',jumpT:'Перейти к ближайшей записи этой камеры',
  motionNow:'ДВИЖ',swapT:'Заменить камеру ячейки (правый клик)',dragT:'Перетащите, чтобы поменять',
  addCam:'ДОБАВИТЬ',
  wallCams:n=>n+' '+ruPl(n,'камера','камеры','камер'),synced:'синхронно',editCams:'ИЗМЕНИТЬ',
  group:'ГРУППА',allCams:'Все камеры',gInside:'Inside',gLift:'Лифты',gOutside:'Снаружи',gRoof:'Крыша',
  gEmpty:'В этой группе нет камер',custom:'Произвольный набор',
  window:'ОКНО',rolling:'СКОЛЬЗЯЩЕЕ',calday:'КАЛЕНДАРНЫЙ ДЕНЬ',
  rollSub:(a,b)=>'Кончается сейчас — крайнее левое: '+a+', '+b,
  calSub:'С полуночи до полуночи, до текущего момента',
  covered:'окна содержит запись',
  rollCall:'ПЕРЕКЛИЧКА',recNow:'ПИШЕТ',dormNow:'в этот момент ничего',
  footage:'ЗАПИСЬ',daysW:n=>n+' '+ruPl(n,'день','дня','дней')+' с записью',lastN:n=>'посл. '+n+'д',
  hasFoot:'есть запись',today:'сегодня',
  play:'Воспроизвести  Space',pause:'Пауза  Space',b10:'Назад 10 с  ←',f10:'Вперёд 10 с  →',
  lastHour:'Последний час',last15:'Последние 15 мин',fit:'ВСЁ',events:'СОБЫТИЯ',
  spanT:l=>'Скользящее окно — последние '+l.toLowerCase()+', до текущего момента',
  exportSel:'Экспорт выделения',retLive:'К эфиру',
  covLbl:'ЗАПИСЬ',motLbl:'ДВИЖЕНИЕ',warming:'ГОТОВИТСЯ',
  archive:'АРХИВ',dayHas:(d,n)=>d+' · '+n+' '+ruPl(n,'камера','камеры','камер'),dayNone:'нет записи в этот день',
  ribT:(d,m)=>d+' · записано по стене: '+m,winHere:'загруженное окно',
  hoverT:'Клик — переход · протяните, чтобы выделить',
  inOut:(a,b)=>'НАЧАЛО '+a+' → КОНЕЦ '+b,
  selSpansGap:'пересекает пробел — у части камер внутри нет записи',
  chooseTtl:'Выберите камеру для этой ячейки',
  chooseSub:c=>'Заменит '+c+' · стена пересоберётся',
  assignTtl:'Назначить камеры',assignSub:'Стена пересоберётся на текущем моменте',
  searchCam:'Поиск по имени, IP или группе…',onWall:'НА СТЕНЕ',useLive:'Как на эфире',cancel:'Отмена',
  applyN:n=>'Применить · '+n+' '+ruPl(n,'камера','камеры','камер'),cap:'максимум 16',
  capHit:'16 из 16 — сначала снимите одну',
  expTtl:'Экспорт этого момента',expSub:'По клипу на каждую камеру плюс один синхронный клип-сетку, как единый момент стены',
  expRange:'Диапазон',expCams:'Камеры',expGrid:'Синхронный клип-сетка',
  expGridNo:'эндпоинт бэкенда ещё не готов — эта часть честно не выполнится',
  expGo:'Экспортировать',
  tagPend:'ЗАПИСЬ',pendT:'Синхронная запись стены — сборка на бэкенде ещё не готова.',
  pendS:'Серверный composited-поток (E1) пока не работает. На эфирные плитки это не влияет — нажмите «К эфиру».',
  failT:'Не удалось собрать синхронную сетку для этого окна.',
  failS:'Сервер не вернул кадры вовремя. Попробуйте другое время или вернитесь к эфиру.',
  tagGroup:'ГРУППА',egT:'В группе «Крыша» нет камер для воспроизведения.',
  egS:'Стену нельзя собрать из пустой группы. Выберите другую группу или нажмите «ИЗМЕНИТЬ».',
  tagFoot:'ЗАПИСЬ',nfT:'В этом окне ни одна камера стены не записывала.',
  nfS:'Ни одна из этих камер здесь не писала. Выберите день с точкой или расширьте окно.'}};

window.WPCore={S,MIN,HR,DAY,NOW,TODAY,RET,RET0,dayStart,pad,hms,hm,ms3,dmy,dm,wdy,durTxt,MO,WD,WD1,ruPl,
  ROSTER,GROUPS,WALL_DEFAULT,segsFor,motionFor,wallDays,litAt,nearestSeg,Scene,SPANS,tickStep,T};
