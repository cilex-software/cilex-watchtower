/* ============================================================
   view-wall.jsx — WALL layout body (part of the combined Verify screen)
   Visual-first: every event is a snapshot card with a clip-duration
   badge. Confirm a real threat or dismiss a false alarm in one click.
   Size (S/M/L) is controlled from the Verify screen toolbar.
   ============================================================ */
function WallBody({ events, act, setSel, setMode, size }) {
  const [tab, setTab] = React.useState('toverify');
  const [hover, setHover] = React.useState(null);

  const cards = events.filter(e=>{
    if (tab==='toverify') return e.status==='new'||e.status==='ack';
    if (tab==='ai') return e.type==='person'||e.type==='vehicle'||e.type==='line_cross'||e.type==='loiter';
    return true;
  }).sort((a,b)=>(SEV_RANK[a.priority]-SEV_RANK[b.priority])||(b.ts-a.ts));

  return (
    <div className="wall">
      <div className="wall-subbar">
        <div className="wall-tabs">
          {[['toverify','To verify'],['ai','AI detections'],['all','All']].map(([k,l])=>(
            <button key={k} className={tab===k?'active':''} onClick={()=>setTab(k)}>{l}</button>
          ))}
        </div>
        <div className="wall-hint">{I.person(13)} Verify what you see — confirm a real threat or dismiss a false alarm without leaving the grid.</div>
      </div>

      <div className={'wall-grid sz-'+size}>
        {cards.map(e=>{
          const T = TYPES[e.type];
          const verified = e.status==='resolved'||e.status==='dismissed';
          return (
            <div key={e.id} className={'wcard'+(verified?' verified':'')} onMouseEnter={()=>setHover(e.id)} onMouseLeave={()=>setHover(null)}>
              <div className="wcard-snap" onClick={()=>{ setSel(e.id); setMode('triage'); }}>
                <Snapshot ev={e} playing={hover===e.id && !verified}/>
                <span className={'wcard-sev '+e.priority}>{e.priority}</span>
                {e.durationSec>0 && <span className="wcard-dur mono">{I.play(10)} {dur(e.durationSec)}</span>}
                {e.type==='offline' && <span className="wcard-dur mono off">no clip</span>}
                {verified && <span className={'wcard-stamp '+e.status}>{e.status==='resolved'?'CLEARED':'DISMISSED'}</span>}
              </div>
              <div className="wcard-info">
                <span className={'tpill '+e.type}>{I[T.icon](12)}{T.label}{e.conf?' · '+Math.round(e.conf*100)+'%':''}</span>
                <div className="wcard-cam">{e.cam.name}</div>
                <div className="wcard-time mono">{hhmmss(e.ts)} · {rel(e.ts)}</div>
              </div>
              {!verified && (
                <div className="wcard-act">
                  <button className="btn good sm" onClick={()=>act.dispose(e.id,'verified')}>{I.escalate(14)} Threat</button>
                  <button className="btn sm" onClick={()=>act.dispose(e.id,'false_alarm')}>{I.x(14)} Dismiss</button>
                  <button className={'btn sm icon'+(e.bookmarked?' is-on':'')} onClick={()=>act.bookmark(e.id)} title="Bookmark">{e.bookmarked?I.bookmarkF(14):I.bookmark(14)}</button>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
window.WallBody = WallBody;
