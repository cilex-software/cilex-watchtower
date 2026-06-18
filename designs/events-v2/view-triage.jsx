/* ============================================================
   view-triage.jsx — VIEW 1: TRIAGE QUEUE (inbox)
   List + detail. The detail pane now plays the event clip inline
   (transport + scrubber) — no separate "open playback" step.
   Work the queue: acknowledge, run the SOP, record a disposition.
   ============================================================ */

/* ---- inline playback player ---- */
function Player({ ev }) {
  const clip = Math.max(ev.durationSec || 20, 14);
  const pre = 6, post = 6;                       // pre/post-roll seconds
  const total = pre + clip + post;
  const [prog, setProg] = React.useState(pre/total);   // start at event in-point
  const [playing, setPlaying] = React.useState(true);
  const [speed, setSpeed] = React.useState(1);
  const trackRef = React.useRef(null);

  React.useEffect(()=>{ setProg(pre/total); setPlaying(true); }, [ev.id]);
  React.useEffect(()=>{
    if (!playing) return;
    const iv = setInterval(()=> setProg(p=>{ const n = p + (0.1*speed)/total; return n>=1 ? 0 : n; }), 100);
    return ()=>clearInterval(iv);
  }, [playing, speed, total]);

  const cur = prog*total;
  const fmt = s => { s=Math.max(0,Math.round(s)); return String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0'); };
  const scrub = e => { const r = trackRef.current.getBoundingClientRect(); setProg(Math.min(1,Math.max(0,(e.clientX-r.left)/r.width))); };
  const inEvent = cur>=pre && cur<=pre+clip;

  return (
    <div className="player">
      <div className="pl-surface">
        <Snapshot ev={ev} playing={playing}/>
        <span className={'pl-state mono'+(inEvent?' hot':'')}>{playing?'▶':'❚❚'} {inEvent?'EVENT':'PLAYBACK'}</span>
      </div>
      <div className="pl-transport">
        <button className="pl-btn" onClick={()=>setPlaying(p=>!p)} title="Play / pause">
          {playing ? <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14"/><rect x="14" y="5" width="4" height="14"/></svg> : I.play(15)}
        </button>
        <button className="pl-btn sm" onClick={()=>setProg(p=>Math.max(0,p-10/total))} title="Back 10s"><span className="pl-jmp mono">−10</span></button>
        <button className="pl-btn sm" onClick={()=>setProg(p=>Math.min(1,p+10/total))} title="Forward 10s"><span className="pl-jmp mono">+10</span></button>
        <span className="pl-time">{fmt(cur)} <i>/</i> {fmt(total)}</span>
        <div className="pl-scrub" ref={trackRef} onClick={scrub}>
          <div className="pl-track"></div>
          <div className="pl-event" style={{ left:(pre/total*100)+'%', width:(clip/total*100)+'%' }}></div>
          <div className="pl-fill" style={{ width:(prog*100)+'%' }}></div>
          <div className="pl-head" style={{ left:(prog*100)+'%' }}></div>
        </div>
        <button className="pl-speed mono" onClick={()=>setSpeed(s=> s===1?2: s===2?4:1)} title="Playback speed">{speed}×</button>
      </div>
    </div>
  );
}

function TriageView({ events, act, sel, setSel }) {
  const [filter, setFilter] = React.useState('open');
  const [note, setNote] = React.useState('');
  const [done, setDone] = React.useState({});

  const list = events.filter(e => {
    if (filter==='open') return e.status==='new' || e.status==='ack' || e.status==='progress';
    if (filter==='critical') return e.priority==='critical';
    return true;
  }).sort((a,b)=> (SEV_RANK[a.priority]-SEV_RANK[b.priority]) || (b.ts-a.ts));

  const cur = events.find(e=>e.id===sel) || list[0];
  React.useEffect(()=>{ setNote(''); setDone({}); }, [sel]);
  const openCount = events.filter(e=>e.status==='new'||e.status==='ack'||e.status==='progress').length;
  const sop = cur ? (SOPS[cur.type] || SOPS._default) : [];

  return (
    <div className="triage">
      <div className="tq-list">
        <div className="tq-tabs">
          {[['open','Open queue',openCount],['critical','Critical',events.filter(e=>e.priority==='critical').length],['all','All',events.length]].map(([k,l,n])=>(
            <button key={k} className={filter===k?'active':''} onClick={()=>setFilter(k)}>{l}<span className="n">{n}</span></button>
          ))}
        </div>
        <div className="tq-scroll">
          {list.map(e=>{
            const T = TYPES[e.type];
            return (
              <button key={e.id} className={'tq-row'+(cur&&e.id===cur.id?' on':'')+(e.status!=='new'?' done':'')} onClick={()=>setSel(e.id)}>
                <span className={'sevdot '+e.priority}></span>
                <span className="tq-thumb"><Snapshot ev={e} showOsd={false} mini/>{e.durationSec>0 && <span className="tq-thumb-dur mono">{dur(e.durationSec)}</span>}</span>
                <span className="tq-meta">
                  <span className="tq-top"><span className={'tpill '+e.type}>{I[T.icon](12)}{T.label}</span></span>
                  <span className="tq-cam">{e.cam.name}</span>
                  <span className="tq-time mono">{hhmmss(e.ts)} · {rel(e.ts)}</span>
                </span>
                <span className={'statetag '+e.status}><span className="d"></span></span>
              </button>
            );
          })}
        </div>
      </div>

      {cur ? (
      <div className="tq-detail">
        <div className="tq-hero">
          <Player ev={cur} key={cur.id}/>
          <div className="tq-toolrow">
            <button className="btn sm ghost">{I.export(15)} Export clip</button>
            <button className="btn sm ghost">{I.assign(15)} Assign</button>
            <span className="spacer"></span>
            <button className={'btn sm ghost'+(cur.bookmarked?' is-on':'')} onClick={()=>act.bookmark(cur.id)}>{cur.bookmarked?I.bookmarkF(15):I.bookmark(15)} {cur.bookmarked?'Saved':'Bookmark'}</button>
          </div>
        </div>

        <div className="tq-body">
          <div className="tq-headline">
            <div>
              <div className="tq-ttl">{TYPES[cur.type].label}{cur.restricted && <span className="restricted">RESTRICTED ZONE</span>}</div>
              <div className="tq-subttl">{cur.note || '—'}</div>
            </div>
            <div className={'sev '+cur.priority}><span className="bar"></span>{cur.priority}</div>
          </div>

          <div className="tq-facts">
            <div><span className="k">Camera</span><span className="v">{cur.cam.name}</span></div>
            <div><span className="k">Device</span><span className="v mono">{cur.cam.id}</span></div>
            <div><span className="k">Zone</span><span className="v">{cur.cam.zone}</span></div>
            <div><span className="k">Time</span><span className="v mono">{hhmmss(cur.ts)} · {cur.ts.toLocaleDateString('en-GB',{weekday:'short',day:'2-digit',month:'short'})}</span></div>
            <div><span className="k">Clip length</span><span className="v mono">{cur.durationSec? dur(cur.durationSec):'—'}</span></div>
            <div><span className="k">AI confidence</span><span className="v mono">{cur.conf? Math.round(cur.conf*100)+'%':'n/a'}</span></div>
          </div>

          <div className="tq-sop">
            <div className="tq-sec-h">Response procedure</div>
            {sop.map((s,i)=>(
              <label key={i} className={'sop-item'+(done[i]?' checked':'')}>
                <span className="cbx" onClick={(e)=>{e.preventDefault(); setDone(d=>({...d,[i]:!d[i]}));}}>{done[i]&&I.check(12)}</span>
                <span>{s}</span>
              </label>
            ))}
          </div>

          <div className="tq-notebox">
            <input placeholder="Add disposition note (what happened, who responded)…" value={note} onChange={e=>setNote(e.target.value)} />
          </div>
        </div>

        <div className="tq-actions">
          <button className="btn good" onClick={()=>act.dispose(cur.id,'authorized',note)}>{I.check(15)} Authorized</button>
          <button className="btn" onClick={()=>act.dispose(cur.id,'false_alarm',note)}>{I.x(15)} False alarm</button>
          <button className="btn danger" onClick={()=>act.dispose(cur.id,'dispatched',note)}>{I.dispatch(15)} Dispatch guard</button>
          <span className="spacer"></span>
          {cur.status==='new' && <button className="btn pri" onClick={()=>act.ack(cur.id)}>{I.check(15)} Acknowledge &nbsp;<kbd>E</kbd></button>}
          {cur.status!=='new' && <span className={'statetag '+cur.status} style={{padding:'0 8px'}}><span className="d"></span>{cur.status}{cur.dispo?' · '+DISPO[cur.dispo].label:''}</span>}
        </div>
      </div>
      ) : <div className="tq-empty">Queue clear — no open events.</div>}
    </div>
  );
}

const SOPS = {
  _default: ['Watch the clip + confirm subject type', 'Confirm intent', 'Record disposition'],
  person: ['Watch playback at event time', 'Confirm person vs. authorized staff (check badge log)', 'If unauthorized after-hours → dispatch / call keyholder', 'Record disposition + notes'],
  line_cross: ['Watch the crossing clip', 'Verify direction (inbound = priority)', 'Escalate to supervisor + dispatch patrol', 'Notify keyholder, log incident'],
  tamper: ['Switch to nearest overlapping camera', 'Verify obstruction vs. fault', 'Dispatch to inspect device', 'Raise maintenance ticket'],
  vehicle: ['Watch playback, read plate if visible', 'Check against expected deliveries', 'If in fire lane > limit → tannoy / dispatch', 'Record disposition'],
  loiter: ['Watch the dwell clip', 'Assess intent / duration', 'Tannoy warning or dispatch', 'Log disposition'],
  offline: ['Check device health page', 'Confirm network vs. power', 'Raise maintenance ticket', 'Cover area with adjacent camera'],
  motion: ['Scrub the motion clip', 'Confirm environmental vs. real', 'Dismiss or escalate'],
};

window.TriageView = TriageView;
