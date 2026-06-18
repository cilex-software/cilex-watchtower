/* ============================================================
   view-review.jsx — VIEW 2: VERIFY (combined screen)
   One screen, two layouts toggled at the top:
     · Verification Wall  — snapshot grid, sized S / M / L
     · Smart Sessions     — zone-grouped sessions, sorted Priority / Recent
   The right-hand controls are contextual: S/M/L only on the Wall,
   Priority/Recent only on Sessions.
   ============================================================ */
function ReviewView({ events, act, setSel, setMode }) {
  const [layout, setLayout] = React.useState('wall');
  const [size, setSize] = React.useState('m');
  const [sortBy, setSortBy] = React.useState('priority');

  return (
    <div className="review">
      <div className="review-bar">
        <div className="modeseg review-toggle">
          <button className={layout==='wall'?'active':''} onClick={()=>setLayout('wall')}>{I.person(14)} Verification Wall</button>
          <button className={layout==='sessions'?'active':''} onClick={()=>setLayout('sessions')}>{I.motion(14)} Smart Sessions</button>
        </div>
        <span className="spacer"></span>

        {layout==='wall' ? (
          <div className="review-ctl">
            <span className="ctl-lbl mono">Size</span>
            <div className="wall-size">
              {['s','m','l'].map(s=>(<button key={s} className={size===s?'active':''} onClick={()=>setSize(s)}>{s.toUpperCase()}</button>))}
            </div>
          </div>
        ) : (
          <div className="review-ctl">
            <span className="ctl-lbl mono">Sort</span>
            <div className="modeseg" style={{height:32}}>
              <button className={sortBy==='priority'?'active':''} style={{padding:'0 14px',fontSize:11}} onClick={()=>setSortBy('priority')}>Priority</button>
              <button className={sortBy==='recent'?'active':''} style={{padding:'0 14px',fontSize:11}} onClick={()=>setSortBy('recent')}>Recent</button>
            </div>
          </div>
        )}
      </div>

      <div className="review-body">
        {layout==='wall'
          ? <WallBody events={events} act={act} setSel={setSel} setMode={setMode} size={size}/>
          : <SessionsBody events={events} act={act} sortBy={sortBy}/>}
      </div>
    </div>
  );
}
window.ReviewView = ReviewView;
