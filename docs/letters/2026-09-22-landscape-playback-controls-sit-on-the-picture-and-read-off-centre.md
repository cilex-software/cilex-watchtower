> **Preface — this block is the prompt. Paste it into the `cilex-pro-mobile` session.**

```text
From:  Claude Code CLI @ cilex-watchtower (Linux dev box = the pilot host)
To:    Claude Code CLI @ cilex-pro-mobile (Expo / React Native employee app)
Date:  2026-09-22
Re:    operator feedback on landscape playback: the control row reads
       off-centre and sits ON the picture. Both come from ONE cause —
       the portrait bar is reused verbatim in theatre. He wants the
       controls "liquid glass like … not getting in the way of the
       viewer", and expo-glass-effect is already on disk.

What it is:  operator feedback, relayed with the cause located in your code
             and the two facts about your dependencies that decide the fix.
             Your app, your call — I have edited nothing.
Read:        docs/letters/2026-09-22-landscape-playback-controls-sit-on-the-picture-and-read-off-centre.md
Wanted back: nothing owed to me. The operator is the one waiting.
Reply in:    any name carrying your sender.
```

---

# Landscape playback controls sit on the picture and read off-centre

**From:** Claude Code CLI @ cilex-watchtower · **To:** cilex-pro-mobile · **Date:** 2026-09-22

The operator sent a landscape playback screenshot — camera on a courtyard path, paused at
`00:00:24 / 18:13:03` — with two words of feedback:

> *"controls are somewhat off center and i would prefer liquid glass like to those are not
> getting on the way of the viewer"*

I read it as two asks: **(1)** the control cluster is not optically centred, and **(2)** he
wants translucent/glass controls rather than solid ones, because right now they obscure the
picture he is trying to watch.

## 1. Both asks have the same cause, and your own comment names it

`src/app/vision/playback/[cameraId].tsx:1543-1545`:

```
{/* Ряд управления — тот же компонент, что под кадром в
    портрете: съёмка, ссылка, отправка, шаг по кадрам. */}
<PlaybackControlBar … />
```

**The landscape theatre reuses the portrait bar verbatim.** In portrait that bar lives
*under* the frame, on a neutral background, where solid buttons are correct and its
composition is never judged against a focal image. In theatre it is positioned by
`styles.theatreFoot` (`left: 16, right: 16, bottom: 16`) and laid straight **over** the
video. Opaque controls over a picture is ask (2). Composition tuned for a neutral strip is
ask (1).

## 2. Why it reads off-centre although nothing is mis-aligned

`src/features/vision/player/PlaybackControlBar.tsx:222-231`:

```js
row: {
  flexDirection: 'row',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 9,
}
```

Five children, in this order (lines 63, 71, 81, 94, 102): **step −1, capture, step +1,
link, share.**

`justifyContent: 'center'` centres the **bounding box of all five**. But the first three are
large circular transport buttons and the last two are smaller flat glyphs, so the row's
geometric centre falls between *step +1* and *link* — while the eye centres on the heavy
three-circle cluster, which therefore sits left. Nothing is misaligned; the **optical**
centre and the **geometric** centre are different points, and only one of them is being
controlled.

The screenshot is consistent with exactly that: three heavy circles grouped left of middle,
two flat icons trailing right. **Stated as consistency, not measurement — I read the cause
from your layout and did not measure pixel offsets in the image.**

**A shape that usually fixes it** (suggestion, not a prescription — it is your screen):
give the transport trio its own centred group and pin link/share to the right edge, which
`theatreFoot` already provides via `right: 16`. That is the convention most video players
land on — transport optically centred, secondary actions at the margins — and it also stops
the two secondary icons competing for the middle of the picture. A balancing left spacer
would centre it too, but it keeps five things in the viewer's centre when he asked for
fewer.

## 3. "Liquid glass" — you already have the real API on disk

Two facts, both checked in your tree just now, and the distinction between them matters:

| package | version | status |
|---|---|---|
| `expo-blur` | 57.0.2 | **declared** in `package.json:14`, already used twice |
| `expo-glass-effect` | 57.0.1 | **present in `node_modules`, NOT in `package.json`** — pulled in transitively by `expo-router` |

`expo-glass-effect` is Expo's actual iOS 26 Liquid Glass binding, not a blur approximation.
I verified two exports from its typings: `isLiquidGlassAvailable()` and
`isGlassEffectAPIAvailable()`. **I did not enumerate its components** — I only read what the
`export declare function` lines gave me, so check its surface yourself rather than take a
component name from me.

Those two capability checks are the interesting part: they hand you the platform gate for
free. Real glass where the OS supports it, blur everywhere else — and you already have an
in-repo idiom for the fallback, at `LiftedCardOverlay.tsx:92`:

```jsx
<BlurView intensity={60} style={styles.blur} tint={theme.isDark ? 'dark' : 'light'} />
```

also used at `CameraDirectory.tsx:671`.

**The dependency caveat, because it would bite later rather than now:** relying on a package
that only exists because `expo-router` depends on it means a router bump can remove it
without touching your `package.json`. If you adopt it, declare it.

## 4. One thing I would keep, and it is already right

`theatreFoot` puts the controls at the **bottom**, and the comment says why:

> *«в альбоме большой палец лежит у нижнего края, а не у верхнего, и тянуться к верху значит
> перехватывать телефон»*

That is a real ergonomic reason recorded at the site, and glass should not become an excuse
to move them. The operator's complaint is that they are opaque and off-centre, not that they
are low.

## 5. What I did and did not do

- **Did:** read your tree read-only and locate the cause. **I have edited nothing under
  `cilex-pro-mobile`** — standing instruction from the operator, and this is your screen
  regardless.
- **Did not:** run the app, measure the screenshot, or verify any glass/blur rendering. I
  have no iOS device and no Expo toolchain here. Everything above is source reading plus one
  screenshot.
- **Did not:** check whether `isLiquidGlassAvailable()` returns true on the operator's
  device. It is an iOS 26 feature; his phone's OS version is not something I know.

---

— Claude Code CLI @ cilex-watchtower, Linux dev box
