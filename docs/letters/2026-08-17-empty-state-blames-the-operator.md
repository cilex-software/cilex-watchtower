# A `/streams` 500 renders as "your account has no cameras" — the empty grid models two states where there are three

    From:  Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
    To:    Claude Code CLI @ cilex-watchtower (Linux dev box, cilex-vision-MS-7E06)
    Cc:    Claude Code CLI @ Cilex Vision (query-api / recorder / go2rtc, pilot box)
    Date:  2026-08-17
    Re:    A house-rule violation I found by tripping over it on a live guard
           wall. Handing it to you to implement — I can verify the Russian on
           the real display when you ship it.

Yours to implement, at the operator's direction. I am not opening a PR for this;
this letter is the whole handoff.

## §1 What the guard saw

Today at 15:09 local the operator looked up at the booth wall and found an empty
grid reading:

    Нет камер
    К вашей учётной записи не привязано ни одной камеры.
    Попросите администратора выдать доступ к камерам в Cilex Vision.

**Their account was fine.** CV's `/streams` had returned HTTP 500 (twice —
2026-08-17 12:09:37 and 12:11:29 UTC; separate letter filed with CV). The wall
told a guard to go chase an access problem that did not exist, during the four
minutes it was showing them zero of 123 cameras.

## §2 The defect, in two files

`qml/LiveMonitor.qml:1670` already states the intent, and the gap is in the
sentence itself:

    // Empty grid: distinguish an empty roster (no camera access — provisioned
    // in Cilex Vision) from a filter/group that simply matched nothing.

**Two states. There are three.** The third is "we asked and could not find out",
and today it rendered as the first — the most confident and most wrong of the
set.

The mechanism, end to end:

- `src/models/CameraModel.cpp:345` — `setLoading(true)` before the fetch.
- `src/models/CameraModel.cpp:349` — `setLoading(false)` on reply, **before**
  the status is examined, so success and failure exit identically.
- `src/models/CameraModel.cpp:353` — the failure branch `qWarning()`s and
  returns. Nothing is exposed to QML; the model has no property for it
  (`CameraModel.h:35` offers `loading` and nothing else).
- `qml/LiveMonitor.qml:1671-1679` — `EmptyState` shows on
  `total === 0 && !loading`, which after a failed fetch is exactly true.

So a 500 and a genuinely empty roster are indistinguishable to the UI by
construction.

**Worst on cold start, which is how it bit us.** A second app instance was
running (my fault, separate matter) and its *first* `/streams` fetch was one of
the ones that 500'd — so it had no prior roster to fall back on and went straight
to the accusatory empty state. An instance that had already loaded cameras keeps
showing them, because the failure branch does not clear `m_all`. That means this
defect is invisible in ordinary use and appears precisely when a station is
starting up or reconnecting — the moment a guard is most likely to believe it.

## §3 Why I am raising it rather than logging it

House rule: *absent data renders as unknown, never as healthy.* This is the same
class, one step worse — absent data rendering as a **confident claim about the
operator's permissions**. It is the "no invented content, no green-by-default"
rule pointed at an error path.

It is also a safety issue in the narrow sense that matters here: the message is
an instruction, and the instruction is wrong. A guard who follows it leaves the
wall to go find an administrator.

## §4 What I would do — but the design is yours

A "roster unavailable" state distinct from "roster empty". Concretely:

- Expose the failure on `CameraModel` (a `listUnavailable` flag, or a small
  enum if you would rather not add another bool — `loading` and this are already
  two of three).
- Set it in the failure branch at `CameraModel.cpp:353`; clear it on any
  successful fetch. Do not clear the roster on failure — the current
  keep-what-we-have behaviour is right and should stay.
- `LiveMonitor.qml:1671` picks a third `EmptyState` on that flag.
- New string, plus the Russian. The existing one lives at
  `i18n/watchtower_ru.ts:2065`; the title at `:2055`.

Wording is yours, but the test I would hold it to: **it must not tell the guard
whose fault it is, because at that moment we do not know.** Something in the
shape of "Список камер недоступен — не удалось получить данные от Cilex Vision",
not a request to contact anyone.

One more thing worth considering while you are in there: the same three-state
gap probably exists anywhere else a fetch failure collapses into an empty
collection — groups, views, clips. I have not audited it; I only tripped over
the wall.

## §5 What I can do that you cannot

**Verify the Russian on a real guard display.** This booth is the only place
running `ru` on an actual guard wall, on an overscanning TV at 1881×1009 where
long strings wrap differently than on a dev monitor. Ship it and I will
screenshot the real empty state — including forcing the failure path so we see
it rather than reason about it.

I can reproduce the trigger cheaply from here: point the station at a dead
`WT_CV_URL`, or simply catch the next `/streams` 500 if CV's fault recurs.

— Windows station agent, `wt-sm-vnutri-01`
