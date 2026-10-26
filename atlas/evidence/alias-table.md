# Mishearing alias table (train-only)

Source: `atlas/evidence/replay-phase3b-padded.csv` (the padded corpus run, `small`,
no command-vocabulary prompt). Every candidate below is justified by a **train**
clip only; heldout clips are used to judge the table, never to build it.

## Shipped (`PayloadExtractor.mishearings`)

| Misheard | Alias | Train clip it came from | Can it change meaning elsewhere? |
|---|---|---|---|
| `skull` | `scroll` | `scroll_down/1` "Skull down" | No — "skull" is never a command word |
| `pulse` | `pause` | (not observed in this run) | No — kept because it is in the approved set |
| `under` | `undo` | `undo/1` "under" | Only inside dictation, which is exempt |
| `lover` | `louder` | `volume_up/3` "Lover" | No — "lover" is never a command word |

Dictation exemption: an utterance starting with `type `, `write `, `dictate ` or
`note down ` is never rewritten, because those words are the user's payload
("type this under the heading" must stay as spoken).

## Rejected

| Candidate | Train clip | Why not |
|---|---|---|
| `no` → mute | `play_pause/3` "Piano Music" | "no" is a word people say; it can flip a real utterance into mute |
| `who` → visit | `go_google/3` "Who is it Google" | rewrite would mangle a genuine question |
| `that mode` → dark mode | `dark_mode/1` | single clip, no generality |
| `taste` → paste | `paste/2` "Taste that" | "taste" can be a genuine payload word |
| `demur` → dimmer | `brightness_down/2` | single clip |
| `squall` → scroll | `scroll_up/1` "Squall up" | single clip; ASR also flipped up/down |
| `stock` → start | `open_terminal/3` "Stock terminal" | "stock" is a real word |
| `term` → terminal | `open_terminal/*` | prefix already resolves; alias adds nothing |

## Measured effect

Heldout accuracy is the judge, not train. See the after-run table in
`atlas/evidence/replay-phase3b-padded.txt` and the run with `mishearings` active
(documented in the Phase 3 report). `pulse` has no observed instance, so it is
carried for uniformity; the other three each repair *train* clips only, which is
a demonstration that the ASR residual is not the rules lane's to fix.
