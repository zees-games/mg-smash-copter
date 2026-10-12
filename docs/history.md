# History: what running and delivering this game found

Kept because each could come back and the story is how it looks. None of them errored. The live rules are in the topic docs.

## Running it

- **Every platform leaned away from its load.** The surface normal had the wrong sign; it tipped, collapsed at the right angle and carried people, all in the wrong direction. Caught only because the check measured the surface.
- **A lone player could not tip anything** at a load gain of 1.0 (1.1 degrees standing on the edge). The equilibrium was four numbers nobody had solved until a screenshot made it obvious.
- **A player could not see the edge they were about to walk off**: platforms at one height are edge-on from eye level, and the grid runs straight across the join. The first rim was placed against the slab's middle rather than the surface pivot and was invisible, and the screenshot meant to prove it looked identical to the one before.
- **The map came back white, and the floor was four hundred metres of red.** Lighting tuned for the wrong renderer; the hazard colour on the one surface nobody survives filled ninety percent of every frame.
- **The bridge held freed nodes for ever.** A platform's net behaviour is a child of its body and the bridge only cleaned its table on the rebuild, after the free. Hence `world_clearing` and the validity guard. A client rebuilding its field had the same leak in the registry.
- **A mid-round joiner was never placed**: they started at the origin, forty metres down inside the kill floor, died on their first tick, and on a two-team server ended the round, which re-laid the field and freed every platform from inside the netcode's loop. The suite saw it as a flood of "previously freed instance", three layers from the cause.
- **Nobody could be shot**: no `DotHitboxSet` and no `combat.trace`, found from dot-combat's boot warning. **A teleport's yaw was taken back** by the motor reading the command. **Lag compensation was on with nothing wired.**
- **A seat made the floor survivable**: the fall check skipped riders, whose own position stops moving while carried.
- **Every round leaked a lag-compensation track per platform**, re-created by a `server_tick` holding the identity list from before the old field went.
- **The camera moved only on a tick** (it hung off the node).
- **The chequerboard had no jumps, Two Islands was four islands, Hollow Centre took three columns, Broadside's chopper was on the wrong pad, and The Spine's steady ground was the least steady thing on the map.** Each layout's blurb was a promise nothing checked. See [map.md](map.md#layouts-that-had-to-be-rebuilt-to-match-their-blurbs).
- **Every cannon shot on The Spine went into a bridge**; no check had fired a shot on any layout but the first.
- **A survivor could not walk off their own corner**: the pads' and ring's kerbs crossed the catwalk junctions, and a check counted kerbs rather than sides.
- **The showdown's winning kill was counted in no round**: `report_kill` ended the round synchronously before progress heard of it.
- **Nobody died of falling, anywhere, ever.** The motor rests a capsule a skin width above the floor (1.51 against a kill height of 1.5), and a player near a platform's middle landed on the bare pillar when it collapsed. Measured on all eight layouts, seven offsets each: all 56 alive. After `FLOOR_REACH` and the `pillar` layer, all 56 die. Every suite's falls had been teleports under the floor.
- **The weapon slot alone named nothing** on a watcher's client, so until 2026-10-08 nobody was seen holding anything and shots came out of chests.

## The prediction that never ran (2026-09-25)

`_apply_join` mirrored every player with owner 0, so nothing was predicted and the player moved a round trip behind the keys, while every check said the client agreed with the server. It is also what made the camera lurch: `render_state` blended a previous tick frozen at the last teleport with the newest snapshot. Measured with `--view=walk`, median eye speed per frame 60.9 m/s (max 1313) against 6.0 after. mg-buses-from-hell found the same line the same day; the fix is shared.

## The stats warning that was dot-stats' (cross-repo)

`dedicated` printed a new WARN that an unpublished stat would not be reported, on a server that reports nothing: `DotStatsTracker.end()` queued a leaver's delta into the reporter even with reporting off. Publishing the stat to silence it would have been changing a decision to hide a log line; it was fixed in dot-stats instead.

## dot-match's spawn warning (cross-repo)

dot-match warned "no usable spawn point at all" once per player per round, for a game that deliberately has no spawn points. Fixed in dot-match: `choose_spawn` returns null for an empty list, which is a game computing its own positions.

## Delivering it

- **The seventh form of the mount constraint** and **the check that passed with the bug put back**: [delivery.md](delivery.md#the-seventh-form-a-path-already-rewritten-rebased-again).
- **The combat manager set itself up twice** (`_ready` calls `setup()`, and `_build_combat` called it again); the tell was every setup log line printed twice in a row.
- **The pads had no edge**, and `CORNER_LIP` was documented in two places and built in none. A value documented and produced nowhere is as invisible to a suite as one produced and consumed by nothing.
- **Nobody could shoot anybody, and every check said the weapons worked.** Every shot left the world origin pointing north: `ZeeWeaponRig` resolved its carrier behind a `role == SERVER` early return (fixed in zee-dot-weapons, for every server using the pack), and this game's `ScPlayer` had no `component()`, so the weapon bridge fell back to the body transform with an identity basis. Then **friendly fire was on** in a game whose rules say off, because `team_of` was never given. No number anywhere was wrong.
- **A bot showdown produced the same winner twelve rounds in twelve**: symmetric corners and a stateless brain. The first fix drew on the entity id alone, which is the same every round, and changed nothing.
- **A client disconnected mid-round** cast freed props and platforms in the bridge (three script errors on a run that exited 0), found by `smash_client`.

## The message that preloaded itself

`sc_event.gd` and `sc_request.gd` preloaded themselves for a typed factory; here that line was the whole of the exit leak (ObjectDB instances, resources, dummy RIDs). Removed; see [netcode.md](netcode.md#messages-never-preload-yourself).

## A full chat log over the health number

The health number was lifted above the chat box's first line, not its full log: eight rows reached y 518 at 1280x720 and drew over the "100" (seen in a game-ballot frame, 2026-10-11). The box is six rows now and the number 170 px off the bottom; `headless_run` checks the arithmetic, both being bottom-anchored.

## Offline, the gun never fired in the world (2026-10-12)

`ScClient._drive_offline` stamped fire and reload onto `controller.current_command`, and the world's tick then ran `ScPlayer.simulate`, which applied a fresh `sampler.sample()` over it: the drawn gun animated, the world's rig never saw a trigger, and no shot of the player's landed in the showdown. Found in game-zombie-zone's first play test (its counter read 15 / 60 for the whole video), and the same lines were in every game built from that skeleton. The buttons go onto the sample through `command_stamp` now; `headless_run`'s "offline, the client's trigger reaches the world's gun" fails with the call removed.

- **A READY that overtook the seat was dropped (2026-10-12).** A client sends READY when its link says PLAYING, which the link decides itself after sending `loaded` on another ENet channel. Through a lossy link the READY can reach the server first; `_admit` found no player for the peer and returned, and nothing asked again, so that client never got a world. Loopback and WebSocket order the two, so no suite could see it until `headless_net` sent the READY before the seat.

## The stand-ins could not win a showdown at any difficulty (2026-10-12)

Moving the stand-ins onto dot-bot's aim and measuring them against a pinned reference turned up four things the old snap-and-hold aim had hidden. Walking the straight line from slot to slot, every stand-in left its catwalk about thirty metres out, all four on one tick, and no shot was fired in twenty rounds. Routed down the catwalks, they stopped against the ring's first cover block and stood there. Round it, the presets that see further did worse: they opened fire walking from sixty metres, where the rifle's moving spread is five times its standing one, and reloaded on arrival (nightmare lost 18 of 20 to the reference, medium 12). And held down, any one-a-press weapon fired once and a charge rifle never. The rules are in [bots.md](bots.md); the presets now come out easy 0.35, medium 1.13, hard 2.38, nightmare 3.17 K/D.
