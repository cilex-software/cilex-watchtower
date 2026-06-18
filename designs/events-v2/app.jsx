/* ============================================================
   app.jsx — shell, shared event state, view router
   ============================================================ */
const MODES = [
  { id:'triage',   n:'01', label:'Triage Queue', tag:'Clear the backlog',
    why:<><b>Inbox triage.</b> Work the queue top-down by priority — watch the event clip inline, run the response procedure, and record a disposition. Best when one operator must clear a backlog of unhandled alarms fast.</> },
  { id:'review',   n:'02', label:'Verify', tag:'See it · sort it',
    why:<><b>Verify — Wall + Sessions in one screen.</b> Toggle between the snapshot <b>Wall</b> (confirm a threat or dismiss a false alarm at a glance) and <b>Smart Sessions</b> (motion fragments collapsed by zone, ranked by priority, bulk-acknowledged). The two strongest review modes, side-controls in one place.</> },
  { id:'timeline', n:'03', label:'Activity Timeline', tag:'Patterns & investigation',
    why:<><b>Forensic timeline.</b> One lane per camera across time; each event extends a bar to the right showing how long it lasted, so clusters and dwell-times become obvious. Best for investigating "what happened between 5 and 8".</> },
  { id:'map',      n:'04', label:'Situation Map', tag:'Where is it happening',
    why:<><b>Spatial awareness.</b> Events pulse on the site plan where they physically occur. Best for supervisors and owners who think in places, not log lines, and need to dispatch in context.</> },
];

function App() {
  const [events, setEvents] = React.useState(()=> RAW.map(e=>({...e})));
  const [mode, setMode] = React.useState('triage');
  const [sel, setSel] = React.useState(null);
  const [flash, setFlash] = React.useState(null);

  const toast = (msg)=>{ setFlash(msg); clearTimeout(window.__ft); window.__ft=setTimeout(()=>setFlash(null),1900); };
  const patch = (id, p)=> setEvents(es=>es.map(e=>e.id===id?{...e,...p}:e));

  const act = {
    ack:    (id)=>{ patch(id,{status:'ack'}); toast('Acknowledged'); },
    bookmark:(id)=>setEvents(es=>es.map(e=>e.id===id?{...e,bookmarked:!e.bookmarked}:e)),
    dispose:(id,dispo,note)=>{
      const inProgress = dispo==='dispatched'||dispo==='verified';
      patch(id,{ status: inProgress?'progress':'resolved', dispo, note: note||undefined });
      toast(DISPO[dispo] ? DISPO[dispo].label+' · logged' : 'Updated');
    },
  };

  const open = events.filter(e=>e.status==='new').length;
  const crit = events.filter(e=>e.status==='new'&&e.priority==='critical').length;
  const m = MODES.find(x=>x.id===mode);

  const View = { triage:TriageView, review:ReviewView, timeline:TimelineView, map:MapView }[mode];

  return (
    <div className="window">
      <div className="titlebar">
        <div className="winbtns"><span className="winbtn"></span><span className="winbtn"></span><span className="winbtn"></span></div>
        <div className="title"><b>Cilex Watchtower</b> — Events</div>
        <div className="titlebar-spacer"></div>
      </div>
      <div className="app">
        <div className="rail">
          <div className="brand"><div className="logo">C</div></div>
          {[['LIVE','live'],['GROUPS','groups'],['VIEWS','views']].map(([l])=>(
            <div key={l} className="nav-item"><RailIcon name={l}/><span className="lbl">{l}</span></div>
          ))}
          <div className="nav-item active"><RailIcon name="EVENTS"/><span className="lbl">Events</span><span className="badge">{open}</span></div>
          <div className="nav-item"><RailIcon name="HEALTH"/><span className="lbl">Health</span></div>
          <div className="spacer"></div>
        </div>

        <div className="main">
          <div className="topbar">
            <div className="topbar-brand"><span className="t">Cilex Vision</span><span className="v">Watchtower</span></div>
            <div className="title-h">Events<span className="sub">d611d029</span></div>
            <div className="spacer"></div>
            <div className="status-strip">
              <div className="chip bad"><span className="dot"></span><b>{open}</b> open</div>
              <div className="chip warn"><span className="dot"></span><b>{crit}</b> critical</div>
              <div className="chip good"><span className="dot"></span><b>{events.filter(e=>e.status==='resolved').length}</b> cleared</div>
            </div>
            <div className="clock mono">{hhmm(NOW)} · <b>UTC+3</b></div>
            <button className="iconbtn">{BellIcon}<span className="ndot"></span></button>
            <div className="avatar">AD</div>
          </div>

          <div className="modebar">
            <div className="modeseg">
              {MODES.map(x=>(
                <button key={x.id} className={mode===x.id?'active':''} onClick={()=>setMode(x.id)}>
                  <span className="mnum">{x.n}</span>{x.label}
                </button>
              ))}
            </div>
            <div className="mode-rationale"><span className="tag">{m.tag}</span>{m.why}</div>
          </div>

          <div className="stage">
            <View events={events} act={act} sel={sel} setSel={setSel} setMode={setMode}/>
          </div>
        </div>
      </div>
      {flash && <div className="toast">{I.check(15)} {flash}</div>}
    </div>
  );
}

const BellIcon = (<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M6 8a6 6 0 0112 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 004 0"/></svg>);
function RailIcon({ name }) {
  const p = {
    LIVE:'M3 5h18v12H3zM9 21h6', GROUPS:'M4 7l8-4 8 4-8 4zM4 12l8 4 8-4M4 17l8 4 8-4',
    VIEWS:'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z', EVENTS:'M6 8a6 6 0 0112 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 004 0',
    HEALTH:'M3 12h4l2-6 4 12 2-6h6',
  }[name];
  return (<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d={p}/></svg>);
}

ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
