# Testing

`./game.sh test` parses every script and runs the three suites; `./game.sh test <suite>` runs one.

| Suite | What it covers |
| --- | --- |
| `examples/headless_run` | the simulation offline: platforms, bridges, falls, every layout's reach, islands and throat, bot drives through what each layout is about, the showdown complex, spectating policy, progress, sounds, what the client draws, the delivery path scan |
| `examples/headless_net` | the real path minus the socket: two worlds, managers, bridges and links with the RPC replaced by a callable; two builds with different message types; prediction, platforms, weapons, a landed shot told as HIT to the shooter alone (a second ready peer hears none; armed with the send removed or broadcast) and the owner's magazine adopted by `ScClient.correct_drawn`, spectating, identity, and **no engine error over the whole run** (an `EngineErrors` logger; a toy pulled out of the tree after a mid-tick field rebuild printed 40 on a green run; armed) |
| `examples/headless_workshop` | subscribed map packs against a fixture `DotContentIndex`: solo lists `Name [Pack]` and the world lays the document's cells out, online lists none, an unaccepted kind and a bad document are left out, own ids win. |
| `examples/dedicated` | as a real server: the console, live moderation tools, the spectate cvar, identity admission, stand-ins filing nothing, orphaned tracks, no engine errors, and the self-preload source check |

## Rules the suites follow

- **Every suite counts sections and a total of checks**, and both are compared (`SECTIONS` was once declared and read by nothing in two suites: the "name that occurs once" detector, on the suite itself). A runtime error aborts a section after it announced itself; the total is what catches that.
- **`headless_net`'s two halves are given different tick rates and different fields**, because one process has one engine rate and one default configuration, and two halves that agree by construction make every agreement check pass for the wrong reason. It cannot see Godot's RPC routing: that is `dedicated` and a real client.
- **Measure surfaces and outcomes, not state.** The platform-normal sign was only caught because the check measured the surface. A fall must be a real fall off an edge or a collapse, never a teleport under the floor (that hid that nobody ever died).
- **A route bot releases the key on arrival**: the motor repeats the last command, and a runner out of the chopper once ran on off the far side and ended the round.
- **Wait for the floor to settle** before asking for a quiet stretch with no corrections; a platform swinging to a new lean under a predicted player is a one-centimetre correction.
- **Stand-ins need per-round variety**: each stand-in's `DotBotAim` is seeded with its id and the round number. Seeded on the entity id alone, twelve showdowns were byte-identical and one bot won every round.
- **How the stand-ins play at each `bot_difficulty` is measured, not asserted**: `tools/bot_difficulty.sh` ([bots](bots.md#measured)); rerun it after touching `_drive_bots` or anything under it.

## Assert the mechanism, not the symptom

A client that predicted nothing passed "a client moves itself and the server agrees" (a client adopting every snapshot agrees) and read 0.00 corrections (the predictor never ran), while its camera lurched, drawn from a controller that never ticked. `headless_net`'s "the local player is predicted, and nobody else is" asserts the mechanism: owned, alone in `predicted()`, a key moving the player in the tick it is pressed before the server simulated it, and a server-side `place_at` corrected and converged on.

## Renders and sound: what no assertion reaches

`tools/shot.sh` is not `--headless` (the headless display driver renders nothing; a capture is a black PNG). Views: `--view=field`, `lean`, `copter`, `showdown`, `armed` (with `--sc-survival-seconds=10 --seconds=12`), `ring`, `flank`, `dais`, `junction` (`--sc-team-count=3`), `jump`, `bridge`, `beacon`, `blind`, `spectate` (and `--sc-spectate-camera=0`), `walk` (a connected client running: key to motion, corrections, eye speed per frame). Any `--sc-*` is config, so `--sc-layout-ids=<id>` picks a layout. `tools/audio_probe.sh` is the sound half: exit 0 means a speaker moved.

## The deployment

None of the suites reaches a mounted pack; see [delivery.md](delivery.md).

```bash
# in dot-server-deploy
godot --headless --path ../mg-smash-copter --import
./server pack smash --source games/mg-smash-copter
./server --game smash
# then connect the client shell to 127.0.0.1:6070
```

dot-server-deploy's `examples/smash_client.tscn` joins a delivered pack with a real client over a real socket, and is the first thing that disconnects a client in the middle of a round.
