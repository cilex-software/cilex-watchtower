/* ============================================================
   view-sessions.jsx — SESSIONS layout body (part of Verify screen)
   Collapses motion fragments into sessions, grouped by zone, ranked by
   priority, with bulk-acknowledge. Sort (Priority/Recent) is controlled
   from the Verify screen toolbar.
   ============================================================ */
function SessionsBody({ events, act, sortBy }) {
  const [picked, setPicked] = React.useState({});
  const [collapsed, setCollapsed] = React.useState({});

  const zones = {};
  events.forEach(e=>{ (zones[e.cam.zone] = zones[e.cam.zone]||[]).push(e); });
  const zoneList = Object.entries(zones).map(([zone,evs])=>{
    const rank = Math.min(...evs.map(e=>SEV_RANK[e.priority]));
    return { zone, evs: evs.sort((a,b)=>(SEV_RANK[a.priority]-SEV_RANK[b.priority])||(b.ts-a.ts)), rank,
      open: evs.filter(e=>e.status==='new').length };
  }).sort((a,b)=> sortBy==='priority' ? a.rank-b.rank : b.evs[0].ts-a.evs[0].ts);

  const pickedIds = Object.keys(picked).filter(k=>picked[k]);
  const toggle = id => setPicked(p=>({...p,[id]:!p[id]}));
  const bulkAck = () => { pickedIds.forEach(id=>act.ack(id)); setPicked({}); };
  const bulkDismiss = () => { pickedIds.forEach(id=>act.dispose(id,'false_alarm')); setPicked({}); };
  const noiseCollapsed = 38;

  return (
    <div className="ses">
      <div className="ses-statbar">
        <div className="ses-stat"><b>{noiseCollapsed}</b><span>motion fragments<br/>collapsed into sessions</span></div>
        <div className="ses-stat"><b className="bad">{events.filter(e=>e.status==='new'&&(e.priority==='critical'||e.priority==='high')).length}</b><span>high-priority<br/>need action</span></div>
        <div className="ses-stat"><b className="good">{events.filter(e=>e.status!=='new').length}</b><span>handled<br/>this shift</span></div>
      </div>

      <div className="ses-scroll">
        {zoneList.map(z=>(
          <div key={z.zone} className="ses-zone">
            <button className="ses-zone-h" onClick={()=>setCollapsed(c=>({...c,[z.zone]:!c[z.zone]}))}>
              <span className={'ses-zchev'+(collapsed[z.zone]?' c':'')}>{I.chev(14)}</span>
              <span className={'sevdot '+['critical','high','medium','low'][z.rank]}></span>
              <span className="ses-zname">{z.zone}</span>
              <span className="ses-zcount mono">{z.evs.length} sessions</span>
              {z.open>0 && <span className="ses-zopen">{z.open} open</span>}
            </button>
            {!collapsed[z.zone] && (
              <div className="ses-rows">
                {z.evs.map(e=>{
                  const T = TYPES[e.type];
                  return (
                    <div key={e.id} className={'ses-row'+(picked[e.id]?' picked':'')+(e.status!=='new'?' handled':'')}>
                      <button className={'ses-cbx'+(picked[e.id]?' on':'')} onClick={()=>toggle(e.id)}>{picked[e.id]&&I.check(12)}</button>
                      <span className="ses-thumb"><Snapshot ev={e} showOsd={false} mini/></span>
                      <span className="ses-main">
                        <span className={'tpill '+e.type}>{I[T.icon](12)}{T.label}</span>
                        <span className="ses-note">{e.note || (e.type==='motion'?'Motion session':'—')}</span>
                      </span>
                      <span className="ses-cam">{e.cam.name}</span>
                      <span className="ses-dur mono">{I.clock(12)} {e.durationSec?dur(e.durationSec):'—'}</span>
                      <span className="ses-time mono">{hhmmss(e.ts)}<br/><span className="r">{rel(e.ts)}</span></span>
                      <span className={'sev '+e.priority}><span className="bar"></span>{e.priority}</span>
                      <span className="ses-rowact">
                        {e.status==='new'
                          ? <><button className="btn sm" onClick={()=>act.ack(e.id)}>{I.check(13)} Ack</button>
                              <button className="btn sm icon" onClick={()=>act.bookmark(e.id)}>{e.bookmarked?I.bookmarkF(13):I.bookmark(13)}</button></>
                          : <span className={'statetag '+e.status}><span className="d"></span>{e.dispo?DISPO[e.dispo].label:e.status}</span>}
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        ))}
      </div>

      {pickedIds.length>0 && (
        <div className="ses-bulk">
          <span className="mono">{pickedIds.length} selected</span>
          <span className="spacer"></span>
          <button className="btn sm" onClick={bulkDismiss}>{I.x(14)} Dismiss as noise</button>
          <button className="btn sm pri" onClick={bulkAck}>{I.check(14)} Acknowledge selected</button>
          <button className="btn sm ghost" onClick={()=>setPicked({})}>Clear</button>
        </div>
      )}
    </div>
  );
}
window.SessionsBody = SessionsBody;
