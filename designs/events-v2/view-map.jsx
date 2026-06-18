/* ============================================================
   view-map.jsx — VIEW 5: SITUATION MAP (spatial awareness)
   A site plan with camera positions. Live events pulse where they
   physically happen, so a supervisor/owner sees WHERE activity is —
   not just a list. Click a camera to verify + dispatch in context.
   ============================================================ */
function MapView({ events, act, setSel, setMode }) {
  const [active, setActive] = React.useState(null);

  /* most recent open event per camera drives the pin state */
  const byCam = {};
  events.forEach(e=>{ const k=e.cam.id; if(!byCam[k] || e.ts>byCam[k].ts) byCam[k]=e; });
  const openByCam = {};
  events.filter(e=>e.status==='new').forEach(e=>{ const k=e.cam.id; openByCam[k]=(openByCam[k]||0)+1; });

  const feed = events.filter(e=>e.status==='new').sort((a,b)=>(SEV_RANK[a.priority]-SEV_RANK[b.priority])||(b.ts-a.ts));
  const cur = active ? Object.values(CAMS).find(c=>c.id===active) : null;
  const curEvents = cur ? events.filter(e=>e.cam.id===cur.id).sort((a,b)=>b.ts-a.ts) : [];
  const curEv = curEvents[0];

  return (
    <div className="map">
      <div className="map-canvas">
        <div className="map-plan">
          {/* schematic site plan: rooms */}
          <svg className="map-rooms" viewBox="0 0 100 100" preserveAspectRatio="none">
            <rect x="2" y="2" width="96" height="96" className="mr-out"/>
            <rect x="8" y="8" width="34" height="30" className="mr"/>
            <rect x="44" y="8" width="22" height="30" className="mr"/>
            <rect x="68" y="8" width="24" height="44" className="mr"/>
            <rect x="8" y="40" width="34" height="26" className="mr"/>
            <rect x="44" y="40" width="22" height="26" className="mr"/>
            <rect x="8" y="68" width="58" height="24" className="mr"/>
            <rect x="68" y="54" width="24" height="38" className="mr"/>
            <line x1="2" y1="54" x2="8" y2="54" className="mr-gap"/>
          </svg>
          <div className="map-labels">
            <span style={{left:'16%',top:'30%'}}>Rear Yard</span>
            <span style={{left:'50%',top:'10%'}}>N. Perimeter</span>
            <span style={{left:'30%',top:'42%'}}>Stockroom</span>
            <span style={{left:'68%',top:'30%'}}>Server Rm</span>
            <span style={{left:'84%',top:'46%'}}>Parking E.</span>
            <span style={{left:'24%',top:'70%'}}>Loading</span>
            <span style={{left:'60%',top:'70%'}}>Reception</span>
            <span style={{left:'50%',top:'90%'}}>Main Ent.</span>
          </div>

          {Object.values(CAMS).map(cam=>{
            const e = byCam[cam.id];
            const open = openByCam[cam.id]||0;
            const pr = e && open ? e.priority : (e && e.type==='offline' ? 'offline' : 'idle');
            return (
              <button key={cam.id} className={'map-pin '+pr+(active===cam.id?' on':'')} style={{left:cam.x+'%',top:cam.y+'%'}}
                onClick={()=>setActive(cam.id)}>
                {open>0 && <span className="map-ping"></span>}
                <span className="map-dot">{I.pin(14)}</span>
                {open>0 && <span className="map-badge">{open}</span>}
              </button>
            );
          })}
        </div>
        <div className="map-legend">
          <span><i className="lg critical"></i>critical activity</span>
          <span><i className="lg high"></i>elevated</span>
          <span><i className="lg offline"></i>offline</span>
          <span><i className="lg idle"></i>clear</span>
        </div>
      </div>

      <div className="map-side">
        {!cur ? (
          <>
            <div className="map-side-h">Live feed <span className="mono">{feed.length} open</span></div>
            <div className="map-feed">
              {feed.map(e=>{
                const T = TYPES[e.type];
                return (
                  <button key={e.id} className="map-feed-row" onClick={()=>setActive(e.cam.id)}>
                    <span className={'sevbar '+e.priority}></span>
                    <span className="mf-thumb"><Snapshot ev={e} showOsd={false} mini/></span>
                    <span className="mf-body">
                      <span className={'tpill '+e.type}>{I[T.icon](11)}{T.label}</span>
                      <span className="mf-cam">{e.cam.zone}</span>
                      <span className="mf-time mono">{rel(e.ts)}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          </>
        ) : (
          <div className="map-detail">
            <button className="map-back" onClick={()=>setActive(null)}>‹ All zones</button>
            <div className="map-d-cam">{cur.name}</div>
            <div className="map-d-zone mono">{cur.zone} · {cur.id}</div>
            {curEv && <div className="map-d-snap"><Snapshot ev={curEv}/></div>}
            {curEv ? (
              <>
                <div className="map-d-act">
                  <button className="btn pri sm" onClick={()=>{setSel(curEv.id);setMode('triage');}}>{I.play(14)} Verify</button>
                  <button className="btn danger sm" onClick={()=>act.dispose(curEv.id,'dispatched')}>{I.dispatch(14)} Dispatch</button>
                  <button className="btn good sm" onClick={()=>act.dispose(curEv.id,'authorized')}>{I.check(14)} Clear</button>
                </div>
                <div className="map-d-h">Recent at this camera</div>
                <div className="map-d-list">
                  {curEvents.slice(0,6).map(e=>{
                    const T=TYPES[e.type];
                    return (
                      <div key={e.id} className="map-d-row">
                        <span className={'sevdot '+e.priority}></span>
                        <span className="tpill {e.type}" style={{border:'none',background:'none',padding:0,color:'var(--ink-2)'}}>{I[T.icon](12)}{T.label}</span>
                        <span className="spacer"></span>
                        <span className="mono">{hhmmss(e.ts)}</span>
                        <span className={'statetag '+e.status}><span className="d"></span></span>
                      </div>
                    );
                  })}
                </div>
              </>
            ) : <div className="map-d-empty">No events at this camera.</div>}
          </div>
        )}
      </div>
    </div>
  );
}
window.MapView = MapView;
