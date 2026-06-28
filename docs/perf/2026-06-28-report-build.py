#!/usr/bin/env python3
# Watchtower stress-test BEFORE/AFTER report (reportlab). Run with /tmp/pdfvenv/bin/python.
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
                                Image, PageBreak, HRFlowable)
from reportlab.lib.enums import TA_LEFT

INK="#1a202c"; SUBT="#4a5568"; GREEN="#2e8b57"; RED="#c0392b"; BLUE="#2b6cb0"; AMBER="#b7791f"
ss=getSampleStyleSheet()
H1=ParagraphStyle('H1',parent=ss['Title'],textColor=INK,fontSize=22,leading=26,spaceAfter=2)
SUB=ParagraphStyle('SUB',parent=ss['Normal'],textColor=SUBT,fontSize=10.5,leading=14,spaceAfter=10)
H2=ParagraphStyle('H2',parent=ss['Heading2'],textColor=INK,fontSize=15,leading=18,spaceBefore=4,spaceAfter=4)
BODY=ParagraphStyle('BODY',parent=ss['Normal'],textColor=INK,fontSize=10,leading=14,spaceAfter=6,alignment=TA_LEFT)
SMALL=ParagraphStyle('SMALL',parent=ss['Normal'],textColor=SUBT,fontSize=8,leading=10.5,spaceAfter=4)
CELLK=ParagraphStyle('CELLK',parent=ss['Normal'],textColor=colors.white,fontSize=9.5,leading=12,fontName='Helvetica-Bold')
CELL=ParagraphStyle('CELL',parent=ss['Normal'],textColor=INK,fontSize=9.5,leading=12.5)
EX=ParagraphStyle('EX',parent=ss['Normal'],textColor=INK,fontSize=9.5,leading=13)

def badge(txt,color):
    t=Table([[Paragraph(f'<font color="white"><b>{txt}</b></font>',CELL)]],colWidths=[6.0*cm])
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),colors.HexColor(color)),
        ('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),
        ('TOPPADDING',(0,0),(-1,-1),3),('BOTTOMPADDING',(0,0),(-1,-1),3)]))
    return t

def kv(rows, kcolor):
    data=[[Paragraph(k,CELLK),Paragraph(v,CELL)] for k,v in rows]
    t=Table(data,colWidths=[3.0*cm,13.0*cm])
    t.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(0,-1),colors.HexColor(kcolor)),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('GRID',(0,0),(-1,-1),0.5,colors.HexColor('#e2e8f0')),
        ('LEFTPADDING',(0,0),(-1,-1),6),('RIGHTPADDING',(0,0),(-1,-1),6),
        ('TOPPADDING',(0,0),(-1,-1),5),('BOTTOMPADDING',(0,0),(-1,-1),5)]))
    return t

def img(path,w):  # w in cm; keep 11:X aspect from the figures
    from PIL import Image as PImage
    iw,ih=PImage.open(path).size
    return Image(path,width=w*cm,height=w*cm*ih/iw)

E=[]
# ---------------- COVER / EXEC SUMMARY ----------------
E.append(Paragraph('Cilex Watchtower — Performance Fixes',H1))
E.append(Paragraph('Stress-test results, <b>before vs after</b> &nbsp;·&nbsp; baseline 2026-06-27 → fixes 2026-06-28 (build 32a0337)',SUB))
E.append(HRFlowable(width='100%',thickness=1,color=colors.HexColor('#cbd5e0'),spaceAfter=10))
E.append(Paragraph('Executive summary',H2))
E.append(Paragraph(
 'Three stress tests were run against the native Qt6/QML operator client. The first run found <b>two real defects</b> '
 '(a playback seek that froze the video, and a memory leak while browsing events) and one clean result (window resize). '
 'Both defects were fixed and the suite was re-run on the same hardware and harness. <b>Both defects are resolved; the '
 'clean test stays clean.</b>',BODY))
exec_rows=[
 [Paragraph('<b>Test</b>',EX),Paragraph('<b>First run (before)</b>',EX),Paragraph('<b>After fix</b>',EX),Paragraph('<b>Headline gain</b>',EX)],
 [Paragraph('1 · Window resize',EX),Paragraph('<font color="%s"><b>PASS</b></font> — no crash, no leak'%GREEN,EX),
   Paragraph('<font color="%s"><b>PASS</b></font> — re-confirmed'%GREEN,EX),Paragraph('No defect (control)',EX)],
 [Paragraph('2 · Playback seek',EX),Paragraph('<font color="%s"><b>DEFECT</b></font> — every jump ≥30s froze (no frame in 45s)'%RED,EX),
   Paragraph('<font color="%s"><b>FIXED</b></font> — all 16 sizes render'%GREEN,EX),
   Paragraph('Frozen (∞) → <b>14–82 ms</b>; 99.8% render',EX)],
 [Paragraph('3 · Events browsing',EX),Paragraph('<font color="%s"><b>DEFECT</b></font> — leak +642 MB / 15 min, no plateau'%RED,EX),
   Paragraph('<font color="%s"><b>FIXED</b></font> — flat after warm-up'%GREEN,EX),
   Paragraph('Growth +642 → <b>+3 MB/15min</b> (−99.5%)',EX)],
]
t=Table(exec_rows,colWidths=[3.2*cm,5.4*cm,3.9*cm,4.0*cm])
t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#2d3748')),
  ('TEXTCOLOR',(0,0),(-1,0),colors.white),('VALIGN',(0,0),(-1,-1),'TOP'),
  ('GRID',(0,0),(-1,-1),0.5,colors.HexColor('#cbd5e0')),
  ('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#f7fafc')]),
  ('LEFTPADDING',(0,0),(-1,-1),6),('RIGHTPADDING',(0,0),(-1,-1),6),
  ('TOPPADDING',(0,0),(-1,-1),5),('BOTTOMPADDING',(0,0),(-1,-1),5)]))
E.append(t); E.append(Spacer(1,10))
E.append(Paragraph(
 '<b>Why it matters.</b> The seek freeze made recorded-footage review unusable beyond the few seconds already buffered — '
 'an operator jumping to an incident saw a frozen image. It now responds in milliseconds at any distance, including '
 'day-scale jumps. The events leak grew without bound and would eventually exhaust memory and crash the client during a '
 'long shift; memory is now bounded and flat.',BODY))
E.append(PageBreak())

# ---------------- TEST 1 ----------------
E.append(Paragraph('Test 1 — Window resize',H2)); E.append(badge('VERDICT: PASS — robust, no fix required',GREEN)); E.append(Spacer(1,8))
E.append(kv([
 ('The test','600 window resizes driven programmatically: 2 min of normal sizes, then 2 min of extreme/degenerate geometry from 1×1 up to 3840×2160. RSS and CPU sampled every 150 ms.'),
 ('Goal','Confirm the UI survives rapid and pathological window geometry without crashing or leaking graphics memory.'),
 ('Finding','Robust in both runs — completed all 600 resizes, no crash, no leak. RSS stays bounded; brief rises at 3–4K sizes are transient framebuffers that fall straight back.'),
 ('Problem','None — no defect found. Included as a control.'),
 ('Fix','None required.'),
 ('Result','Re-confirmed clean on the current build: 0 crashes, RSS bounded (floor ~245 MB, transient peak 321 MB at 4K, returns).'),
],'#2f855a'))
E.append(Spacer(1,8)); E.append(img('/tmp/rep_resize.png',16.0))
E.append(Paragraph('Fig. 1 — RSS across 600 resizes. Green = normal sizes, amber = extreme. Bounded throughout; spikes are transient large-window framebuffers, not a leak.',SMALL))
E.append(PageBreak())

# ---------------- TEST 2 ----------------
E.append(Paragraph('Test 2 — Playback seek latency',H2)); E.append(badge('VERDICT: DEFECT → FIXED',BLUE)); E.append(Spacer(1,8))
E.append(kv([
 ('The test','From a 24-hour recorded session, jump the playhead by 16 step sizes (1 s, 10 s, 30 s, 1 m … up to 24 h), 100 times each, timing the interval from the seek command to the <b>first actually-rendered video frame</b>.'),
 ('Goal','Measure how quickly — and whether — the player shows new footage when an operator scrubs or jumps to a different time. This is the core "review recorded footage" interaction.'),
 ('Finding','<b>Before:</b> small in-buffer jumps rendered fast (1 s ≈ 36 ms, 10 s ≈ 101 ms), but <b>every jump ≥ 30 s FROZE</b> — the playhead moved yet no frame appeared for 45 s+; the video stuck on the old image. Reproduced on the real user path (scrubber-click and event-click) and on the physical display.'),
 ('Problem','The player seeked inside one long 24 h HLS stream. FFmpeg\'s HLS demuxer stalls when it has to seek across the session\'s ~2,879 fragment <b>discontinuities</b>, so no frame is decoded. Recorded-footage review was effectively broken beyond the small playout buffer.'),
 ('Fix','For any far jump (> 20 s) the client now re-opens a short ~30-min session that <b>starts just before the target</b> and seeks into it — the target sits near the start of a fresh short stream, so the demuxer never crosses discontinuities. A follow-up <b>decoupled the scrubber timeline from this short window</b>, so the full 24 h timeline, footage track and markers stay on screen.'),
 ('Result','<b>All 16 jump sizes now render.</b> 1,524 of 1,527 seeks succeeded (99.8%); far jumps complete in <b>14–82 ms median</b> (the 3 stragglers were transient 10 s hiccups, not the old systematic freeze). A 24 h jump that <b>never completed</b> before now lands in ~16 ms. Playback memory holds a ~727 MB plateau — bounded, no leak.'),
],'#2c5282'))
E.append(Spacer(1,8)); E.append(img('/tmp/rep_seek.png',16.5))
E.append(Paragraph('Fig. 2 — Seek → first-frame latency per jump size (log scale). Red = froze (shown at the observed 45 s no-render mark). Before: only 1 s & 10 s rendered. After: every size renders in tens of milliseconds.',SMALL))
E.append(PageBreak())

# ---------------- TEST 3 ----------------
E.append(Paragraph('Test 3 — Events browsing',H2)); E.append(badge('VERDICT: DEFECT → FIXED',BLUE)); E.append(Spacer(1,8))
E.append(kv([
 ('The test','15 minutes of continuous events-area use, driven programmatically: selecting events, switching the four tabs (Triage / Verify / Timeline / Map) and opening recordings. RSS, CPU and click→playback latency sampled throughout.'),
 ('Goal','Confirm the events workflow stays responsive and memory-stable over a realistic operator session.'),
 ('Finding','<b>Before:</b> resident memory climbed <b>+642 MB over 15 min</b> (582 → 1,223 MB, peak 1,302) in a sawtooth that <b>never plateaued</b> — a leak. Opening a recording was responsive (median 67 ms).'),
 ('Problem','<b>Two compounding leaks.</b> (1) Switching tabs destroyed and recreated the view each time, leaking the just-selected view\'s state. (2) Selecting an event auto-opened and played its recording, and Qt\'s FFmpeg player leaks ~2 MB of decode context per source change. Left running, RSS climbs until the process is killed (out-of-memory).'),
 ('Fix','(1) Keep the four event views <b>alive</b> instead of recreating them on every tab switch. (2) Load a recording <b>on demand</b> — show the event snapshot with a play button; the recording loads on the play-tap, not on every selection. (3) Lazy-load the non-Triage views so a triage-focused session keeps a low baseline.'),
 ('Result','<b>Leak eliminated.</b> Memory growth fell from <b>+642 MB/15 min to +3 MB/15 min (−99.5%)</b> — flat after a brief warm-up. Typical triage-focused use now settles at <b>484 MB</b> (below the original\'s starting point); even heavy all-tabs use plateaus at a bounded 980 MB, versus a before-trajectory that passed 1,223 MB and kept climbing. Over a 1-hour shift, roughly <b>2.5 GB of leaked memory is avoided</b>.'),
],'#2c5282'))
E.append(Spacer(1,8)); E.append(img('/tmp/rep_events.png',16.5))
E.append(Paragraph('Fig. 3 — Resident memory over time (solid = measured, dashed = projected). Before climbed without a ceiling; after reaches a fixed ceiling and stays flat. Typical triage-only use holds at 484 MB.',SMALL))
E.append(PageBreak())

# ---------------- METHOD ----------------
E.append(Paragraph('Method & notes',H2))
E.append(Paragraph(
 '<b>Harness.</b> Each test is an environment-gated UI driver compiled into the client (inert unless enabled), exercising '
 'the real user paths and logging timestamps. An external sampler reads the process\'s memory and CPU from <font face="Courier">/proc</font> '
 'every 150 ms. Latency is measured in-app as the interval from the command (seek / click) to the actual frame or session update. '
 'Tests run on the same machine and build settings for both runs; "before" is the 2026-06-27 baseline, "after" is build 32a0337 (2026-06-28).',BODY))
E.append(Paragraph(
 '<b>On the numbers.</b> The "before" figures are the measured baselines from the first run. The seek "froze" bars are drawn at the '
 'observed 45 s no-render mark for scale; the true value is unbounded (the frame never arrived). The events "before" trace is '
 'reconstructed from the measured endpoints (582 → 1,223 MB) and slope; the "after" trace is the live 15-min recording. '
 'The 24 h session-span is the backend\'s current cap; footage exists further back but a single session cannot span it.',BODY))
E.append(Paragraph(
 '<b>Remaining follow-ups.</b> Playback does not yet auto-continue past the end of a re-opened 30-min window (a deliberate, '
 'pre-existing limit of the short-window approach). The events all-tabs baseline (980 MB) could be lowered further by releasing '
 'a hidden view\'s heavy image content; deferred as the typical case is already 484 MB and flat.',BODY))

SimpleDocTemplate('/tmp/Watchtower_Fixes_BeforeAfter.pdf',pagesize=A4,
  leftMargin=2.0*cm,rightMargin=2.0*cm,topMargin=1.8*cm,bottomMargin=1.6*cm,
  title='Cilex Watchtower — Performance Fixes (Before/After)').build(E)
print("PDF -> /tmp/Watchtower_Fixes_BeforeAfter.pdf")
