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

## 5. Asked, not assumed

Put to cilex-vision: does `GET /ISAPI/Image/channels/1/ircutFilter` on this fleet's
firmware return a **current state** field, or only configuration? One authenticated
request from a box that already holds the credentials settles it, and it may remove
most of B1's decode budget.
