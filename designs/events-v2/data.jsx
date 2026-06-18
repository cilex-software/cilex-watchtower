/* ============================================================
   data.jsx — mock event domain + icons + procedural Snapshot
   Exposes globals via window for the view scripts.
   ============================================================ */

/* anchor "now" to the screenshot clock: 2026-06-17 20:49 UTC+3 */
const NOW = new Date('2026-06-17T20:49:00');

/* ---- icon set (stroke, 1.6) ---- */
const I = {
  person: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="7" r="3.2"/><path d="M5.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/></svg>),
  vehicle: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3 13l1.6-4.5A2 2 0 016.5 7h11a2 2 0 011.9 1.5L21 13v4h-2M3 17v-4m0 4h2m14 0h-2M7 17h10"/><circle cx="7" cy="17.5" r="1.6"/><circle cx="17" cy="17.5" r="1.6"/></svg>),
  motion: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="2.4"/><path d="M5.5 5.5a9 9 0 000 13M18.5 5.5a9 9 0 010 13M8 8a5 5 0 000 8M16 8a5 5 0 010 8"/></svg>),
  line_cross: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3 17h18" strokeDasharray="2 3"/><path d="M8 21l6-16M14 11l4 2-1-4"/></svg>),
  loiter: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3 2"/></svg>),
  tamper: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7z"/><path d="M9.5 9.5l5 5M14.5 9.5l-5 5"/></svg>),
  offline: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3 3l18 18M10.6 5.1A9 9 0 0121 12M5 8a13 13 0 00-2 4M8.5 11.5A5 5 0 0116 12M9 15a5 5 0 015-1.5"/><circle cx="12" cy="19" r="0.6" fill="currentColor"/></svg>),
  check: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 12.5l5 5L20 6.5"/></svg>),
  x: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>),
  escalate: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M12 19V5M6 11l6-6 6 6"/></svg>),
  play: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"><path d="M7 5l12 7-12 7z" fill="currentColor"/></svg>),
  bookmark: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"><path d="M6 4h12v16l-6-4-6 4z"/></svg>),
  bookmarkF: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor"><path d="M6 4h12v16l-6-4-6 4z"/></svg>),
  export: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3v12M8 7l4-4 4 4M5 14v5a2 2 0 002 2h10a2 2 0 002-2v-5"/></svg>),
  dispatch: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M21 3L11 13M21 3l-6 18-4-8-8-4z"/></svg>),
  assign: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><circle cx="9" cy="8" r="3"/><path d="M3.5 19c0-3 2.4-5 5.5-5 1.2 0 2.3.3 3.2.9M16 11v6M13 14h6"/></svg>),
  chev: (s=14)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M9 6l6 6-6 6"/></svg>),
  clock: (s=14)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2" strokeLinecap="round"/></svg>),
  pin: (s=16)=>(<svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M12 21s7-5.5 7-11a7 7 0 10-14 0c0 5.5 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/></svg>),
};

/* ---- subject silhouettes drawn into the snapshot ---- */
function PersonGlyph({ h=64, c='#cdd6df' }) {
  const w = h*0.42;
  return (<svg width={w} height={h} viewBox="0 0 42 100"><g fill={c}>
    <ellipse cx="21" cy="11" rx="8.5" ry="9"/>
    <path d="M9 34c0-7 5-12 12-12s12 5 12 12v22c0 3-2 4-4 4l-1 26h-4l-1.5-24h-3L20 86h-4l-1-26c-2 0-4-1-4-4z"/>
  </g></svg>);
}
function VehicleGlyph({ h=46, c='#b9c2cc' }) {
  const w = h*2.1;
  return (<svg width={w} height={h} viewBox="0 0 200 96"><g fill={c}>
    <path d="M8 64c-4 0-6-3-5-7l6-20c2-6 7-10 13-10h70l34 6c8 1 18 5 28 11l24 6c5 1 9 5 9 10v8c0 3-2 5-5 5H8z"/>
    <rect x="34" y="30" width="56" height="22" rx="3" fill="#11161c"/>
  </g>
  <circle cx="48" cy="74" r="15" fill="#0c0f13"/><circle cx="48" cy="74" r="7" fill={c}/>
  <circle cx="152" cy="74" r="15" fill="#0c0f13"/><circle cx="152" cy="74" r="7" fill={c}/></svg>);
}

/* ---- time helpers ---- */
function rel(d) {
  const s = Math.round((NOW - d) / 1000);
  if (s < 60) return s + 's ago';
  const m = Math.round(s/60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m/60); return h + 'h ' + (m%60) + 'm ago';
}
function hhmmss(d){ return d.toTimeString().slice(0,8); }
function hhmm(d){ return d.toTimeString().slice(0,5); }
function dur(sec){ const m=Math.floor(sec/60), s=sec%60; return m? m+'m '+s+'s' : s+'s'; }

/* ---- cameras + zones ---- */
const CAMS = {
  A: { id:'hiwatch-083bc14eff9a', name:'Loading Bay — Dock 2', zone:'Loading Bay', x:24, y:70 },
  B: { id:'hiwatch-2f5e1ac033', name:'North Perimeter — Fence 4', zone:'North Perimeter', x:50, y:14 },
  C: { id:'hiwatch-9c4d77ab12', name:'Main Entrance — Lobby', zone:'Main Entrance', x:50, y:88 },
  D: { id:'axis-p3265-east12', name:'Parking East — Row C', zone:'Parking — East', x:84, y:46 },
  E: { id:'hiwatch-66aa0142f1', name:'Stockroom — Aisle 1', zone:'Stockroom', x:30, y:42 },
  F: { id:'hiwatch-7b9e23cc40', name:'Server Room — Rack A', zone:'Server Room', x:68, y:30 },
  G: { id:'axis-q1786-recep', name:'Reception Desk', zone:'Reception', x:60, y:70 },
  H: { id:'hiwatch-1d8f90bb77', name:'Rear Yard — Gate', zone:'Rear Yard', x:16, y:30 },
};

const TYPES = {
  person:    { label:'Person detected', code:'AI_PERSON',  icon:'person' },
  vehicle:   { label:'Vehicle detected', code:'AI_VEHICLE', icon:'vehicle' },
  motion:    { label:'Motion', code:'MOTION', icon:'motion' },
  line_cross:{ label:'Line crossing', code:'LINE_CROSS', icon:'line_cross' },
  loiter:    { label:'Loitering', code:'LOITER', icon:'loiter' },
  tamper:    { label:'Camera tamper', code:'TAMPER', icon:'tamper' },
  offline:   { label:'Camera offline', code:'CONN_LOST', icon:'offline' },
};

let _uid = 0;
function ev(o){
  const t = new Date(NOW - o.ago*1000);
  return Object.assign({ id:'EV-'+(7400+(_uid++)), ts:t, status:'new', conf:null, sx:48, sy:8, tod:'night',
    subject: (o.type==='person'||o.type==='loiter'||o.type==='line_cross')?'person':(o.type==='vehicle'?'vehicle':'none'),
    bookmarked:false, dispo:null }, o, { cam: CAMS[o.cam] });
}

/* meaningful, mixed-priority event stream over the last ~3.5h */
const RAW = [
  ev({ ago:74,    type:'person', cam:'F', priority:'critical', conf:0.94, tod:'night', sx:54, sy:6,  durationSec:38, restricted:true,
       note:'Unscheduled presence in Server Room after hours.' }),
  ev({ ago:240,   type:'tamper', cam:'A', priority:'critical', conf:0.88, tod:'night', subject:'none', durationSec:12,
       note:'Lens obstructed / field of view lost.' }),
  ev({ ago:355,   type:'line_cross', cam:'B', priority:'critical', conf:0.91, tod:'night', sx:40, sy:10, durationSec:9,
       note:'Perimeter line crossed, inbound direction.' }),
  ev({ ago:520,   type:'person', cam:'H', priority:'high', conf:0.83, tod:'night', sx:60, sy:8, durationSec:64,
       note:'Person at rear gate, no badge event paired.' }),
  ev({ ago:690,   type:'vehicle', cam:'D', priority:'high', conf:0.79, tod:'night', sx:30, sy:18, durationSec:182,
       note:'Vehicle stationary in fire lane > 3 min.' }),
  ev({ ago:880,   type:'loiter', cam:'C', priority:'high', conf:0.74, tod:'night', sx:52, sy:9, durationSec:214,
       note:'Loitering at main entrance.' }),
  ev({ ago:1180,  type:'person', cam:'E', priority:'medium', conf:0.81, tod:'night', sx:44, sy:10, durationSec:27 }),
  ev({ ago:1500,  type:'vehicle', cam:'D', priority:'medium', conf:0.69, tod:'dusk', sx:62, sy:20, durationSec:44 }),
  ev({ ago:1760,  type:'motion', cam:'A', priority:'medium', subject:'none', durationSec:18, tod:'night' }),
  ev({ ago:2010,  type:'person', cam:'G', priority:'low', conf:0.77, tod:'day', sx:48, sy:12, durationSec:52,
       note:'Likely reception staff (badge-in 18:08).' }),
  ev({ ago:2300,  type:'motion', cam:'B', priority:'low', subject:'none', durationSec:8, tod:'night' }),
  ev({ ago:2640,  type:'motion', cam:'E', priority:'low', subject:'none', durationSec:14, tod:'night' }),
  ev({ ago:2980,  type:'offline', cam:'H', priority:'medium', subject:'none', durationSec:0, tod:'night',
       note:'Stream dropped — reconnect pending.' }),
  ev({ ago:3260,  type:'person', cam:'C', priority:'low', conf:0.72, tod:'dusk', sx:40, sy:11, durationSec:33 }),
  ev({ ago:3600,  type:'vehicle', cam:'D', priority:'low', conf:0.66, tod:'dusk', sx:34, sy:22, durationSec:71 }),
  ev({ ago:4200,  type:'motion', cam:'A', priority:'low', subject:'none', durationSec:21, tod:'dusk' }),
  ev({ ago:5100,  type:'person', cam:'H', priority:'medium', conf:0.8, tod:'dusk', sx:55, sy:9, durationSec:40 }),
  ev({ ago:6400,  type:'motion', cam:'G', priority:'low', subject:'none', durationSec:11, tod:'day' }),
  ev({ ago:7600,  type:'vehicle', cam:'D', priority:'low', conf:0.7, tod:'day', sx:28, sy:24, durationSec:96 }),
  ev({ ago:8800,  type:'motion', cam:'B', priority:'low', subject:'none', durationSec:7, tod:'day' }),
];

/* pre-resolve a couple so states are visibly mixed */
RAW[9].status = 'resolved'; RAW[9].dispo = 'authorized';
RAW[13].status = 'dismissed'; RAW[13].dispo = 'false_alarm';
RAW[16].status = 'ack';

const SEV_RANK = { critical:0, high:1, medium:2, low:3 };

/* disposition vocab (grounded in alarm acknowledgement workflows) */
const DISPO = {
  verified:   { label:'Verified threat', cls:'danger', icon:'escalate' },
  dispatched: { label:'Dispatched', cls:'danger', icon:'dispatch' },
  authorized: { label:'Authorized activity', cls:'good', icon:'check' },
  false_alarm:{ label:'False alarm', cls:'', icon:'x' },
  env:        { label:'Environmental', cls:'', icon:'x' },
};

/* ============================================================
   Snapshot component — procedural CCTV still
   ============================================================ */
function Snapshot({ ev, playing=false, showOsd=true, mini=false }) {
  const t = ev.type;
  const cls = ['snap', 'tod-'+ev.tod];
  if (mini) cls.push('mini');
  if (t==='offline') cls.push('lost');
  if (t==='tamper') cls.push('tamper');
  if (playing) cls.push('playing');
  const isThreat = ev.priority==='critical' || t==='line_cross' || t==='tamper';
  const sub = ev.subject;
  const conf = ev.conf ? Math.round(ev.conf*100) : null;
  const boxW = sub==='vehicle' ? 30 : 11;
  const boxH = sub==='vehicle' ? 24 : 40;

  return (
    <div className={cls.join(' ')}>
      <div className="scene"></div>
      {t!=='offline' && <>
        <div className="gridfloor"></div>
        <div className="struct" style={{ left:'4%', top:'18%', width:'16%', height:'40%' }}></div>
        <div className="struct" style={{ right:'6%', top:'12%', width:'22%', height:'30%' }}></div>
        <div className="floor"></div>
      </>}

      {sub!=='none' && t!=='offline' && t!=='tamper' && (
        <div className="subject" style={{ left:ev.sx+'%', bottom:ev.sy+'%' }}>
          {sub==='person' ? <PersonGlyph h={76} /> : <VehicleGlyph h={50} />}
          <div className={'bbox'+(isThreat?' threat':'')} style={{ left:'-14%', bottom:'-8%', width:boxW+'%', height:boxH+'%' }}>
            <span className="lab">{(TYPES[t]?.label||'OBJECT').split(' ')[0].toUpperCase()}{conf?' '+conf+'%':''}</span>
          </div>
        </div>
      )}

      {t==='tamper' && <div className="obscure"></div>}
      {t==='offline' && <>
        <div className="lost-bars"></div>
        <div className="lost-txt">{I.offline(20)}<span>SIGNAL LOST</span></div>
      </>}

      {showOsd && <>
        <div className="osd-tl"><span className="rec"></span>{ev.cam.id.slice(0,16)}</div>
        <div className="osd-br">{ev.ts.toLocaleDateString('en-GB',{day:'2-digit',month:'short'}).toUpperCase()} {hhmmss(ev.ts)}</div>
        <div className="osd-bl">{playing?'▶ PLAYBACK':'CH ' + (ev.cam.name.match(/\d+/)||['1'])[0]}</div>
      </>}
      <div className="scan"></div>
      <div className="vig"></div>
      <div className="playhead"></div>
    </div>
  );
}

Object.assign(window, { NOW, I, Snapshot, PersonGlyph, VehicleGlyph, CAMS, TYPES, RAW, DISPO, SEV_RANK,
  rel, hhmm, hhmmss, dur });
