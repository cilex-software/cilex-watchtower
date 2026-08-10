/* Wall playback — aside, scrubber and modals. Split out to keep the page file readable. */
const {useState,useEffect,useRef,useMemo,useCallback}=React;
const WC=window.WPCore;
const {S,MIN,HR,DAY,NOW,RET,RET0,dayStart,pad,hms,hm,ms3,dmy,dm,wdy,durTxt,MO,WD1,WD,ROSTER,GROUPS,
  segsFor,wallDays,litAt,nearestSeg,SPANS,tickStep,ruPl}=WC;

/* ───────── tier 1 · the archive ribbon (same axis as the scrubber beneath it) ───────── */
function Ribbon({L,t,days,selDay,onDay,win,litDayTotal}){
  const ref=useRef(null),[w,setW]=useState(1000);
  useEffect(()=>{const el=ref.current;if(!el)return;
    const m=()=>setW(el.getBoundingClientRect().width);m();
    if(!window.ResizeObserver)return;const ro=new ResizeObserver(m);ro.observe(el);return()=>ro.disconnect();},[]);
  /* remainder distributed one pixel at a time — floor() would end the ribbon short of the ruler below it */
  const base=Math.floor(w/RET),extra=w-base*RET;
  const wid=Array.from({length:RET},(_,i)=>base+(i<extra?1:0));
  let x=0;const lefts=wid.map(v=>{const l=x;x+=v;return l;});
  const compact=base<26,tiny=base<15;
  const mon0=(()=>{const d=new Date(days[0].t);return days[0].t-((d.getDay()+6)%7)*DAY;})();
  const wkOf=v=>Math.floor((v-mon0)/(7*DAY));
  const weeks=[],months=[];
  days.forEach((d,i)=>{const dt=new Date(d.t);
    if(i>0&&dt.getDay()===1)weeks.push(lefts[i]);
    if(i>0&&dt.getDate()===1)months.push([lefts[i],MO[L][dt.getMonth()]]);});
  const sel=days[selDay]||null;
  /* the loaded window drawn ACROSS the ribbon — this is what makes "rolling, crossing midnight" visible */
  const wa=Math.max(0,Math.min(1,(win.a-days[0].t)/(RET*DAY))),wb=Math.max(0,Math.min(1,(win.b-days[0].t)/(RET*DAY)));
  return <div className="rib">
    <div className="riblbl">
      <span className="k">{t.archive}<em>{sel?wdy(sel.t,L)+' '+new Date(sel.t).getDate():''}</em></span>
      <span className="v">{sel&&sel.mins?t.dayHas(Math.floor(sel.mins/60)+'h '+(sel.mins%60)+'m',litDayTotal):t.dayNone}</span>
    </div>
    <div className="ribtrack" ref={ref}>
      {days.map((d,i)=><button key={i} style={{width:wid[i]}} disabled={!d.has}
        className={'rday'+(d.has?' has':' none')+(wkOf(d.t)%2?' wkB':'')+(i===selDay?' sel':'')+(d.today?' today':'')}
        title={d.has?t.ribT(wdy(d.t,L)+' '+dmy(d.t,L),Math.floor(d.mins/60)+'h '+(d.mins%60)+'m'):dmy(d.t,L)+' · '+t.dayNone}
        onClick={()=>d.has&&onDay(i)}>
        {!tiny&&<span className="wd">{compact?WD1[L][new Date(d.t).getDay()]:WD[L][new Date(d.t).getDay()]}</span>}
        {!compact&&<span className="dn">{new Date(d.t).getDate()}</span>}
        <span className="dens"><i style={{height:d.has?Math.max(1,Math.round(d.frac*4))+'px':0}}></i></span>
      </button>)}
      {weeks.map((l,i)=><span key={'w'+i} className="wdiv" style={{left:l}}></span>)}
      {months.map(([l,m],i)=><React.Fragment key={'m'+i}>
        <span className="mdiv" style={{left:l}}></span><span className="mlbl" style={{left:l}}>{m}</span></React.Fragment>)}
      <span className="ribwin" title={t.winHere}
        style={{left:(wa*100)+'%',width:Math.max(0.25,(wb-wa)*100)+'%'}}></span>
    </div>
  </div>;}

/* ───────── aside ───────── */
function Aside({L,t,cams,litMap,motNow,segs,mots,group,setGroup,win,view,spanKey,calDay,onCalDay,
  ph,covPct,hoverCam,setHoverCam,onJump,onEdit,showCal,days}){
  const [gopen,setGopen]=useState(false);
  const gname=g=>g==='all'?t.allCams:g==='inside'?t.gInside:g==='lift'?t.gLift:g==='outside'?t.gOutside:t.gRoof;
  const withF=days.filter(d=>d.has).length;
  const [anchor,setAnchor]=useState(()=>{const d=new Date(NOW);return new Date(d.getFullYear(),d.getMonth(),1).getTime();});
  const first=new Date(anchor),y=first.getFullYear(),mo=first.getMonth();
  const lead=(first.getDay()+6)%7,dim=new Date(y,mo+1,0).getDate(),rows=Math.ceil((lead+dim)/7);
  const cells=[];for(let i=0;i<rows*7;i++){const t0=new Date(y,mo,1-lead+i).getTime();
    const idx=Math.round((t0-RET0)/DAY);cells.push({t:t0,inMo:new Date(t0).getMonth()===mo,idx,
      d:idx>=0&&idx<RET?days[idx]:null});}
  const litN=cams.filter(c=>litMap[c.oct]).length;
  const winStart=win.a;

  return <div className="aside">
    {/* THE authoritative clock — in the status column, never over the picture it describes */}
    <div className="aclock">
      <span className="d">{wdy(ph,L)} {dmy(ph,L)}</span>
      <span className="t">{hms(ph)}<span className="ms">.{ms3(ph)}</span></span>
      <button className="sy" title={t.syncT}>{t.sync(litN,cams.length)}</button>
    </div>
    <div className="ahd">
      <div className="h2"><span style={{fontSize:12.5,color:'var(--ink)',fontFamily:"'Space Grotesk',sans-serif"}}>{t.title}</span>
        <span>· {t.wallCams(cams.length)}</span>
        <button onClick={onEdit}>{t.editCams}</button></div>
    </div>
    <div className="arow">
      <span className="k">{t.group}</span>
      <button className="gsel" onClick={()=>setGopen(v=>!v)}>
        {gname(group)}<span className="cv">▾</span>
        {gopen&&<span className="gpop" onMouseDown={e=>e.stopPropagation()}>
          {GROUPS.map(g=><button key={g.id} className={group===g.id?'on':''} disabled={g.n===0}
            title={g.n===0?t.gEmpty:''}
            onClick={e=>{e.stopPropagation();if(g.n>0){setGroup(g.id);}setGopen(false);}}>
            {gname(g.id)}<span className="n">{g.n}</span></button>)}
        </span>}
      </button>
    </div>
    <div className="wstate">
      <div className="l1">
        <span className={'md '+(win.mode==='cal'?'cal':'roll')}>{win.mode==='cal'?t.calday:t.rolling}</span>
        <span className="rng">{win.mode==='cal'
          ?dm(win.a,L)+' · '+hm(win.a)+'–'+hm(win.b)
          :hm(win.a)+' → '+hm(win.b)}</span>
      </div>
      <span className="sub">{win.mode==='cal'?t.calSub:t.rollSub(wdy(winStart,L)+' '+dm(winStart,L),hm(winStart))}</span>
      <span className="sub"><b style={{color:'var(--ink2)',fontFamily:"'JetBrains Mono',monospace"}}>{covPct}%</b> {t.covered}</span>
    </div>
    {showCal&&<div className="cal">
      <div className="ch"><span className="k">{t.footage}</span><span className="v">{t.daysW(withF)}</span></div>
      <div className="calg">
        {WD1[L].slice(1).concat(WD1[L][0]).map((w,i)=><span className="calw" key={i}>{w}</span>)}
        {cells.map((c,i)=>{const has=c.d&&c.d.has,sel=c.idx===calDay,out=!c.inMo||!c.d;
          return <button key={i} disabled={!has}
            className={'cald'+(out?' out':has?' has':' none')+(sel?' sel':'')+(c.d&&c.d.today?' today':'')}
            title={has?wdy(c.t,L)+' '+dmy(c.t,L):dmy(c.t,L)}
            onClick={()=>has&&onCalDay(c.idx)}>{new Date(c.t).getDate()}{has&&<i></i>}</button>;})}
      </div>
      <div className="callg"><span><i></i>{t.hasFoot}</span><span><b></b>{t.today}</span></div>
    </div>}
    <div className="rc">
      <div className="rch">{t.rollCall}<b>{litN}</b>/<span>{cams.length}</span><em>{t.recNow}</em></div>
      <div className="rcl">
        {cams.map(c=>{const lit=litMap[c.oct],near=lit?null:nearestSeg(segs[c.oct],ph);
          const m=(mots[c.oct]||[]).filter(([a,b])=>b>view.a&&a<view.b);
          return <button key={c.oct} className={'rcr'+(lit?' lit':'')+(hoverCam===c.oct?' hi':'')}
            onMouseEnter={()=>setHoverCam(c.oct)} onMouseLeave={()=>setHoverCam(x=>x===c.oct?null:x)}
            onClick={()=>{if(!lit&&near)onJump(near.at);}}>
            <span className="sq" style={{background:lit?'var(--good)':'transparent',
              boxShadow:lit?'none':'inset 0 0 0 1px var(--line2)'}}></span>
            <span className="oc">.{c.oct}</span>
            <span className="st">{lit?(motNow[c.oct]?t.motionNow:t.recNow):t.dormNow}</span>
            <span className="mb">{m.slice(0,12).map(([a,b,v],i)=>
              <i key={i} style={{left:((a-view.a)/(view.b-view.a)*100)+'%',
                width:Math.max(1.5,(b-a)/(view.b-view.a)*100)+'%',opacity:.3+v*.7}}></i>)}</span>
            {!lit&&near&&<span className="jp">{near.dir<0?'←':'→'} {hm(near.at)}</span>}
          </button>;})}
      </div>
    </div>
  </div>;}

/* ───────── scrubber ───────── */
function Scrubber({L,t,cams,segs,mots,cov,warmFrom,view,win,ph,sel,setSel,onSeek,h,setH,
  lanesOn,litMap,hoverCam,setHoverCam,zoom,setZoom,trackRef}){
  const [hov,setHov]=useState(null),[grip,setGrip]=useState(false),[drag,setDrag]=useState(null);
  const span=view.b-view.a,pct=v=>((v-view.a)/span)*100;
  const [tick,label]=tickStep(span);
  const ticks=[];for(let x=Math.ceil(view.a/tick)*tick;x<view.b;x+=tick)ticks.push(x);
  const HEAD=14+15,LANE_MIN=7;
  const laneArea=Math.max(LANE_MIN,h-HEAD);
  const laneH=lanesOn?Math.max(LANE_MIN,Math.floor(laneArea/Math.max(1,cams.length))):0;
  const xToT=cx=>{const r=trackRef.current.getBoundingClientRect();
    return view.a+Math.max(0,Math.min(1,(cx-r.left)/r.width))*span;};

  const down=e=>{if(e.button!==0)return;
    const t0=xToT(e.clientX);let moved=false;
    const mv=m=>{const t1=xToT(m.clientX);if(Math.abs(m.clientX-e.clientX)>4){moved=true;
      setDrag([Math.min(t0,t1),Math.max(t0,t1)]);}};
    const up=m=>{window.removeEventListener('mousemove',mv);window.removeEventListener('mouseup',up);
      if(moved){const t1=xToT(m.clientX);setSel([Math.min(t0,t1),Math.max(t0,t1)]);}
      else onSeek(t0);
      setDrag(null);};
    window.addEventListener('mousemove',mv);window.addEventListener('mouseup',up);};

  const wheel=e=>{e.preventDefault();
    const at=xToT(e.clientX);
    if(e.shiftKey){const d=(e.deltaY||e.deltaX)*span/900;
      let a=view.a+d,b=view.b+d;
      if(a<win.a){b+=win.a-a;a=win.a;}if(b>win.b){a-=b-win.b;b=win.b;}
      setZoom({a,b});return;}
    const k=e.deltaY>0?1.28:1/1.28;
    let ns=Math.min(win.b-win.a,Math.max(20*S,span*k));
    const f=(at-view.a)/span;
    let a=at-f*ns,b=a+ns;
    if(a<win.a){a=win.a;b=a+ns;}if(b>win.b){b=win.b;a=b-ns;}
    setZoom(ns>=(win.b-win.a)-1?null:{a,b});};

  const dragSel=drag||sel;
  const selGap=useMemo(()=>{if(!sel)return false;
    return cams.some(c=>!(segs[c.oct]||[]).some(([a,b])=>a<sel[1]&&b>sel[0]));},[sel,cams,segs]);

  return <div className="scrub" style={{height:h}}>
    <span className={'sgrip'+(grip?' on':'')} title={t.hoverT}
      onMouseDown={e=>{e.preventDefault();setGrip(true);
        const y0=e.clientY,h0=h;
        const mv=m=>setH(Math.max(HEAD+LANE_MIN,Math.min(420,h0+(y0-m.clientY))));
        const up=()=>{setGrip(false);window.removeEventListener('mousemove',mv);window.removeEventListener('mouseup',up);};
        window.addEventListener('mousemove',mv);window.addEventListener('mouseup',up);}}
      onDoubleClick={()=>setH(160)}></span>
    <div className="srow" style={{flex:1,minHeight:0}}>
      <div className="slbl">
        <span style={{color:'var(--good)'}}>{t.covLbl}</span>
        {lanesOn&&<span style={{color:'var(--accent)'}}>{t.motLbl}</span>}
        {zoom&&<span style={{color:'var(--ink3)'}}>{durTxt(span,L)}</span>}
      </div>
      <div className="strack" ref={trackRef} onMouseDown={down} onWheel={wheel}
        onMouseMove={e=>setHov(xToT(e.clientX))} onMouseLeave={()=>setHov(null)}>
        <div className="cov">
          {cov.map(([a,b],i)=>{const wa=Math.max(a,warmFrom);
            return <React.Fragment key={i}>
              <i className="rdy" style={{left:pct(a)+'%',width:Math.max(0.1,pct(Math.min(b,warmFrom))-pct(a))+'%'}}></i>
              {b>warmFrom&&<i className="wrm" style={{left:pct(wa)+'%',width:Math.max(0.1,pct(b)-pct(wa))+'%'}}></i>}
            </React.Fragment>;})}
          {warmFrom<view.b&&<span className="lbl" style={{left:'auto',right:5,color:'var(--warm)'}}>{t.warming}</span>}
        </div>
        <div className="ruler">
          {ticks.map(x=><i key={x} style={{left:pct(x)+'%',height:x%label===0?'100%':'5px'}}></i>)}
          {ticks.filter(x=>x%label===0).map(x=><span key={x} style={{left:pct(x)+'%'}}>{hm(x)}</span>)}
        </div>
        {lanesOn&&<div className="lanes">
          {cams.map((c,i)=>{const m=(mots[c.oct]||[]).filter(([a,b])=>b>view.a&&a<view.b);
            const dark=!(segs[c.oct]||[]).some(([a,b])=>b>view.a&&a<view.b);
            return <div key={c.oct} className={'lane'+(i%2?' z':'')+(hoverCam===c.oct?' hi':'')+(dark?' dk':'')}
              style={{height:laneH}}
              onMouseEnter={()=>setHoverCam(c.oct)} onMouseLeave={()=>setHoverCam(x=>x===c.oct?null:x)}>
              {laneH>=11&&<span className="lo">.{c.oct}</span>}
              {m.map(([a,b,v],k)=><i key={k} style={{left:pct(a)+'%',
                width:Math.max(0.08,pct(b)-pct(a))+'%',opacity:.28+v*.72}}></i>)}
            </div>;})}
        </div>}
        {dragSel&&<span className="selr" style={{left:pct(Math.max(dragSel[0],view.a))+'%',
          width:Math.max(0.1,pct(Math.min(dragSel[1],view.b))-pct(Math.max(dragSel[0],view.a)))+'%'}}>
          <em className="a">[</em><em className="b">]</em></span>}
        {ph>=view.a&&ph<=view.b&&<span className="phd" style={{left:pct(ph)+'%'}}><b></b></span>}
        {hov!=null&&<>
          <span className="hovl" style={{left:pct(hov)+'%'}}></span>
          <span className="htip" style={{left:pct(hov)+'%'}}>
            {hoverCam?'.'+hoverCam+' · ':''}{wdy(hov,L)} {hms(hov)}</span></>}
        {sel&&<span className="selchip" style={{left:Math.min(88,pct(sel[0]))+'%'}}>
          {t.inOut(hms(sel[0]),hms(sel[1]))} · {durTxt(sel[1]-sel[0],L)}
          {selGap?' · '+t.selSpansGap:''}</span>}
      </div>
    </div>
  </div>;}

/* ───────── modals ───────── */
function Modal({L,t,m,wall,setWall,close,sel,cams}){
  const [q,setQ]=useState('');
  const [pick,setPick]=useState(()=>wall.filter(x=>x!=null));
  const onWall=new Set(wall.filter(x=>x!=null));
  const gname=g=>g==='inside'?t.gInside:g==='lift'?t.gLift:g==='outside'?t.gOutside:t.gRoof;
  const list=useMemo(()=>{const s=q.trim().toLowerCase();
    return ROSTER.filter(c=>!s||String(c.oct).includes(s)||c.ip.includes(s)
      ||c.model.toLowerCase().includes(s)||gname(c.group).toLowerCase().includes(s));},[q,L]);

  if(m.k==='cell'){const cur=wall[m.idx]!=null?ROSTER.find(c=>c.oct===wall[m.idx]):null;
    return <div className="scrim" onMouseDown={close}>
      <div className="modal" onMouseDown={e=>e.stopPropagation()}>
        <div className="mhd"><div className="t1">{t.chooseTtl}</div>
          <div className="t2">{cur?t.chooseSub(cur.model+' ('+cur.ip+')'):t.assignSub}</div></div>
        <div className="msrch"><span style={{color:'var(--ink3)',fontSize:11}}>⌕</span>
          <input autoFocus value={q} onChange={e=>setQ(e.target.value)} placeholder={t.searchCam}/></div>
        <div className="mlist">
          {list.map(c=><button key={c.oct} className="mrow"
            onClick={()=>{setWall(w=>{const n=[...w];while(n.length<16)n.push(null);
              const at=n.indexOf(c.oct);if(at>=0)n[at]=n[m.idx];n[m.idx]=c.oct;
              while(n.length&&n[n.length-1]==null)n.pop();return n;});close();}}>
            <span className="nm"><b>{c.model} ({c.ip})</b><span>.{c.oct} · {gname(c.group)}</span></span>
            {onWall.has(c.oct)&&<span className="ow">{t.onWall}</span>}
          </button>)}
        </div>
        <div className="mft"><button className="gh" onClick={close}>{t.cancel}</button></div>
      </div></div>;}

  if(m.k==='edit'){const full=pick.length>=16;
    return <div className="scrim" onMouseDown={close}>
      <div className="modal" onMouseDown={e=>e.stopPropagation()}>
        <div className="mhd"><div className="t1">{t.assignTtl}</div><div className="t2">{t.assignSub}</div></div>
        <div className="msrch"><span style={{color:'var(--ink3)',fontSize:11}}>⌕</span>
          <input autoFocus value={q} onChange={e=>setQ(e.target.value)} placeholder={t.searchCam}/></div>
        <div className="mlist">
          {list.map(c=>{const on=pick.includes(c.oct);
            return <button key={c.oct} className={'mrow'+(on?' on':'')}
              onClick={()=>setPick(p=>on?p.filter(x=>x!==c.oct):(p.length>=16?p:[...p,c.oct]))}
              title={!on&&full?t.capHit:''}>
              <span className="cb">✓</span>
              <span className="nm"><b>{c.model} ({c.ip})</b><span>.{c.oct} · {gname(c.group)}</span></span>
            </button>;})}
        </div>
        <div className="mft">
          <span className={'c'+(full?' max':'')}>{pick.length} / 16 · {full?t.capHit:t.cap}</span>
          <button style={{marginLeft:'auto'}} onClick={()=>setPick(wall.filter(x=>x!=null))}>{t.useLive}</button>
          <button onClick={close}>{t.cancel}</button>
          <button className="pri" disabled={!pick.length}
            onClick={()=>{setWall(pick.slice(0,16));close();}}>{t.applyN(pick.length)}</button>
        </div>
      </div></div>;}

  return <div className="scrim" onMouseDown={close}>
    <div className="modal" style={{width:420}} onMouseDown={e=>e.stopPropagation()}>
      <div className="mhd"><div className="t1">{t.expTtl}</div><div className="t2">{t.expSub}</div></div>
      <div style={{padding:'2px 0'}}>
        {[[t.expRange,sel?hms(sel[0])+' → '+hms(sel[1])+' · '+durTxt(sel[1]-sel[0],L):'—'],
          [t.expCams,t.wallCams(cams.length)]].map(([k,v])=>
          <div key={k} style={{display:'flex',alignItems:'baseline',gap:9,padding:'7px 13px',borderBottom:'1px solid var(--line)'}}>
            <span style={{fontFamily:"'JetBrains Mono',monospace",fontSize:8,letterSpacing:1.2,color:'var(--ink3)',width:96,flex:'none'}}>{k.toUpperCase()}</span>
            <span style={{fontFamily:"'JetBrains Mono',monospace",fontSize:11.5,color:'var(--ink)'}}>{v}</span>
          </div>)}
        <div style={{display:'flex',alignItems:'baseline',gap:9,padding:'7px 13px'}}>
          <span style={{fontFamily:"'JetBrains Mono',monospace",fontSize:8,letterSpacing:1.2,color:'var(--ink3)',width:96,flex:'none'}}>{t.expGrid.toUpperCase()}</span>
          <span style={{fontSize:11,color:'var(--bad)',lineHeight:1.4}}>{t.expGridNo}</span>
        </div>
      </div>
      <div className="mft"><button onClick={close}>{t.cancel}</button>
        <button className="pri" onClick={close}>{t.expGo}</button></div>
    </div></div>;}

window.WPParts={Aside,Scrubber,Modal,Ribbon};
