extends "sc_client_state.gd"

## The client's spectator half: who is watched, the free camera, and the input that steps through them.

## True while the load gate covers the screen: no input, no prediction sampling, no round clock.
## False without a gate.
func _covered() -> bool:
	return gate != null and not gate.is_open()


## What the third-person and spectator cameras stop against: the course and the props.
func _level_mask() -> int:
	return game.physics.mask_of([&"world", &"prop"]) if game.physics != null else 1


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Overridden by the camera half of the client.
func _place_camera(_seated: bool) -> void:
	pass


## Overridden by the camera half of the client.
func toggle_view() -> void:
	pass



## Whether this client's own player is out and watching somebody.
func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


## The player whose eyes this camera is behind, so their body is not drawn around it.
func _watched_through_eyes() -> ScPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


## Puts the camera where [ScSpectate] says, and takes it back when a round starts.
##
## [b]The camera leaves the player's node while they watch.[/b] Setting a global transform
## on a camera hung under the chase arm is undone by the arm on its next frame, and one hung
## under the body is under a body that is not where anything worth seeing is. So it is moved
## to this node for as long as the player is out and handed back by `_place_camera` — the
## same call a view swap uses — the moment they are not.
##
## Once a FRAME, like the rig: the target's pose is the drawn one, so a camera moved on the
## tick would step at the tick rate however smoothly the target is drawn.
func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera(player.riding)

			if view_model != null and is_instance_valid(view_model):
				view_model.visible = true

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# A view model left on is somebody else's gun drawn in front of the camera.
	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false

	# Chase and death cameras pulled out of the course by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(player.player_id)

	if game.spectate.is_roaming(player.player_id):
		where = _fly_free_camera()
	else:
		_free_cam = null

	# Identity is dot-spectate's "no answer" — a target it could not find. Holding the last
	# frame is better than a camera at the world origin, which here is inside the cannon.
	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		game.spectate.roam_key = _key(ScBindings.ROAM)
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


## The free-roam key: into a free camera while out, and back onto a player from it. On a
## connected client the server decides (it owns the mode, and says no with a notice when
## `mp_freeroam 0` or `mp_forcecamera` forbids it); offline the local world is the server.
func toggle_roam() -> void:
	if not is_spectating():
		return

	_free_cam = null
	_roam_look = Vector2.ZERO

	if bridge != null:
		bridge.ask_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded
## from where the camera was on the first frame of a roam, so it starts where the spectator
## looked. The pose is kept in the manager too, so a later hand-over starts from it.
func _fly_free_camera() -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(camera.global_transform)

	var sens := deg_to_rad(_sampler.tunables.mouse_sensitivity) if _sampler != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if _pointer_ours() and not _covered():
		move = Vector3(
			_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
			_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
			_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
		)

	# Walk is the slow key here; this game has no sprint (Shift is the brake), so nothing is fast.
	var pose := _free_cam.step(move, false, _held(&"dot_fps_walk"), get_process_delta_time())
	var _kept := game.spectate.manager.move_free(String(player.player_id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := ScBindings.make().row_for_action(action)
	return str(row.get("default", action))


## Asks for the next or previous person to watch, or the other camera.
func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)

		if audio != null:
			var _denied := audio.deny()


## Everything a frame draws that a tick does not, in this order: the netcode's
## interpolation, then every player's body, then every beacon. Returns how many bodies are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [b]The interpolation was never called in this game, and a comment here said it was.[/b]
## `present_beacons`, which this replaces, read a remote player's node on the grounds that
## "everybody else's node is written by the interpolator once a frame already" — and nothing
## anywhere called `DotNetManager.interpolate_frame`, so nothing wrote it. The
## `_net_interpolated` hooks on `ScPlayerNet`, `ScPropNet` (so `ScCopterNet`) and `ScPlatformNet` were written,
## documented and reached by nothing, and every remote player, prop, chopper and the lean of
## every platform moved only when a snapshot landed — the render-jitter class, paid for in
## this family's fourth game. The other half was that a remote player had no body to move
## ([ScFigure]).
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which is what
## hides their own body. [param alpha] is the fraction through the current tick; -1 derives it
## from the engine, which is what a real frame wants. A suite passes it, because a suite's
## frames are not an engine's.
static func present_frame(
	p_net: DotNetManager,
	p_game: ScGame,
	own: ScPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: ScPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0

	for key: StringName in p_game.players:
		var body: ScPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var team := p_game.team_of(key)
		var colour := Color.WHITE

		if team >= 1 and team <= ScGame.TEAM_COLOURS.size():
			colour = ScGame.TEAM_COLOURS[team - 1]

		# And whoever a spectator is looking out of: a camera inside somebody's head draws the
		# inside of their head.
		if body.present_body((mine and first_person) or body == watched, at, colour):
			shown += 1

		# Every player's beacon, this client's own included — somebody who has been beaconed
		# sees their ring and hears their ping too. After the interpolation, so a ring is
		# placed where this frame draws them rather than where the last one did.
		var _pinged := body.present_beacon(delta, at, mine)

	return shown


## Where this frame draws [param body].
##
## [b]Two sources, and which one is not a detail.[/b] A player somebody else simulates — any
## [param remote] player on a connected client — is placed by the interpolator, which writes
## their node once a frame; their controller never ticks here, so its render state is a blend
## of two ticks that never happened. A player THIS process simulates — the local player, and
## every offline stand-in — has a node that moves once a tick, and `render_state` is the
## blend between the last two, which is what the camera is drawn from too. Not while riding:
## a rider's controller is not simulated, and the machine is what is drawn.
static func drawn_position(body: ScPlayer, remote: bool) -> Vector3:
	if remote or body.riding or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		# Opens the settings when the menu left this Escape alone, because a released pointer
		# with nothing on screen to click was a key that did half a job.
		# A second Escape never reaches here: dot-ui's stack
		# sits deeper in the tree, sees it first, and closes the screen.
		if settings != null:
			settings.open()
		return

	# Nothing below acts while the cover is up: no fire, use, reload, slot or view.
	if _covered():
		return

	if event is InputEventKey and _handle_key(event):
		return

	if _handle_pointer(event):
		return

	if player == null:
		return

	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	if event is InputEventMouseMotion and _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The game's keys, each a row of [ScBindings] read through its action, so a key moved on the
## Controls page moves what it does here. True when the key was taken.
func _handle_key(event: InputEvent) -> bool:
	if event.is_action_pressed(ScBindings.ROAM) and is_spectating():
		toggle_roam()
		return true

	if event.is_action_pressed(ScBindings.VIEW):
		# Out, the key swaps the SPECTATOR's camera, which the server decides.
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	# The slots. One to five, which is what the pack uses.
	for i in range(ScBindings.SLOTS.size()):
		if event.is_action_pressed(ScBindings.SLOTS[i]):
			_slot = i + 1
			return true

	if event.is_action(ScBindings.RELOAD):
		_reloading = event.is_pressed()
		return true

	if event.is_action_pressed(ScBindings.BOARD):
		# Boarding a chopper is a REQUEST, not a button: it happens once, must not be lost, and is
		# resolved against where the server thinks you are, not where you were a round trip ago.
		if bridge != null:
			bridge.ask_board()
		elif game != null and player != null:
			var _boarded := game.try_board(player.player_id)
		return true

	return false


## The wheel and the buttons. True when the event was taken.
func _handle_pointer(event: InputEvent) -> bool:
	# The wheel cycles the weapons in the showdown (dot-menu's stock rows, API 10); in the
	# chopper and out of the round it does nothing, and it is never jump.
	if event is InputEventMouseButton and _pointer_ours() and weapons != null and not is_spectating():
		if event.is_action_pressed(&"dot_menu_weapon_next"):
			_slot = _cycled_slot(1)
			return true
		if event.is_action_pressed(&"dot_menu_weapon_previous"):
			_slot = _cycled_slot(-1)
			return true

	if not event is InputEventMouseButton:
		return false

	var button := event as InputEventMouseButton

	# Out, the buttons step through who to watch. Nobody out has a weapon, and a click
	# that fired nothing and moved nothing is reported as the game having frozen.
	if is_spectating():
		_firing = false
		_alt = false

		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			spectate_step(1)
		elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
			spectate_step(-1)
		return true

	if button.button_index == MOUSE_BUTTON_LEFT:
		_firing = button.pressed
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		_alt = button.pressed

	return false


## The next carried slot [param step] along from the one wanted, empty slots skipped, or the
## wanted one when there is nothing to cycle to.
func _cycled_slot(step: int) -> int:
	if weapons == null or weapons.arsenal == null:
		return _slot

	var carried: Array = weapons.arsenal.slots()

	if carried.size() < 2:
		return _slot

	var at := carried.find(_slot if _slot > 0 else weapons.arsenal.current_slot())
	return int(carried[posmod(at + step, carried.size())])


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
		"armed": weapons != null,
		"watching": String(game.spectate.watching(player.player_id))
			if is_spectating() else "-",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out


## dot-game's chat box and microphone, with this game's channels and voice format. It also
## draws dot-server's own lines (the vote between games, joins, an admin's `say`), which arrive
## on the shell's client link rather than on this game's bridge. Static so a suite can build
## the same box the client does.
static func new_chat() -> DotGameChatClient:
	var box := DotGameChatClient.new()
	box.name = "Chat"
	box.channels = [
		{"id": ScServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": ScServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": ScServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	box.max_length = ScServices.chat_rules().max_length
	box.voice_config = ScServices.voice_format()
	# Six rows, not eight: a full log of eight reached the health number (ScHud puts it 170
	# pixels off the bottom; six rows end 162 off it). A wrapped vote line takes two.
	box.window_settings = {"max_lines": 6}
	return box


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: ScPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
