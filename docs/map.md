# The map: layouts, jumps, and the showdown

`game/sc_layouts.gd` holds eleven arrangements of the field as documents (`full`, `checker`, `islands`, `spine`, `airfield`, `gauntlet`, `broadside`, `hollow`, and the multi-level `terraces`, `ring`, `watchtowers`), each with a blurb that is a promise; `game/sc_arena.gd` builds the sky, the floor, the tube and the showdown complex in code. What a "level" is for the nightly quota is in [design.md](design.md#what-a-level-is-for-the-nightly-quota).

## Reach: a jump is measured, not sized by eye

`ScPlayer.jump_reach(config, rise)` is `tunables_for(config, active).jump_reach(rise)`, dot-player-controller's `DotFpsTunables.jump_reach`, so the game keeps no copy of the arithmetic. **The rise is never zero on this map**: a runner leans the platform toward the edge they run at, so the lip has dropped by the time they reach it (about 0.3 m mid-edge, 0.8 m at a corner, against a 1.15 m apex). The suite steps `ScPlatforms`' own model along the run to measure that dip for every route; it is most of the difference between a jump and a wall.

`Layout.jumps` declares which KINDS of jump a layout means (`ALONG_ROWS`, `ACROSS_HOLES`, `ACROSS_ROWS`, `DIAGONALS`); `ScLayouts.pairs()` turns kinds into pairs off the cell list; `ScPlatforms.clear_air()` measures the air along the runner's line. **The sweep is both ways**: a declared jump must be inside the reach, and an undeclared one outside even a flat running jump, because "nobody is crossing" and "every platform stands alone" are promises too. `ScLayouts.islands()` counts what a player can get to, per cell, off the built field (bridges plus declared jumps).

## The throat

The tube stands in the middle of the field with its muzzle under the decks. **Nothing may be built over it**: `ScArena.THROAT_CLEARANCE` is the 2.5 m a tumbling monolith sweeps, the middle column's bridge is not built (`_has_bridge`), and the throat section measures every layout against it and fires all-tier shots at each. On The Spine every shot once went into a bridge's underside, on a layout drawn one round in nine, because no check fired on any layout but the first. The chequerboard's field is moved half a row over so the tube stands in the hole where (2,1) would be.

## Layouts that had to be rebuilt to match their blurbs

- **The chequerboard** ("every jump is a diagonal"): its rows were 13.5 m of air apart, so it was five islands. Rows are pulled in to 0.525 of the pitch (`row_pitch_scale`) and shifted half a row (`row_shift`): each diagonal is 2.8 m, the next platform along a row 12.3 m (a fall).
- **Two Islands** ("nobody is crossing") was four islands of two. Rows at 0.51 of the pitch and columns at 1.08 make each end one island of four, crossed every way; between them 14.1 m nothing reaches, the tube in it. Sides are dealt one to an island.
- **The Spine** ("the walkways are the steady ground"): its bridges were springs pivoting in mid-air; they rest on their lips now ([platforms.md](platforms.md#bridges-rest-on-their-lips)).
- **Broadside** ("a chopper over the middle"): the chopper was on the ordinary pad, two jumps from one side and four from the other. `Layout.chopper_cell` puts it on the middle column's first-row platform, on the pillar's axis where a lean moves it least.
- **Airfield** ("there is a chopper on the pad, somebody is going to take it"): the chopper was on the ordinary pad, (3,1) on the full field, two jumps from the second side and four jumps and a bridge from the first. Its pad is the last column's bridge now (`Layout.chopper_on_bridge`): each side runs its own row to one end of the same walkway, four jumps and three, and the pad falls with either platform it rests on, taking the chopper.
- **Hollow Centre** ("loses its centre column") took three. `Gaps.HOLLOW` now loses the middle third kept to the field's parity (on five, the centre column; at least one left at each end), and the layout declares `ALONG_ROWS`: each half is a U round the hole, its bridge the only way between its rows.

Tightest declared jumps are under 3 m of a running reach of about 3-4 m (Two Islands' diagonals, the chequerboard's, Broadside's); the suite prints each with its margin.

## The showdown complex

A square ring in the middle, a pad per side at the corners, catwalks from pads to ring, perches on the flanks. Everything is derived from the same corner angles, so any team count gets one of each per pad.

- **Ring cover faces the pads.** `ScArena.ring_cover()` puts one block per team (`RING_COVER_SIZE`, 2.4 m wide, 1.1 m high) on the line from the ring's middle to that team's catwalk, half-way in, square to it: crouched behind it a survivor is out of that pad's sight; standing, they are shot at over it. The first draft put blocks between catwalks, end-on to both pads, covering nobody.
- **The flanks**: `ScArena.flank_walks()` puts a perch (`PERCH_SIZE`, 8 m) half-way round between every two pads, joined to both by catwalks that never come near the ring. From a perch the ring's blocks are side-on, so somebody hidden from the pad a block faces is in plain sight. A flank leaves a square pad at an angle, so its slab runs half its width into both ends and sits `FLANK_DROP` (2 cm) under them, or two coplanar tops z-fight.
- **The dais**: `ScArena.dais()` (`DAIS_SIZE`, 4 m square, 0.9 m high) on the ring's middle, the one cover that can be held against any side by moving round it. Its top is the trade: 0.9 m is one jump (apex 1.15) and never a step (0.45), and on it a survivor sees and is seen by every pad and perch.
- **A catwalk is cut along both edges.** `ScArena.catwalk(index)` ends each long side where it leaves the ring's square (`_line_exit`) and where it meets the pad's, a convex prism, with kerbs stopping at either edge. Measured along its middle, an oblique catwalk ran 3.2 m into the ring.
- **Kerbs are open where a catwalk arrives.** `_build_kerb` cuts an opening wherever a catwalk crosses an edge. A 0.34 m kerb 0.6 m deep stopped a runner dead; dot-player-controller's step-up handles it since, and the openings stay because a junction with no step is the better junction. A check that counted kerbs passed; it counts SIDES now, and the showdown walk fails without the openings.
- **Every edge is marked.** `CORNER_LIP` was documented twice and built nowhere, and the pads were flat shapes against a flat sky. Catwalks get the band on their long sides only: a kerb across a short end is a step at the junction a player runs through.
- The showdown is reached by teleport; its question is whether a survivor can WALK from their pad along a catwalk onto the ring, which is driven with two sides (square junctions) and three (oblique).

## Pieces and levels

A cell is `Vector3i(column, row, z)` with `z = kind | (level << 2)`: kind is PLATFORM, BRIDGE or TOWER (a tower is 0.62 of a platform, with a railing), level is 3 bits of `LEVEL_RISE` (0.6 m) each. A layout carries its own `columns` and `rows`; `ScArena._field_reach` is the widest over all of them, so the throat holds for the biggest. A bridge's pitch comes from the surface heights of its two lips and it falls with either. A bigger layout's reach sweep adds the level rise to the dip for an upward jump. Towers are never spawn points. The cell list on the wire writes two bits of kind and three of level (`sc_events.gd`).

## Riding the chopper

A body marked with the meta `ScPlayer.META_CARRIER` carries whoever stands on it: `ScPlayer._carry_on_body` applies the body's transform change over the tick (`now * was.inverse()`) to the rider's position when the ground is not a deck. The client's mirror of a chopper is marked and on the vehicle layer too, so prediction agrees. `headless_run` drives a held body by hand and checks the rider goes with it and keeps their own step on getting off. Frame: `tools/shot.sh --view=rider`.

## The map list

`ScLayouts.catalogue()` is a `DotMapCatalogue` of the allowed layouts; `ScMapSession` (a `DotMapSession`) applies a change through `world.change_layout_now` with no scene swap, and `ScModule._build_maps` wires dot-map's commands to it. Link the addon with `addons/dot_map`.
