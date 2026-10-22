# Bot soak

`./game.sh soak [layout] [minutes]` runs `tools/soak.tscn`: four stand-ins in the real `ScGame` on one layout (a map here is a layout id: terraces by default), driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts, ticked externally at 64 Hz. The platform phase is cut to 15 s so the showdown, the only phase the stand-ins walk, is most of the run; only a live stand-in in the showdown counts as a mover with a goal. Rounds run back to back. The report is `.godot/test-logs/soak-<layout>.json` plus one `SOAK {...}` line (with `rounds`, `rounds_over` and `showdown_sec`), and the exit code is 1 on failure. There is no navigation mesh, so off-nav and unreachable are off; the harness does not see this game's combat, so its kill and damage counters stay 0.

**Needs the linked `addons/dot_spawn`** (gitignored like the other links, made by dot-bootstrap or `ln -s ../../dot-spawn/addons/dot_spawn addons/dot_spawn`; used by the tool only, never by the game), and an `--import` after adding it.

Object growth is allowed 40 percent here (the default is 25): the count saws up with each round's field and props and down at the teardown (about 2600 to 3300), so a run that ends mid-round read 25 to 30 percent over its start on four layouts with no leak. A real leak climbs past that.

First run, 2026-10-22, 2 simulated minutes on each of the nine layouts (full, checker, islands, spine, airfield, gauntlet, broadside, hollow, terraces): no fell-out, tick p95 3.1 to 3.5 ms, worst tick 14 ms (a round change), 3 to 4 rounds each. Object growth failed the default 25 percent on checker, islands and gauntlet (the sawtooth above), which is why the limit moved.

- The 5.0 s "stuck" stand-in seen on every layout (2026-10-22) was a firefight, not a game bug: `--trace` shows both teams meeting at the ring's middle, stopping about 9 m apart to shoot (`bot_stop_to_shoot`) and losing health until the round ends. The tool now gives no goal to a stand-in with a live enemy within 30 m. All nine layouts pass a one-minute soak.
- `--trace` prints each live stand-in once a second in the showdown (team, health, position, speed, zone).
