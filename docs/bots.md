# Stand-ins

`ScGame._drive_bots` and the showdown half below it. The family view is dot-bot's [design](../../dot-bot/docs/design.md) and [presets](../../dot-bot/docs/presets.md).

## Whose decision is whose

- **How a stand-in turns, aims and when it fires is dot-bot's**: one `DotBotAim` per stand-in per round (`_bot_aim_of`), on the game's `DotBotSettings.of(world)`. So the view turns at `bot_turn_rate`, the first shot waits `bot_reaction` (+ `bot_notice` off-axis), opens `bot_aim_error` off and settles, and a target is seen only inside `bot_fov` and `bot_sight` with nothing of the world between (`_bot_sees`). `bot_difficulty` moves this game's stand-ins with every other game's.
- **What only this game asks of them is `sc_bot_*`** (`ScConfig`): `sc_bot_advance` (how far a stand-in walks to a fight), `sc_bot_lean_notice` (degrees of lean before it walks uphill; the platform half's one mistake) and `sc_bot_spray` (how wide a miss it fires at, below).
- `sc_bot_spread` was a fixed aim offset per bot per round; it is now a deprecated name for `bot_aim_error`, kept because server configs set it. `ScConfig.bot_aim_spread_degrees` is gone.
- Bound by the module (`bind_cvars`), and solo at the console (`ScClient._bind_bot_console`, plus `-- --bot_difficulty hard` at launch). Names are `ScGame.BOT_NAMES` through `DotBotNames.pick`, solo and server alike, never twice.
- A player with its own `DotBotSettings` attached (`DotBotSettings.attach(player, …)`) plays by those instead: how `tools/bot_difficulty` pins its reference.

## The showdown walk

- **The route is the catwalks** (`_showdown_goal`, `_showdown_zone`): down the middle of its own catwalk, across the ring to the mouth of theirs, up the middle of that one. A straight line from slot to slot leaves a 3.4 m catwalk on the diagonal; with it every stand-in fell about thirty metres out.
- **On the ring it steps round the cover** (`_bot_round_cover`): the blocks facing each pad and the dais sit on every catwalk's line, and a stand-in walking the line stopped against the first block for the rest of the round. Tested at knee height (0.5 m), over the kerbs and under every block.
- **It stops to shoot as often as `bot_stop_to_shoot` says** (once per engagement, `_bot_stops_to_shoot`), but only where it may fire at all (inside `bot_max_range` and the gun's reach), and holds at `bot_range` (arm's length with a melee weapon).

## The trigger

- **Fired only where the gun lands** (`_bot_weapon_reach`): out to where the weapon's spread, standing or walking by the body's actual speed, stays within `sc_bot_spray` metres (0.6 by default: the rifle reaches 76 m standing, 16 walking), never past its `max_range`. Before this the presets that see further emptied a magazine walking from sixty metres and lost more fights than medium.
- **Pressed the way the weapon wants** (`_bot_trigger`): held for automatic and hold weapons, tapped on alternate ticks for one-a-press (`SEMI`, `BURST`), held and let go at full charge for `CHARGE`. Held down, a revolver, shotgun, marksman rifle or hatchet fired once a showdown and the charge rifle never.

## Measured

`tools/bot_difficulty.sh` plays two stand-ins at a preset against two reference stand-ins pinned to an ordinary player's numbers (game-arena's `headless_bots` reference), 20 showdowns per preset (cannon off, five seconds of platforms). Measured 2026-10-12:

| Preset | One rifle each: rounds won, K/D | The server's weapon draw: rounds won, K/D | First shot after sight (setting) |
| --- | --- | --- | --- |
| easy | 2-18, 0.35 | 6-14, 0.60 | 0.58 s (0.50) |
| medium | 11-9, 1.13 | 10-10, 1.00 | 0.31 s (0.30) |
| hard | 18-2, 2.38 | 15-5, 1.50 | 0.22 s (0.21) |
| nightmare | 17-3, 3.17 | 16-3, 2.11 | 0.12 s (0.12) |

Medium is an even match for the reference, as in game-arena. `--full` plays whole rounds with the cannon: most end in the first half when a platform goes over, which the preset does not touch, so its numbers move little between presets. `headless_run`'s "a stand-in turns, waits and then hits" holds the turn to `bot_turn_rate` and the first shot to `bot_reaction` in the game (armed against the old snap and held trigger).
