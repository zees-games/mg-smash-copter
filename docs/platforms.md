# Platforms, bridges and falling

`game/sc_platforms.gd` is the file the game is about. Why a platform is not a rigid body is in [design.md](design.md#a-platform-is-not-a-rigid-body).

## The model

A platform is a lean (two angles), a lean velocity, a sink and a sink velocity: a torsion spring driven by the loads on the deck (people by where they stand and how hard they move, props by mass and where they land). It comes off its pillar at the collapse angle (16 degrees).

- **Semi-implicit integration, not explicit Euler.** Advancing the angle from the old velocity adds energy every step, so a spring that should settle grows, and a platform with nobody on it eventually throws itself off its own pillar. zee-dot-weapons paid for the same thing in its recoil spring.
- **The surface normal's sign**: a plane through the pivot with normal `(sin t, cos t, 0)` puts a point at `+x` BELOW the pivot. The obvious `(-sin(lean.x), 1, -sin(lean.y))` is backwards and made every platform lean away from its load, with every other symptom correct. Checks measure the SURFACE, not the state.
- **The load gain is solved, not guessed.** The equilibrium lean is `offset * kilos * gain / (inertia * stiffness)`. At gain 1.0 one person on the edge leaned a platform 1.1 degrees against a 16 degree collapse, and the walk key did nothing anybody could feel. At 1.8 a lone runner leans it about six degrees and three on one edge take it over.
- **Slopes and the slide.** `max_slope_angle` is 14 against a collapse at 16: a player standing still holds at 13.5 degrees and slides at 15. But a player pushing uphill at 15 still climbs (the controller's steep-surface air control), and one who lands moving uphill on a lean from about 12.3 degrees glides for over a second; both are dot-player-controller's behaviour, queued there. `headless_run` asserts the three parts that are this game's design.

## Bridges rest on their lips

A bridge is not a platform with the pillar left out (that pivoted in mid-air, leaned further than a platform under the same runner, fell first, and met the lips with up to 0.85 m of step). **`ScPlatforms._rest_bridges`**: a bridge's pitch is the line between its two lips' heights, its roll is theirs, a load on it is shared between the two platforms by where along it it lands, and it falls (`WHY_UNSUPPORTED`) when either does. Every bridge in the catalogue joins two platforms, so this is every layout's. The wire is unchanged: a client adopts a bridge's lean and sink like any deck's.

## Falling is fatal, everywhere

- **A person on foot within `ScGame.FLOOR_REACH` (0.5 m) of the kill height has reached the floor.** The motor rests a capsule a skin width above what it stands on, so `y <= kill_height` never fired on a real landing (1.51 against 1.5). Every fall in every suite used to be a teleport under the floor; a real fall never does that.
- **Pillars are on their own collision layer, `pillar`**: solid to props and choppers, never to a person. A player near a platform's middle used to drop 0.57 m onto the bare pillar's top when it collapsed, out of the cannon's reach, and survive to the showdown. Now a collapse takes the floor away from whoever is on it, and a faller over a pillar drops through the column (visible, and correct). The bare pillar stays as the marker `pillar_falls_with_platform` keeps it for.
- **A rider is measured by the machine** (see [design.md](design.md#the-chopper-is-a-fourth-chassis)).

## Freeing the field

- `ScPlatforms.clear` and `ScArena._clear` take children **out of the tree at once and free them at the end of the frame**: the removal stops two fields existing at one height, the deferral stops destruction landing mid-loop, because a round can end inside `DotNetManager.server_tick` while it walks the replicated entities. Neither `free()` nor `queue_free()` alone does both.
- A platform's replication behaviour is a child of its body, so freeing the field frees the behaviours. The server emits `world_clearing` so the bridge drops them first, and the tick loop has a validity guard as well; a client rebuilding its field (`_apply_layout`) unregisters the old identities the same way.

## Readability

The floor a player reads is the most important thing on screen, and every one of these was found by a picture:

- **A band in the cannon's colour round every platform**, mesh only: at the same height, neighbouring platforms are edge-on from eye level and under a metre apart, so the field read as one floor to the horizon. The rim is positioned against the SURFACE (the pivot), not the slab's middle.
- **The floor is not hazard red.** Painting the one surface nobody survives filled ninety percent of every frame and turned the platforms to specks. The drop is what says "do not go there".
- **Lit under `gl_compatibility`**: a sun of 1.05 with a filmic curve blew every surface to white and the grid, which is what a player reads a tilt off, vanished. The light is a dot-lighting document (`ScArena.DAYLIGHT`, the family's sunny look: warm high sun, pale cool fill, blue sky continued under the horizon, a light haze from 120 m) drawn with dot-lighting's `painted()` profile (`ScArena.light_profile()`), which matches the light to the renderer, lowers the exposure, grades, and adds a shadowless fill so a deck's underside and its pillar keep their edges in shade. Under the earlier hand-set numbers (reference 700, fill 0.62) a third of a player's first frame was still pure white; with `painted()` under 1 %. Shadows stay on in the browser (a few dozen boxes). Check a look change in Forward+ too (`GODOT=<a wrapper that adds --rendering-method forward_plus> tools/shot.sh`), though Compatibility is what the shell draws.
- **One light grid under a pastel per role** (`ScTextures.ROLE_COLOURS`): a near-white deck with the checker on it, mid-lavender pillars, the cannon, rims and cover in butter yellow, lavender arenas, a coral hazard rim, mint pads, a muted sky-blue floor (`Role.FLOOR`). The roles used to load six of Kenney's saturated colour tiles drawn white, which read as a neon test level; tinting one of those is a double tint that makes mud, so every role now loads the light grid (`textures/prototype/grid.png`).

## A beach ball on every platform

Each field puts one of dot-props' beach balls on every platform (not a bridge), a little toward one corner (`ScGame.build_toys`, placed from the decks on both ends in deck order: the server after `platforms.build`, a client after LAYOUT's `build_cells`). It is a real rigid body on the `toy` layer: the deck is an `AnimatableBody3D`, so a leaning platform tips the ball off its edge, a prop from the cannon or a chopper knocks it flying, and a person walks through it and pushes it (`_advance_toys`). It is not a load on the platform's spring, and it is never cover: a showdown shot down the same ray pushes it and goes on to the combat (`_shoot_toys`, dot-props' `shot_along`). Replicated as `net/sc_toy_net.gd` through TOYS after LAYOUT; a client registers every mirror the moment TOYS arrives (dot-net stops reading a snapshot at the first entity it does not know) and pairs them once its field is laid out; the server's released ids leave lag compensation's history too, or `dedicated` finds them orphaned. `sv_toys*` are bound REPLICATED and followed.

