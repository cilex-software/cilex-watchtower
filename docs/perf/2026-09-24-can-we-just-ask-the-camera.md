# "Can't you just ask the camera?" — probably yes, I cannot test it, and the probe method in CLAUDE.md does not work here

**2026-09-24.** The operator asked whether B1 needs to infer IR mode from pixels at all,
or whether the camera can simply be asked. It is the same question that demolished the
day/night half of B1 — *why infer what something already knows* — and it deserves the
same answer: measure, do not assert.

## 1. The existence probe in CLAUDE.md does not discriminate on this firmware

`CLAUDE.md` says: *"Never guess camera credentials — HiWatch/Hikvision firmware locks
after ~7 failures. Existence-probe with an unauthenticated request and read 401-vs-404
instead (Codex's method, adopted repo-wide)."*

Run against `192.168.1.127`, unauthenticated, **including a control path that cannot
exist**:

```
/ISAPI/Image/channels/1/ircutFilter               401
/ISAPI/Image/channels/1/ircutFilter/capabilities  401
/ISAPI/Image/channels/1/supplementLight           401
/ISAPI/Image/channels/1/ISPMode                   401
/ISAPI/System/deviceInfo                          401
/ISAPI/Nonexistent/madeup                         401   <-- CONTROL
```

**Every path returns 401, including one that certainly does not exist.** This firmware
challenges authentication before routing, so 401 carries no information about whether
an endpoint is there. **The probe proved nothing, and without the control I would have
reported four endpoints as confirmed present.**

Recorded because the method is in `CLAUDE.md` as adopted repo-wide. It is sound where
the device routes before authenticating; it is silent here. **Always include a path
that cannot exist** — otherwise the method cannot fail, which is the property this repo
has spent a week learning to distrust.

## 2. Who can actually ask

Not this box: it has no camera credentials, and guessing costs a lockout after ~7
failures on a fleet real guards are watching.

**cilex-vision can.** Measured in their tree — they already run a working ISAPI client
against all 133 cameras:

```
services/query-api/ptz_ops.py       ISAPI
services/query-api/motion_ops.py    ISAPI
services/query-api/provisioner.py   ISAPI
```

And they do **not** currently touch the relevant endpoints — no hit for `ircut`,
`supplementLight` or `ISPMode` anywhere in `services/`. Nor does the running API expose
any such field: probing the live OpenAPI for `ircut`, `ir_cut`, `night_mode`,
`day_night`, `supplement`, `ir_state` returns **absent** for every one. The only hits
are `scene_light` and `illuminat`, which are B1's own fields — the thing being built.

So the capability is unexplored rather than rejected.

## 3. The distinction that decides whether it replaces the pixel check

Hikvision's `ircutFilter` resource is, in the published ISAPI spec, a **configuration**:
mode (`auto` / `day` / `night` / `schedule`) and switching thresholds. **Configured mode
is not current state.** A camera set to `auto` tells you nothing about whether the
filter is open right now.

**That is exactly tonight's other lesson wearing different clothes.** cilex-vision
discovered hours ago that `/app/routers/labs.py` showed patched code while the process
went on executing what it loaded at startup — *the filesystem of a running container is
not its behaviour*. The configured IR mode is not the filter's position, for the same
reason.

So there are two questions, and only the second replaces anything:

1. **What mode is the camera configured in?** Useful for faults — a camera pinned to
   `day` will never go IR, and that explains a silent camera without decoding anything.
2. **Is the filter closed right now?** Only this competes with the pixel check, and
   whether the firmware reports it is unknown.

## 4. And they are not redundant even if the answer is yes

The pixel check reads the **image**; ISAPI reads the **camera's report of itself**. A
stuck filter is precisely the case where those disagree — the camera says night mode,
the picture is in colour — and that disagreement is a fault worth surfacing.

Measured tonight: chroma is `0.0000` on IR frames against a floor of `4.2944` on
everything else, across 220 rows. That is not a statistical claim about the camera's
intentions; it is the absence of chroma information in the frame.

**So if ISAPI reports live state, it should become the primary and the pixel check
becomes the audit** — cheap, occasional, and the thing that catches a camera lying
about itself. Which is the same structure as astronomy plus IR: the authoritative
source, plus an independent path that can contradict it.

## 5. ANSWERED: configuration only. The pixel check is not replaced.

cilex-vision probed five cameras with authenticated read-only GETs, using the
recorder's own credential resolution — nothing guessed.

```
/ISAPI/Image/channels/1/ircutFilter      200   IrcutFilterType = auto
                                               nightToDayFilterLevel = 4, Time = 5
/ISAPI/Image/channels/1/supplementLight  200   irLight (outdoor) / eventIntelligence (indoor)
/ISAPI/Image/channels/1/ISPMode          200   mode = auto
                                               scheduleType = day, 06:00:00-18:00:00
```

**`auto` says how the camera DECIDES, not where the filter IS.** So the answer is
question 1 of the two above: configured mode, not live state. **B1's pixel check
remains the only way to know whether the filter is actually closed, and the decode
budget is unchanged.**

Still worth having for faults, for the reason that made the question worth asking: a
camera pinned to `day` will never go IR, which explains a silent camera with no decode
at all.

`supplementLight` was **unresolved** here — it differs between cameras (irLight
outdoor, eventIntelligence indoor), but that is a configuration difference, not
evidence of state.

> **RESOLVED 2026-09-26 by cilex-vision, with the experiment that could have failed.**
> Their first daylight read was on a camera whose picture never left colour, so an
> unchanged field there proved nothing either way — and they said so rather than call
> it. They then found the ONE outdoor camera that genuinely switches to IR
> (`hiwatch-04eecdd45e2d`, SATAVG 0.00 at night — the same single camera this box's
> chroma census had found on 2026-09-24 by an unrelated method) and read every field
> before and after a real switch, with a frame measured 2 s after each read:
>
> ```
>                                    2026-09-25 13:15 MSK   2026-09-26 03:07 MSK
>   picture (SATAVG)                 7.65  colour           0  greyscale (IR on)
>   supplementLightMode              irLight                irLight
>   irLightBrightness                100                    100
>   whiteLightBrightness             50                     50
>   mixedLightBrightnessRegulatMode  auto                   auto
>   IrcutFilterType / level / time   auto / 4 / 5           auto / 4 / 5
> ```
>
> **The picture changed state; not one field moved.** So ISAPI reports how a camera
> is CONFIGURED, never what it is DOING. Pixel chroma is the only state signal, and
> B1's `ir` label cannot come from the camera. This is the same conclusion §5 reached
> from the other direction — no live-state field in the full image-config dump, and
> both candidate status paths absent — now confirmed by a controlled before/after on
> a camera known to switch.
>
> **Still worth reading, for faults.** A camera configured with the supplement light
> off, or with the IR-cut pinned to `day`, will never go IR — which explains a dark
> or silent camera without decoding a single frame. That is B2 (`camera_health`)
> territory.

## 6. A FALSE POSITIVE IN MY DRIFT MONITOR, found by accident

Every camera carries a day/night **schedule** of `06:00:00-18:00:00`. Against real sun
times that is **47 minutes early at dawn and 58 early at dusk**.

It is inert today — all five report `mode = auto`, and the measured transition at 18:59
against a computed sunset of 18:58 proves light is deciding rather than the clock. **But
a camera flipped to `mode = schedule` would transition at a fixed 06:00/18:00 and look
exactly like an hour of coordinate error.**

**So the monitor must read `ISPMode.mode` and EXCLUDE scheduled cameras, not flag
them.** Without that, one operator changing one camera's mode raises a coordinate alarm
for the whole site. That is a bigger hole than the 9-to-13-evening resolving power, and
neither of us would have found it by building the monitor — it came out of a probe
aimed at something else.

## 7. The probe method is silent on this firmware in BOTH directions

My unauthenticated probe returned 401 on everything including an impossible path.
cilex-vision assumed authenticating would restore routing so a 404 would mean
something. **It does not:**

```
unauthenticated   401 on everything, including /ISAPI/Nonexistent/madeup
authenticated     403 on /ISAPI/Nonexistent/madeup, 200 on the real paths
```

**This firmware never reveals existence through a status code.** The only reliable
discovery is a 200 with a parseable body.

Both of us needed an impossible-path control to learn that, and they had one only
because I published mine — otherwise three real paths would have returned three 200s
and "authenticated probing works" would have gone in the register without anyone
learning that 403 does not mean absent.

**`CLAUDE.md`'s existence-probe rule needs amending on this point.** The "never guess
credentials, the firmware locks after ~7 failures" half is unaffected and important.
It is the "read 401-vs-404" half that is unreliable here, in both authenticated and
unauthenticated form. Not edited unilaterally: that file governs four agents and the
amendment is the operator's to approve.
