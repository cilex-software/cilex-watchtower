/* ============================================================
   view-timeline.jsx — VIEW 3: ACTIVITY TIMELINE (swimlanes)
   One lane per camera across a time axis. Events plotted as markers,
   motion shown as duration bars. Spot clusters, scrub, investigate.
   Forensic / pattern view. Click a marker for a popover action.
   ============================================================ */
function TimelineView({ events, act, setSel, setMode }) {
  const [hours, setHours] = React.useState(3.5);
  const [pop, setPop] = React.useState(null);
  const winSec = hours*3600;
  const t0 = new Date(NOW - winSec*1000);

  const camKeys = Object.keys(CAMS);
  const pct = (d)=> ((d - t0)/(winSec*1000))*100;

  /* hour gridlines */
  const ticks = [];
  for (let i=0;i<=Math.ceil(hours);i++){
    const tt = new Date(t0.getTime()+i*3600*1000);
    ticks.push({ left: pct(tt), label: hhmm(tt) });
  }

  return (
    <div className="tl">
      <div className="tl-bar">
        <div className="tl-title">Activity timeline <span className="mono">· {Object.keys(CAMS).length} cameras · {events.length} events</span></div>
        <span className="spacer"></span>
        <div className="tl-legend">
          <span><i className="lg critical"></i>critical</span>
          <span><i className="lg high"></i>high</span>
          <span><i className="lg motion"></i>motion / session</span>
        </div>
        <div className="modeseg" style={{height:32}}>
          {[[1.5,'90m'],[3.5,'3.5h'],[8,'8h']].map(([h,l])=>(
            <button key={l} className={hours===h?'active':''} style={{padding:'0 12px',fontSize:11}} onClick={()=>setHours(h)}>{l}</button>
          ))}
        </div>
      </div>

      <div className="tl-grid">
        <div className="tl-axis">
          <div className="tl-axis-corner"></div>
          <div className="tl-axis-track">
            {ticks.map((t,i)=>(<div key={i} className="tl-tick" style={{left:t.left+'%'}}><span>{t.label}</span></div>))}
          </div>
        </div>

        <div className="tl-lanes">
          {camKeys.map(k=>{
            const cam = CAMS[k];
            const lane = events.filter(e=>e.cam.id===cam.id && e.ts>=t0);
            return (
              <div key={k} className="tl-lane">
                <div className="tl-lane-h">
                  <span className="ln-name">{cam.name}</span>
                  <span className="ln-zone mono">{cam.zone}</span>
                </div>
                <div className="tl-lane-track">
                  {ticks.map((t,i)=>(<div key={i} className="tl-vline" style={{left:t.left+'%'}}></div>))}
                  {lane.map(e=>{
                    const left = pct(e.ts);
                    const w = e.durationSec? Math.max(0.6, (e.durationSec*1000/(winSec*1000))*100) : 0;
                    const T = TYPES[e.type];
                    const big = e.priority==='critical'||e.priority==='high';
                    return (
                      <React.Fragment key={e.id}>
                        {w>0.6 && <div className={'tl-barseg '+e.priority} style={{left:left+'%', width:w+'%'}}></div>}
                        <button className={'tl-mk '+e.priority+(big?' big':'')+(e.status!=='new'?' done':'')} style={{left:left+'%'}}
                          onClick={()=>setPop(pop===e.id?null:e.id)} title={T.label}>
                          {I[T.icon](big?13:11)}
                        </button>
                        {pop===e.id && (
                          <div className="tl-pop" style={{left:left+'%'}} onClick={ev=>ev.stopPropagation()}>
                            <div className="tl-pop-snap"><Snapshot ev={e} showOsd={false}/></div>
                            <div className="tl-pop-b">
                              <div className={'tpill '+e.type}>{I[T.icon](12)}{T.label}</div>
                              <div className="tl-pop-meta mono">{hhmmss(e.ts)} · {e.durationSec?dur(e.durationSec):'instant'} · {e.conf?Math.round(e.conf*100)+'%':'—'}</div>
                              <div className="tl-pop-act">
                                <button className="btn sm pri" onClick={()=>{setSel(e.id);setMode('triage');}}>{I.play(13)} Review</button>
                                <button className="btn sm" onClick={()=>act.bookmark(e.id)}>{e.bookmarked?I.bookmarkF(13):I.bookmark(13)}</button>
                                <button className="btn sm" onClick={()=>{act.ack(e.id);setPop(null);}}>{I.check(13)} Ack</button>
                              </div>
                            </div>
                          </div>
                        )}
                      </React.Fragment>
                    );
                  })}
                </div>
              </div>
            );
          })}
          <div className="tl-now" style={{left:'100%'}}><span>now {hhmm(NOW)}</span></div>
        </div>
      </div>
    </div>
  );
}
window.TimelineView = TimelineView;
