# The Watch — guard avatar characters (8)

2026-08-05, operator direction: guards pick a CHARACTER, not a person's face —
archetypes with real watch-lore behind them, "loyal, vigilant" in the
historical/mythological sense. The operator generates the art from these
descriptions; the client bundles the images and stores only `avatar_id`.
Names/passwords stay user-owned (profile self-creation — see letter
`docs/letters/2026-08-05-guard-self-profiles.md`).

Shared art style (prepend to every generation prompt):
> Circular badge avatar, heraldic bust emblem, dark charcoal background
> (#14181d), single warm amber rim-light (#e8a33d), engraved-line texture with
> subtle brass detail, no text, head-and-chest composition, dignified and calm,
> must stay legible at 64 px.

Delivery: 1:1 square ≥512 px, identical background/rim treatment across the
set (chip renders at ~28–64 px).

| # | EN | RU | Role | Motto (RU) |
|---|----|----|------|------------|
| 0 | Owl | Сова | Night Warden | «Вижу в темноте» |
| 1 | Raven | Ворон | Far-Seer | «Всё замечу — всё запомню» |
| 2 | Wolf | Волк | Patrol | «Свой периметр знаю» |
| 3 | Wolfhound | Волкодав | Faithful | «Своих не подведу» |
| 4 | Crane | Журавль | Sentinel | «Не задремлю» |
| 5 | Goose | Гусь | Alarm | «Разбужу весь дом» |
| 6 | Bear | Медведь | Doorwarden | «Пока я тут — порядок» |
| 7 | Griffin | Грифон | Keeper | «Главное — под охраной» |

## 0 · Owl — «Сова» · the Night Warden
Athena's little owl sat at the goddess's shoulder and saw what soldiers
missed; across Europe the owl's unblinking stare was itself a ward against
harm. Patience made visible: sees everything, announces almost nothing. For
the guard who catches the one wrong shadow at 03:40.
**Visual:** great grey owl, three-quarter bust, enormous calm amber eyes
catching the rim light, engraved feathering, faint crescent moon etched
behind the head.

## 1 · Raven — «Ворон» · the Far-Seer
Odin's ravens Huginn and Muninn flew the world each day and whispered back
everything they saw; the Tower of London keeps ravens on the payroll with a
real Ravenmaster — legend says the fortress stands while they stay.
Intelligence and memory; everything lands in the log. For the guard whose
shift report is immaculate.
**Visual:** glossy raven head and shoulders in profile turning toward the
viewer, one sharp knowing eye, blue-black iridescence, a small etched key
behind.

## 2 · Wolf — «Волк» · the Patrol
Geri and Freki lie at Odin's throne; the she-wolf of the Capitoline guarded
Rome's founders. A wolf walks its bounds, knows its pack, and nothing crosses
the line unseen. For the guard who walks every perimeter full-length, in any
weather.
**Visual:** grey wolf bust, ears forward, steady pale-gold eyes, winter-thick
fur, a faint arc of etched pawprints tracing a patrol loop.

## 3 · Wolfhound — «Волкодав» · the Faithful
The shepherd's answer to the wolf — bred to stand between the flock and the
dark; the watchdog archetype from Cerberus at the gate to the faithfulness of
Hachikō, and in Slavic fantasy «Волкодав» is the bodyguard who cannot be
bought. Stands at the door until relieved. For the guard people trust with
their keys.
**Visual:** big calm wolfhound (alabai-like) head, gentle-serious eyes, one
honorably ragged ear, heavy collar with a small brass tag catching the light.

## 4 · Crane — «Журавль» · the Sentinel
Medieval bestiaries: cranes sleep in a circle while one stands on one leg
holding a stone in its raised claw — doze off, the stone drops, the watch
wakes. Heraldry still calls the emblem "a crane in its vigilance." The
literal patron of not falling asleep on shift.
**Visual:** white-grey crane, neck tall, one leg raised clasping a small
round stone, red crown patch, minimal engraved reeds, amber dawn rim.

## 5 · Goose — «Гусь» · the Alarm
Around 390 BC the Gauls climbed the Capitoline by night; the dogs slept —
Juno's sacred geese screamed, woke Manlius, and Rome was saved. The most
famous alarm call in recorded history. Fearless voice; and the self-ironic
pick for the guard with humor and the loudest radio.
**Visual:** white goose, chest out, wings half-spread, beak open mid-honk,
proud furious little eye, a tiny etched laurel wreath behind — dignified
despite itself.

## 6 · Bear — «Медведь» · the Doorwarden
In Slavic folklore the bear is «хозяин» — the master whose presence keeps the
forest in order, invoked as guardian of yard and household. Calm mass; ends
trouble by standing in the doorway. For the guard whose presence alone
de-escalates.
**Visual:** brown bear head and chest, frontal, small steady eyes, immense
and unhurried, one paw resting on an etched wooden threshold-beam.

## 7 · Griffin — «Грифон» · the Keeper
Herodotus tells of griffins guarding gold in the far north — eagle's sight
joined to lion's strength, the classical warden of treasuries; their
descendants still hold the Bank Bridge in St Petersburg. The veteran's
emblem. The aspirational pick.
**Visual:** eagle-headed griffin bust, feathered neck flowing into lion
shoulders, folded wing edge visible, gold-leaf hint on the beak, a small
etched strongbox below.

## Product notes
- Picker shows the avatar + RU name + motto; free choice, changeable later,
  never assigned. Multiple guards MAY pick the same character (it's a
  favorite, not an identity).
- Client bundles the eight images (qrc); server stores `avatar_id` 0..7 only.
- Mottos are flavor text in the picker, not achievements/ranks — The Watch
  rank ladder (copper→…→sentinel) is orthogonal and stays hours-based.
