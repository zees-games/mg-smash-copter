# The client: camera, spectating, sound, figures, HUD, menus

Built only by `ScClient`; a dedicated server draws and plays nothing.

## The camera

The rig is drawn every frame from `DotFpsController.render_state` (a blend of the controller's last two ticks), never from the player's node, which only moves on a tick: at 64 ticks and 144 frames, more than half the frames stood still. `place_at` goes through `teleport` so the handover does not sweep the view across the map for a frame, and applies a command carrying the new angle, because the motor reads its view from the COMMAND and repeats the last one: set the yaw alone and it is taken straight back. First person and third.

## Being out

Last-team-standing, so the people who are out have the most reason to watch, and in the showdown the most reason to cheat by watching. `ScSpectate` wraps a `DotSpectatorManager`, built by `ScGame` on both ends: **on a server it decides; on a connected client it is a mirror that is told** (see [netcode.md](netcode.md#what-crosses)). The client computes the camera from players its world already draws, so the wire carries a decision per event, never a transform per frame.

- **A faller's death camera is not where they died.** A fall is recorded at the kill height; `on_died` moves the camera back up over where they went down and looks down the drop (`DROP_CAM_RISE`).
- **"Own side" by default** (`sc_spectate_camera`, `ScConfig.spectate_camera`): the survival phase is harmless to watch, but a dead player on voice with a camera on the other corner is a free scout in the showdown. dot-spectate then forces first person (a chase camera sees round corners). `0` allows anybody and the chase camera, `2` nobody.
- **The server's own choice goes to a team-mate first** (`_prefer_side`); dot-spectate's key order would pick a stranger. A viewer stepping through the list is left where they asked.
- **Nobody left on your side is a fixed camera, one per phase** (`camera_for`): over the field and over the corners, built from the decks actually laid out. The phase is a fact the client has, so it is not sent.
- **No delay**: every player is always relevant, so a delay hides nothing; a mirror records no history anyway.
- The client moves its camera off the player's node while they watch (a camera under the chase arm has its transform undone by the arm) and hands it back through `_place_camera` at round start. The watched body is not drawn round a first-person camera (`present_frame`'s `watched`), and the view model is hidden. Left and right click step; F5 swaps first person and behind.

## Sound

The cannon is behind you as often as in front, and the creak is the platform under you going; here sound is information, not polish. `ScAudio.sound_catalogue()` is every decision as a document (positional or flat, cull distance, concurrency, priority) naming `.ogg` paths under `ScPaths.rebase("res://audio")`, and `sound_recipes()` names the `DotAudioSynth` voice standing in for each. Dropping a real file in switches that id over.

- **Distances are the map's**: the corners are 133 m from the tube, so the cannon and a collapse carry 260 m.
- **The cannon's bang is a prop that arrived within `MUZZLE_REACH` of the muzzle**, from `ScNetBridge.prop_arrived` (offline `props.spawned`). A prop already in the air when a client joins arrives the same way, so anything else would be a volley on every join.
- **The creak is derived on the client**: a lean past 70% of the collapse angle, from numbers every client has 30 times a second, with hysteresis (again only after settling below 50%), or it creaks every snapshot.
- **Weapons by kind of use, not by weapon**: five kinds are what a player acts on. Your own shots from your rig's `used` signal (a round trip sooner), everybody else's from `ScNetBridge.weapon_used_by`.
- **The ears are wherever the eyes are**, spectator camera included.
- **The beacon's ping stays in `ScBeacon`** (its own `AudioStreamPlayer3D`, pinned to once a second by the suite); `beacon` is the id to move it to when real audio ships.
- A headless client gets dot-audio's null sink; whether a speaker moves is `tools/audio_probe.sh` under xvfb, which drains the mixer before quitting (quitting with a voice sounding leaks the stream).

## Figures, and a gun in somebody else's hand

`ScFigure` is the Blocky Character, one of six atlases (`ScAvatars.SKINS` in `ScFigure.ATLASES` order), the side a torso tint. The stock person is the old id hash, exactly (`ScAvatars.stock_avatar`), so a server with no platform draws everybody as before.

- **The hand is at the end of the kit's own right arm, as its child.** The character is not skinned: `arm-right` is a node pivoting at the shoulder, and the kit's `holding-right` clip is that node turned -90 degrees about X (measured). The figure plays its walk or sprint and then holds the arm up itself (`HOLD_ARM`), so its `AnimationPlayer` is advanced by hand in `pose()` (`ANIMATION_CALLBACK_MODE_PROCESS_MANUAL`): left to the engine, the clip writes the arm before the hold in some frames and after it in others. The hand is scaled back to metres, or the gun reads as a toy.
- **A watched melee use is a swing**: `ScFigure.fired` samples the kit's `attack-melee-right` rotation track for `arm-right` alone, so the legs keep their clip.
- **The flash and tracer are the hand's; the report is the game's.** The world model is built with zee-dot-weapons' `sounds` off, set **by name**, because a shell older than that property fails to parse a pack that names it.

## HUD, admin overlays, chat

`ScHud`: four numbers, a tilt bar, a dot, and who you are watching.

- `blind_overlay` fades a near-black rect in under the numbers and **hides the tilt bar**, because the bar is the floor drawn as a number, and a blinded player would balance by instrument.
- **The chat box is on its own CanvasLayer (layer 2)**: in the default canvas it drew under every CanvasLayer, so a blind covered the line saying an admin had done it.
- **The health number and the chat box both anchor bottom-left**; they once overlapped. A headless viewport is 64x64, where nothing can overlap anything: only a render shows layout.
- `ScBeacon` (by preload) is a ring, a once-a-second ripple, a 30 m column through everything except on your own, placed by `ScClient.present_beacons` at the drawn position, on the client, never the world (which also runs on a dedicated server).

## Settings and the menu

`ScSettings` is dot-menu's `DotMenuSettings` with this game's schema (the same as mg-buses-from-hell's): sensitivity (ACCOUNT, the family's 0.022 degrees per unit), field of view (SERVER_CLAMPED, default 92), three volumes. Escape opens it over the field, walking suspended while it is up. The config file (`user://cfg/smash-copter.json`) is the server's rules; the settings document is the player's (`user://smash_settings`).
