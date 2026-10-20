# The design, and the decisions that shape it

**The first game in the family whose antagonist is the floor.** Nothing can hurt anybody for the first two thirds of a round: no weapon, no objective, nobody to shoot. The first phase is a question about where to stand on something that leans toward you, and the only inputs a player has are where they are and how fast they move. Then the clock runs out and it becomes an ordinary team fight, between exactly the people who were good at the first half. Neither half would be much alone; the second works because its people earned their place by not falling over.

## A platform is not a rigid body

The decision the whole game rests on; [platforms.md](platforms.md) has the model. A slab balanced on a thin cylinder in Godot's solver is in permanent marginal contact: it jitters at rest, its behaviour depends on contact-point ordering, and it is **not reproducible across two machines**. A crate a few centimetres out is cosmetic; a floor a few centimetres out is a player falling through something their own machine says holds them up. So a platform is an `AnimatableBody3D` driven by a torsion spring `ScPlatforms` integrates: four floats, a pure function of the loads, deterministic, and cheap enough that the server just tells every client what it decided.

## Shift is a brake

Every other 3D game here binds shift to a sprint. Here running is the default and shift is the slow walk, because a platform is destabilised in proportion to how hard the people on it are moving: the only way to cross a platform somebody is standing on the far side of is to slow down. One line in `ScPlayer.tunables_for` (`can_sprint = false`, shift on the walk action) and one term in the load model (`platform_motion_gain`). It is the one mechanic a player discovers by being punished for what every other game rewards.

## The tiers are the cannon's whole design

A crate wobbles a platform, a boulder tips it, a container takes a corner off it, a monolith deletes it with everybody on it. All four outcomes come from two numbers on a `DotPropDef` (mass and size) through one model in `ScPlatforms`, not a rule per prop. A server retunes a round by editing a document, and the suite asserts the design rather than the code.

**The cannon aims.** Firing straight up with a random lean is worse to play against: half the shots go nowhere and the rest are unreadable. This one picks a platform still standing, solves the arc to it, and scatters the aim by a few metres, so every shot is a warning readable off the sky and missing is still possible.

## The map is a description, not a build

A round's field is an id, a handful of numbers and a list of cells. A client rebuilds the identical field, every platform in the same order, and a snapshot then moves platform seven without saying what a platform is. **The cell list travels, not just the layout id**: a client deriving the field from its own catalogue would be right until its build was one layout behind the server's, and then every snapshot would move the wrong floor, silently. Thirty-odd bytes a round buys the whole class of bug. Specials (`sc_specials.gd`) are multipliers over the same model.

## No dot-spawn

A spawn point is a fixed place, and every place in this world tips, collapses, or is not there this round. The game places its own players: a side to a platform, spread round its middle, facing inward, from the field it just built; on a field of islands, one side to an island while any island is free (`_place_players`). `DotMatch.spawns_ref` is still set, to the match node itself, so dot-match never walks the scene for points (unset, it picks up another world's in a process with a server and a client, or the outgoing map's for a frame).

## The showdown is somewhere else

The corners started directly over the field, where the tube, the arc and the parked chopper are; a chopper spawned on its pad came up inside the ring's underside and sat there pinned, level, every number correct. The complex is a map's width away along -Z, still in plain sight from every platform: a player who can see where the round ends plays the first half differently. Survivors are teleported to it, each handed a random weapon from zee-dot-weapons (that draw is the second half's fairness; `give` and `strip` are refused for it).

## The chopper is a fourth chassis

`DotVehicleHover` returns early when its ground rays find nothing, which is right for a hovercraft and is the state a helicopter lives in; `DotVehicleWheeled` needs wheels on a surface. So `ScCopter` is loaded through `DotVehicleDef.chassis_script_path`, dot-vehicle's documented extension point, and nothing in that addon knows what a helicopter is.

- **Three controls fit in a `DotVehicleCommand` and the fourth does not.** Collective is throttle, pedals are steer, rotor brake is brake, and the cyclic goes in `DotVehicleInstance.meta`: widening the command would be a breaking change across the family for a field only an aircraft has.
- **It holds itself up at exactly neutral.** A machine whose neutral is a slow sink is one a player fights while trying to aim. It does not arrest a climb; that is what the ceiling is for.
- A parked chopper rests on whatever is under its pad, so every layout with one needs a platform there. `Layout.chopper_cell` names it (-1,-1 is the ordinary pad; with `chopper_on_bridge` it names a bridge, the Airfield's); `ScGame.chopper_pad_on(layout, index)` is the one reader. Server-side only: the machine replicates where it comes to rest.
- **A rider is measured by the machine for falls**: a pilot who put the chopper down on the floor sat out of the cannon's reach, alive. A machine within two metres of the kill height has reached the floor (a parked one's origin rests 0.9 m above it).

## What a level is, for the nightly quota

Decided 2026-09-23. **A level is a change to where a player can stand or go** (the field or the showdown), and it ships with its jumps declared, measured against the movement's reach, driven by a bot and rendered. In order of preference, because extending comes before adding:

1. An existing layout in `ScLayouts` rebuilt so it plays the way its own blurb says.
2. A walkable extension of the showdown complex in `ScArena`.
3. A new layout, only if it needs something the vocabulary lacks: a new `Gaps` or `Bridges` shape, or a new number on `Layout` that travels on the wire (`row_pitch_scale` and `row_shift` were added for the chequerboard). A row that only recombines existing enums and scales is a variant.

**Not a level**: a special round, a layout's weight, a cvar default, a prop. Every level declares `Layout.jumps`, passes `headless_run`'s reach and throat sections, gets a section that drives a bot through the property it is about, and is rendered (`tools/shot.sh --view=jump --sc-layout-ids=<id>`, `--view=field`).

## Teams and friendly fire

- dot-match's `max_difference` is 0, because `sides` decides a team; the default 1 refuses a join that puts a side two ahead (`force_balance = false` does not reach it) and left offline stand-ins on no team. A refused join logs at ERROR.
- **`DotDamageResolver` needs a `team_of` callable**, or `_same_team` answers false and friendly fire is on whatever the rules say. A free-for-all is right without one; a team game is silently wrong.
- **Tell spectating and progress about a death before dot-match**: `report_kill` can end the round synchronously (the last of a side is an elimination), which files the round, and the winning kill was counted in no round.

## The layout vote

A layout is drawn per round, so the players vote for the next one over dot-vote (`game/sc_vote.gd`, a `DotVoteDirector` over a `DotVoteListSource` of `ScLayouts.allowed`). dot-vote's ROUND_END trigger opens a ballot at a round's end and applies it at the next, one layout late; `ScVote` uses MANUAL instead: a ballot opens `sc_vote_after` (20) seconds into every round and is applied at the round's end (`apply: END_OF_ROUND`), setting `ScGame.next_layout_id`, which the next `_lay_out_round` uses once instead of the weighted draw (and drops if `layout_ids` no longer allows it). The module advances the director once a server tick (`self_advance` off, `round_based` on) and calls `note_round_end` from `DotMatch.round_ended`.

- **Rock the vote opens the ballot in the game, not in dot-vote.** Under MANUAL the director hands every opening to its host, a passed rock-the-vote included: without `ScVote`'s handler on `director.clock.expired` (reason `rtv`), `!rtv` answered "Rocked. 1 of 1." and nothing opened. A rocked vote still waits for the round's end (`rtv_apply`): changing the layout mid-round tears every platform down under the people standing on it. `rtv_delay_sec` is 0, because dot-vote's two minutes are as long as a whole survival phase.
- **`vary_layout` off means no ballot**: the operator asked for one layout all evening. The list is read again on every layout laid, so `layout_ids` changed between rounds reaches the ballot.
- No time limit (`duration_sec` 0), the current layout is on the ballot, no cooldown in plays. Stand-ins do not vote, so a server of stand-ins never opens one.
- dot-vote's commands (`vote`, `rtv`, `nominate`, …) are the module's, so `!vote 2` in chat reaches them through `_on_chat_command` as the player who typed it.
- The client shell draws the ballot from the `map_ballot` notice (`DotVoteBallotFeed` → `DotBallotPanel` down the right-hand side); nothing of it is in this game's client. `tools/shot.sh --ballot` draws the same panel from this game's own vote over any view.
- An owner reshapes it in `user://cfg/smash_vote.json` or `game.yml`'s `metadata: layout_vote:`, keyed as `DotVoteRules`; `{"enabled": false}` leaves the draw alone.
- `cfg/maps.yml` (or the `--config` directory's, or `sv_map_rotation_file`) says which layouts rotate, in dot-map's `DotMapRotationFile` shape (`defaults:` / `games: mg-smash-copter:`, named rotations, `maps:` lists and name globs). `ScMapSession.load_rotation` reads it and sets `DotMapDef.in_rotation`; a layout outside the active rotation stays installed (the M menu marks it "not in rotation", an admin can still change to it) but is never drawn, balloted or nominated. `sv_map_rotation <name>` switches, and the file's `commands:` block renames vote, rtv and nominate. No file: every layout rotates. A `cycle` rotation's order is not followed, the draw stays weighted.

`examples/dedicated`'s "the layout vote" section drives it through the console as a player's chat would: a nomination, the ballot opening on its own clock with the nomination on it, a vote by number, the round's end laying the winner, and rock-the-vote opening the next one early. Not yet tried in a browser.
