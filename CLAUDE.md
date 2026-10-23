# mg-smash-copter

Two to six teams stand on 10.5 m platforms balanced on single pillars forty metres up while a cannon in the middle throws props in four tiers at them; a platform leans toward whatever stands on it and comes off at sixteen degrees. Survive the clock and you are teleported to corners in the sky with a random weapon from zee-dot-weapons for a last-team-standing finish. The family's first game whose antagonist is the floor, the second on dot-game, and the first verified by a real client against a delivered pack, which is how the seventh form of the mount constraint was found.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. **The detail is in [docs/](docs/README.md)**: open the file for what you are touching.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | changing a rule of the game, the cannon, the chopper, what counts as a level, teams, the layout vote |
| [docs/platforms.md](docs/platforms.md) | touching `sc_platforms.gd`, bridges, falling, the field's teardown, what the floor looks like |
| [docs/map.md](docs/map.md) | a layout, a jump, the throat, the showdown complex in `sc_arena.gd` |
| [docs/netcode.md](docs/netcode.md) | `game/net/`, the module, prediction, anything replicated, combat and lag compensation |
| [docs/client.md](docs/client.md) | the camera, spectating, sound, figures and held weapons, HUD, settings |
| [docs/services.md](docs/services.md) | moderation tools, stats and achievements, identity |
| [docs/delivery.md](docs/delivery.md) | any `res://` path, art, a new script, project settings, a newer addon API |
| [docs/bots.md](docs/bots.md) | touching the stand-ins (`_drive_bots` and below), a `bot_*` or `sc_bot_*` cvar |
| [docs/testing.md](docs/testing.md) | adding a check, believing a green run, rendering |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening"; what this game found and how it looked |

## Layout

| Path | What |
| --- | --- |
| `game/sc_platforms.gd` | THE FILE: a slab on a pillar as a torsion spring the game integrates; bridges resting on lips |
| `game/sc_game.gd` | the simulation: phases, loads, impacts, falls, the handover. Headless |
| `game/sc_layouts.gd`, `sc_specials.gd`, `sc_content.gd` | the eight field layouts as documents and the jumps each means; special rounds as multipliers; props in four tiers and the chopper |
| `game/sc_arena.gd`, `sc_cannon.gd`, `sc_copter.gd` | the sky (a dot-lighting document), floor, tube and showdown complex in code; what the cannon throws and where; the helicopter chassis |
| `game/sc_player.gd` | one person: movement, the carry, health, weapons |
| `game/sc_config.gd`, `sc_paths.gd`, `sc_textures.gd` | every number (metres and seconds, layered); `rebase`/`rebase_onto`; the prototype grid's tint by role |
| `game/sc_module.gd`, `sc_server.gd`, `sc_services.gd`, `sc_vote.gd` | the dot-server module over `DotGameModule`, the game scene, chat/voice/moderation over `DotGameServices`, the layout vote over dot-vote |
| `game/net/` | codec, behaviours, link, and `sc_net_bridge.gd`, the only file naming both halves |
| `game/sc_client.gd`, `sc_hud.gd`, `sc_spectate.gd`, `sc_audio.gd`, `sc_figure.gd`, `sc_settings.gd`, `sc_avatars.gd`, `sc.tscn` | the client (spectate is built on both ends) |
| `game/sc_progress.gd` | stats and achievements, authority only |
| `props/` | prop bodies built from exported numbers, and the chopper |
| `assets/kenney/`, `assets/{blaster-kit,melee,arms}/`, `textures/prototype/` | vendored CC0 art, one folder per kit; the weapon pack's art; Kenney's light prototype grid |
| `scenes/sc_server.tscn`, `game.yml` | what a deployed server instantiates; the descriptor in the pack |
| `examples/` | `headless_run`, `headless_net`, `headless_workshop`, `dedicated` |
| `tools/` | `shot.sh` (`--view=…`, `--ballot`, any `--sc-*` is config), `net_shot` (`--view=walk`), `audio_probe.sh`, `bot_difficulty.sh` (stand-ins at each preset against a pinned reference), `soak.tscn` (`./game.sh soak [layout] [min]`, [soak](docs/soak.md)) |

## Running and testing

- `./game.sh` plays offline; `./game.sh online` runs a local server and browser client; `./game.sh test` parses and runs the four suites; `./game.sh shot` renders. Addon links come from `.gitignore` through dot-bootstrap.
- After touching a camera, the view key or player collision: `tools/camera_check.sh` (cameras round every deck, armed; `--render` for frames). [client](docs/client.md#cameras-and-bodies)
- **The sky's bed is wind and everybody steps** (dot-audio's stock, `ScAudio.setup`); the level is measured with `addons/dot_audio/tools/loudness.sh` (−17 LUFS band, `loudness_trim_db`), never set by ear. Stock ids have files, so the suite's stand-in checks skip them.
- **Render after any change to what is drawn**; `tools/shot.sh` is never `--headless` (a black PNG). [testing](docs/testing.md#renders-and-sound-what-no-assertion-reaches)
- **The suites cannot see delivery.** After touching paths, art or addon APIs, import, pack and join with a real client (dot-server-deploy `examples/smash_client.tscn`). [testing](docs/testing.md#the-deployment)

## Rules

- **Offline, the client's buttons go onto the world's own sample** (`ScPlayer.command_stamp`, set in `ScClient._adopt`), never onto `controller.current_command`, which `ScPlayer.simulate` samples over: that way no trigger ever reached the world's gun offline. `headless_run`'s "offline, the client's trigger" is armed ([history](docs/history.md)).
- **The hands are armed at the handover offline too** (the world's `phase_changed` and `player_armed` in `ScClient._start_offline`; `_on_phase` hears only the bridge, and offline the showdown was played with nothing drawn), with only what was dealt (`ScClient._give_dealt`: the world's rig offline, `ScPlayer.dealt` connected; never `give_everything`), counted by dot-ui's `DotAmmoCounter` bottom right and brought to the server's count once quiet (`ScClient.correct_drawn`). A hit is the server's word (`ScGame.hit_landed`, HIT to the shooter alone; `headless_net` checks the routing, armed): `DotHitMarker` and zee's red burst on the body (`play_body_hit`, by `has_method`). `headless_run`'s "at the handover the hands draw the server's guns" is armed.
- **The client's platform layer is dot-game's `DotGameClient`** (`ScClient.platform`): the loading cover, settings and Escape menu, console, Tab, M, the pointer and the input block (`input_blocked_changed` suspends both samplers). `headless_run` waits for `platform.is_shown()` and presses Tab through `settings.menu`; `tools/shot.sh --view=cover` renders the cover.
- **Every key is an `ScBindings` row read through its action**, never a keycode (Escape excepted); H is help (dot-menu's stock key; `ScSettings._fill_help` writes the rules), so no row may default to H. `headless_run` checks it and the Escape menu's Help and Leave.
- **M is the layout list** (dot-menu's map menu): `ScGame.layout_rows()` and `change_layout_now()` (the next layout plus dot-match's `begin_round_now`) serve both solo and the server, where dot-vote's map menu lets the owner's `sv_map_menu_flag` change it now and gives anybody else a vote. No row may default to M; `headless_run` and `dedicated` check it.
- **Workshop maps are solo-only layouts.** `provides.json` accepts map kind `arena` (no weapons or props: nothing reads those catalogues). A pack `map` entry's `scene` is a JSON document `{id, name, blurb?, columns, rows, row_pitch_scale?, cells: [[column, row, kind, level]]}` (`id` equals the entry id) that `ScWorkshop` reads through `DotMapCatalogue.follow_content` into `ScLayouts.workshop` as layout `workshop:<id>` (weight 0, never drawn at random). `ScClient._start_offline` follows the shared index; the M menu lists `Name [Pack]`; the game's own ids win; a server never calls it, so online (and the vote) lists none. `headless_workshop` checks it; `tools/shot.sh --workshop --view=field` renders one.
- **A seat behind its loading cover is never hurt or eliminated** (dot-game's "still loading"): `ScModule` gives the world `harm_gate` (from `can_peer_be_harmed`), `ScGame.can_be_harmed` is asked by the combat resolver's `adjust` (the one choke point: shots, crushes, blasts, falls) and by `_watch_falls`; an admin's slay or slap carries `context.admin` and passes. Bots are never loading. `dedicated` checks it over a real ENet client, armed; `tools/render_cover.sh` renders the cover and the frame after it lifts.
- **A round ends on its last moment** (`ScKillcam`, `game/sc_killcam.gd`): every drawn frame goes into dot-replay's `DotKillcamBuffer`, each death is noted, and `round_over` replays the last one from the shooter's eyes (a fall, crush or blast from the victim's) before dot-ui's `DotWinnerReveal` (the winning side) and the Tab board. `mp_killcam_time` (REPLICATED, 7, 0 off) is added to the intermission on the server (`ScGame.apply_intermission`, not when the intermission is 0, as in the suites); `reduce_motion` shows the reveal's last frame at once. No `requires.floor.json`: `headless_run` forbids one. `tools/shot.sh --view=killcam --sc-warmup-seconds=1 --seconds=2|9.5` renders both.
- A dead body falls as dot-player-char's ragdoll: the server picks the fall (`ScGame.decide_death`, on `player.death`), it rides DEATH last and optional, and the client copies it from the figure it draws (`ScClient._fall`). The `sv_ragdoll*` cvars are bound in the module, REPLICATED, and followed by the client. See dot-player-char's [docs/ragdolls.md](../dot-player-char/docs/ragdolls.md).
**The floor** ([platforms](docs/platforms.md), [design](docs/design.md))
- A platform is never a rigid body: four floats integrated semi-implicitly by `ScPlatforms`, decided by the server, adopted by clients. Never explicit Euler.
- Check a platform by its SURFACE, not its state.
- A bridge rests on its two lips and falls with either (`_rest_bridges`); it is not a platform without a pillar.
- Falling: a person within `FLOOR_REACH` of the kill height is dead; pillars are on the `pillar` layer, never solid to a person; a rider is measured by the machine. Test a fall by a real fall, never a teleport under the floor.
- Free the field by taking nodes out of the tree now and freeing at frame end; emit `world_clearing` first. A round can end inside `server_tick`.
- Shift is a brake (`can_sprint = false`), and running loads the platform (`platform_motion_gain`).
- A beach ball on every platform (dot-props' toys, `ScGame.build_toys` on both ends from the decks): rides a leaning deck, never a load and never cover; a client registers every toy mirror on TOYS before its field is laid out. [platforms](docs/platforms.md#a-beach-ball-on-every-platform)
- A round lays the field out inside the netcode's own tick, so `ScToyNet.pull` skips a toy out of the tree (dot-net history #30 skips the unregistered entity too); `headless_net` fails on any engine error in its stderr. [testing](docs/testing.md)

**The map** ([map](docs/map.md))
- A layout's blurb is a promise: declare `Layout.jumps`; the reach sweep holds declared jumps inside the reach and undeclared ones outside it.
- Nothing over the tube: `THROAT_CLEARANCE`, and the throat section fires every tier at every layout.
- The cell list travels with the layout, not just its id.
- A new level ships declared, measured, driven by a bot and rendered; see [what a level is](docs/design.md#what-a-level-is-for-the-nightly-quota).
- A chopper's pad needs a platform or a bridge under it (`Layout.chopper_cell`, `chopper_on_bridge`).
- Showdown geometry derives from the corner angles; catwalks are cut along both edges and kerbs open where a catwalk arrives.

**Netcode** ([netcode](docs/netcode.md))
- Only a player's own feet are predicted; the local mirror is owned through `_mirror_owner`. Pilots, props, platforms and choppers are the server's.
- Platform state is not interpolated; snapshots at 30 (`NET_SNAPSHOT_RATE`).
- Weapons replicate as a counter in the snapshot, never an event per shot; magazine, reserve and `net_blind` are owner-only.
- dot-combat: lag compensation turned on by the bridge together with its callables; `team_of` given to the damage resolver; `setup()` not called twice; `ScPlayer.component()` is the weapon bridge's seam.
- Tell spectating and progress about a death before dot-match (`report_kill` can end the round).
- A `DotNetMessage` script never preloads its own file; `dedicated` checks the source.
- **A READY before the player is seated is kept** (`_ready_unseated` in the bridge) and answered by `add_player`: over ENet with loss it overtakes the link's `loaded`, and a dropped READY left the client waiting for ever. `headless_net` sends it first (armed). [history](docs/history.md)
- `is_instance_valid` before casting anything the bridge looks up after a disconnect.

**Delivery** ([delivery](docs/delivery.md))
- No `class_name`; relative `preload` and `extends` only.
- Every own `res://` path through `ScPaths.rebase()` where it is defined; `rebase` is idempotent; test the mounted case through `rebase_onto`, never a built-in tautology.
- Models load by path through `rebase()`, never as `ext_resource`; one folder per Kenney kit.
- `ZeeModelCache.set_asset_root(ScPaths.root())` on client ready, `res://` back on exit.
- A property or method newer than the shipped shell is set by name, or the pack fails to parse; rebuild the shell first.
- Gravity is `ScConfig.gravity` on the world's own space; the renderer is `gl_compatibility`.
- `project.godot` carries no comments: the editor drops them, and any key left at its default, the first time it saves the file, so the reasons for its settings live here (the line above). The canvas texture filter is Nearest so the prototype grid reads as discrete squares from forty metres up, where a player judges a platform's tilt. Texture imports keep `detect_3d/compress_to=0` (`[importer_defaults]` starts new ones that way) so the editor never re-imports one VRAM-compressed on a first open.
- Colour is a tint per role over one light grid (`ScTextures.ROLE_COLOURS`), never a coloured tile; the light is `ScArena.DAYLIGHT` drawn with dot-lighting's `painted()` profile (API 3), matched to the renderer. [platforms](docs/platforms.md#readability)

**The game** ([services](docs/services.md), [client](docs/client.md))
- The layout vote opens `sc_vote_after` into a round and applies at its end (MANUAL, `END_OF_ROUND`), rocked votes too; under MANUAL `ScVote` opens a passed rock-the-vote itself, or `!rtv` does nothing. The match answers dot-vote's `round_in_progress_fn` (`world.match_node.is_live()`, set by name because an older shell's dot-vote lacks it), so a `time_up: finish_round` limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`; `dedicated` checks both halves. [design](docs/design.md#the-layout-vote)
- The HUD follows the menu's theme and HUD size (`ScHud.follow_menu`, dot-menu's `follow_hud` by name); `ScHud.piece_theme()` is the accent only (the gold, the fine green), never plate, text or ink, and the HUD's Labels set no colour of their own except the accent lines. `headless_run` checks a theme change reaches the pieces and the lines.
- dot-match `max_difference` is 0; `DotMatch.spawns_ref` is the match node itself; no dot-spawn.
- Stand-ins are never counted and a player is begun on their first number; progress in memory, reporting off.
- Refused moderation tools (respawn, give, strip) are refused for a reason `modtools` prints.
- Spectating defaults to own side; no delay; the server's automatic choice prefers a team-mate.
- `ScPlayer.retune` (every respawn and special) gives the sampler new tunables; offline, `ScClient._follow_look` rebinds the settings' look to them each tick, or a respawn reverts the sensitivity to the addon's default. `headless_run` checks it after a retune.
- **Stand-ins aim through dot-bot's `DotBotAim` on `DotBotSettings.of(world)`** (`bot_difficulty`, bound by the module and at the solo console); what is only this game's is `sc_bot_*`. In the showdown they walk the catwalks and round the ring's cover, fire only where the gun lands (`sc_bot_spray`) and press the trigger the way the weapon wants. Rerun `tools/bot_difficulty.sh` after touching them. [bots](docs/bots.md)
- The creak is derived on the client with hysteresis; the cannon's bang is a prop arriving at the muzzle; the beacon's ping stays in `DotFxBeacon`.

**Tests** ([testing](docs/testing.md))
- Every suite counts sections and a total, and both are compared. The two halves of `headless_net` differ in tick rate and field on purpose.
- Arm every guard (break it, watch it fail, put it back); assert the mechanism, not agreement.
