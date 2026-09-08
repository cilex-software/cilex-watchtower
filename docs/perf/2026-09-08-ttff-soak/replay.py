#!/usr/bin/env python3
"""Server-side replay of what the app's open does, timed per HTTP call. Read-mostly: creates
review sessions the way the app does and DELETEs them after. Credential from the 0600 file."""
import json,os,sys,time,urllib.request,urllib.error,http.cookiejar,re
BASE="http://127.0.0.1:8000"
u,p=open(os.path.expanduser("~/.config/watchtower-warden/ttff-soak.cred")).read().split("\n")[:2]
cj=http.cookiejar.CookieJar(); op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def call(method,path,data=None,raw=False):
    req=urllib.request.Request(BASE+path,data=json.dumps(data).encode() if data is not None else None,headers={"Content-Type":"application/json"},method=method)
    t=time.monotonic()
    try: r=op.open(req,timeout=120); b=r.read(); code=r.status; st=r.headers.get("Server-Timing","")
    except urllib.error.HTTPError as e: b=e.read(); code=e.code; st=e.headers.get("Server-Timing","")
    return code,int((time.monotonic()-t)*1000),b,st
code,_,_,_=call("POST","/auth/login",{"username":u,"password":p}); assert code==200, code
mode=sys.argv[1]
def iso(ms): return time.strftime("%Y-%m-%dT%H:%M:%S",time.gmtime(ms/1000))+".000Z"
if mode=="single":
    cam=sys.argv[2]; day=sys.argv[3]  # window: first 30 min of the day (local midnight = 21:00Z prev day; use UTC 00:00 of day for simplicity)
    s=time.mktime(time.strptime(day+" 00:00:00","%Y-%m-%d %H:%M:%S"))*1000
    body={"camera_id":cam,"wall_start":iso(s),"wall_end":iso(s+30*60000),"hevc_capable":True,"seek_mode":"continuous","head_split":True}
    code,ms,b,st=call("POST","/review/sessions",body); j=json.loads(b) if code==200 else {}
    sid=j.get("session_id") or j.get("id"); man=j.get("manifest",{}); frags=man.get("fragments") or j.get("fragments") or []
    print("  POST /review/sessions       %5d ms  code=%d frags=%s  st=%s" % (ms,code,len(frags),st[:110]))
    if not sid: print("  no session:",b[:200]); sys.exit()
    code,ms,b,st=call("GET",f"/review/sessions/{sid}/playlist.m3u8"); pl=b.decode(errors="replace")
    segs=[l for l in pl.splitlines() if l and not l.startswith("#")]
    print("  GET playlist.m3u8           %5d ms  code=%d bytes=%d segs=%d first=%s" % (ms,code,len(b),len(segs),segs[0] if segs else "-"))
    if segs:
        seg=segs[0] if segs[0].startswith("/") else f"/review/sessions/{sid}/{segs[0]}"
        code,ms,b,st=call("GET",seg); print("  GET first segment           %5d ms  code=%d bytes=%d  st=%s" % (ms,code,len(b),st[:90]))
        if len(segs)>1:
            seg=segs[1] if segs[1].startswith("/") else f"/review/sessions/{sid}/{segs[1]}"
            code,ms,b,st=call("GET",seg); print("  GET second segment          %5d ms  code=%d bytes=%d" % (ms,code,len(b)))
    code,ms,_,_=call("DELETE",f"/review/sessions/{sid}"); print("  DELETE session              %5d ms  code=%d" % (ms,code))
elif mode=="mosaic":
    ids=sys.argv[2].split(","); span=int(sys.argv[3]); prewarm=(len(sys.argv)>4 and sys.argv[4]=="prewarm")
    e=time.time()*1000; s=e-span*60000
    body={"camera_ids":ids,"wall_start":iso(s),"wall_end":iso(e),"layout":{"cols":4,"rows":4}}
    if prewarm: body["prewarm_at"]=0
    code,ms,b,st=call("POST","/review/mosaic-sessions",body); j=json.loads(b) if code==200 else {}
    sid=j.get("session_id") or j.get("id"); frags=(j.get("manifest",{}).get("fragments") or j.get("fragments") or [])
    print("  span=%4d min prewarm=%-5s POST mosaic-sessions %6d ms code=%d frags=%d st=%s" % (span,prewarm,ms,code,len(frags),st[:100]))
    if not sid: print("  no session:",b[:200]); sys.exit()
    t=time.monotonic(); code,ms,b,st=call("GET",f"/review/mosaic-sessions/{sid}/playlist.m3u8"); pl=b.decode(errors="replace")
    segs=[l for l in pl.splitlines() if l and not l.startswith("#")]
    print("      GET playlist %5d ms code=%d segs=%d" % (ms,code,len(segs)))
    if segs:
        seg=segs[0] if segs[0].startswith("/") else f"/review/mosaic-sessions/{sid}/{segs[0]}"
        code,ms,b,st=call("GET",seg); print("      GET seg0     %5d ms code=%d bytes=%d st=%s" % (ms,code,len(b),st[:90]))
    code,ms,_,_=call("DELETE",f"/review/mosaic-sessions/{sid}"); print("      DELETE       %5d ms code=%d" % (ms,code))
