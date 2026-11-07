extends "sc_client_hearing.gd"

## The client's local player half: the camera and view model, and the hands armed offline or by the server. [ScClient] wires it to the world.


func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id == _watch_id and weapons != null:
		_give_locally(weapon_id)

	if session_id != _watch_id or chat == null:
		return

	chat.say_locally("You were handed a %s." % String(weapon_id), Color(0.86, 0.92, 0.80))


## Builds a view model for this player's own hands at the handover.
##
## Drawn, never decided (`authority` is false): the server owns every shot and this is a gun that visibly deploys, reloads and kicks.
func _arm_locally() -> void:
	if weapons != null or player == null:
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.tick_rate = game.tick_rate
	# The held weapon lowers at every brush that stops the player, fences and clip included.
	weapons.wall_extra_mask = player.controller.tunables.collision_mask if player.controller != null else 0
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	weapons.ads_rules = game.ads_rules
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {
			"why": ready_now.error.message,
		})
		_disarm_locally()
		return

	# [b]Only what the server dealt[/b] (`_give_dealt`), never the whole pack: `give_everything`
	# put all of it in five slots, so a slot held whichever weapon was given last and the drawn
	# gun was not the one the server fired (mg-prop-hunt's play test).
	_give_dealt()

	# Your own shots, from your own rig: a predicted use, heard the tick it happens rather
	# than when the server's snapshot says it did. At the camera, so it is at full volume.
	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(
				camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)
			)
	)


func _give_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return
	if weapons.arsenal != null and weapons.arsenal.carries(weapon_id):
		return
	var given := weapons.give(weapon_id)
	if not given.ok:
		DotLog.warn(CHANNEL, "the drawn rig refused a weapon", {"weapon": String(weapon_id), "why": given.error.message})


## Gives the drawn rig what this player was dealt: offline the world's rig weapons, selected first; connected, every ARMED the server sent (`ScPlayer.dealt`).
##
## An ARMED that arrives after the rig is built is given by [method _on_armed].
func _give_dealt() -> void:
	if weapons == null or player == null:
		return
	var ids: Array[StringName] = []
	var world: ZeeWeaponRig = player.weapons
	if _offline and world != null and world != weapons and world.arsenal != null:
		var first := world.current_def()
		if first != null:
			ids.append(first.id)
		for slot in world.arsenal.slots():
			var held := world.arsenal.slot_at(slot)
			if held != null and held.def != null and not ids.has(held.def.id):
				ids.append(held.def.id)
	else:
		ids.append_array(player.dealt)
	for id in ids:
		_give_locally(id)
	if not ids.is_empty() and weapons.arsenal != null:
		var def := weapons.arsenal.catalogue.get_def(ids[0])
		if def != null:
			var _selected := weapons.arsenal.select(def.slot, 0)


func _disarm_locally() -> void:
	if weapons != null:
		player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = base_fov
	camera.current = true

		# Other players and stand-ins: hidden when one is at the lens, faded in third person when between camera and you. Handed the figures rather than looked up by a query: a hull is off while mp_solidplayers is 0, exactly when a body walks through you.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)

	_place_camera(player.riding)


## Puts the camera where this view mode wants it, rebuilding the rig if the mode changed.
##
## A boom in third person, nothing in first: dot-core's [DotCameraBoom] sweeps a sphere from the eye so backing to a platform edge does not put the view inside the floor, and eases in rather than snapping like a ray.
func _place_camera(seated: bool) -> void:
	if camera == null or player == null:
		return

	var eye := ScPlayer.EYE_HEIGHT + (0.9 if seated else 0.0)

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	if not third_person:
		player.add_child(camera)
		_rig_height = eye
		camera.position = Vector3(0.0, eye, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# The level, never players: they are faded instead (a stand-in behind you would pull the
	# camera into your head).
	_arm.collision_mask = _level_mask()
	_arm.add_excluded_object(player.get_rid())
	# Swept from the eye, the height above it added in the world's up: a pivot above the
	# head can itself be inside a beam, and a sweep that starts inside does not see it.
	_rig_height = eye
	_arm.lift = CHASE_UP - ScPlayer.EYE_HEIGHT
	_arm.position = Vector3(0.0, _rig_height, 0.0)
	player.add_child(_arm)

	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Swaps the view, where the server's `mp_forceview` allows. Presentation only: the
## simulation does not know which one is on.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera(player.riding if player != null else false)

	if audio != null:
		var _heard := audio.click()

	if hud != null:
		hud.shout("third person" if third_person else "first person", 1.2)


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera(player.riding if player != null else false)


## Keeps the settings' sensitivity and invert bound to the tunables the offline sampler reads now.
##
## A respawn builds fresh tunables at the default, so asked every tick (one identity comparison) because the player knows nothing of the settings; the old object is unbound so a session does not collect one per round.
func _follow_look() -> void:
	if settings == null or player == null or player.sampler == null:
		return
	var now := player.sampler.tunables
	if now == _look_tunables or now == null:
		return
	if _look_tunables != null and settings.applier != null:
		settings.applier.unbind(_look_tunables)
	_look_tunables = now
	settings.bind_look(now)


## Puts this game's three buttons and the slot onto a command.
func _stamp(command: DotFpsCommand) -> void:
	if command == null:
		return

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about, online
		# (the command sent) and offline (`command_stamp` on the world's own sample).
		command.move = Vector2.ZERO
		command.buttons = 0
		return

	command.set_button(ScNetCommand.BUTTON_FIRE, _firing)
	command.set_button(ScNetCommand.BUTTON_ALT, _alt)
	command.set_button(ScNetCommand.BUTTON_RELOAD, _reloading)


## Whether the sights may come up: on foot (never in a chopper), first person, the pointer ours, alive, not watching and not under the cover.
func _aim_allowed() -> bool:
	return _pointer_ours() and not third_person and not is_spectating() and not _covered() \
		and player != null and player.is_alive() and not player.riding


## What the command says about the sights: the view model's own state (a toggle in the rules reaches the server's spread and pace as it does the
## picture), and nothing when the sights may not come up.
func _aim_sent() -> bool:
	var hands := view_model if view_model != null and is_instance_valid(view_model) else null
	return _aim_allowed() and (hands.is_aim_held() if hands != null else _aiming)


## The sights on the picture, once a frame: the view model's aim and the lens zoom from the base field of view.
func _present_aim() -> void:
	var hands := view_model if view_model != null and is_instance_valid(view_model) else null

	if hands != null:
		hands.aim_input(_aiming and _aim_allowed())

	camera.fov = base_fov * (hands.aim_fov_scale() if hands != null and not is_spectating() else 1.0)

	if hud != null:
		hud.follow_hands(hands if hands != null and not is_spectating() else null)


func _drive_view_model(command: DotFpsCommand) -> void:
	if weapons == null or player == null:
		return

	var weapon_command := DotWeaponCommand.new()
	weapon_command.set_button(DotWeaponCommand.BUTTON_AIM, _aim_sent())

	if command != null:
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ATTACK, command.is_pressed(ScNetCommand.BUTTON_FIRE)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ALT, command.is_pressed(ScNetCommand.BUTTON_ALT)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_RELOAD, command.is_pressed(ScNetCommand.BUTTON_RELOAD)
		)
		weapon_command.yaw = command.yaw
		weapon_command.pitch = command.pitch

	weapon_command.slot = _slot

	var _outcome := weapons.simulate_tick(weapon_command, game.round_number * 100000 + Engine.get_physics_frames())

	var busy := weapon_command.is_pressed(DotWeaponCommand.BUTTON_ATTACK) \
		or weapon_command.is_pressed(DotWeaponCommand.BUTTON_RELOAD) \
		or weapons.arsenal.is_reloading() or weapons.arsenal.is_switching()
	_drawn_quiet = 0.0 if busy else _drawn_quiet + 1.0 / float(maxi(game.tick_rate, 1))
	var _corrected := correct_drawn()


## Brings the drawn gun's magazine and reserve (what the HUD counts) to the server's once it has been quiet [constant DRAWN_SETTLE_SEC]: online from this player's owner-only fields, offline from the world's rig. True when it changed anything.
##
## The drawn gun predicts, so a refused shot or a fresh refill leaves its counter wrong and nothing else corrects it.
func correct_drawn() -> bool:
	if weapons == null or weapons.arsenal == null or _drawn_quiet < DRAWN_SETTLE_SEC:
		return false

	var source := _server_count()

	if source.is_empty() or bool(source.busy):
		return false

	var arsenal := weapons.arsenal
	var held := arsenal.current()

	if held == null or int(source.slot) != arsenal.current_slot() or arsenal.is_reloading() or arsenal.is_switching():
		return false

	var changed := false

	if held.def.uses_magazine() and held.magazine != int(source.magazine):
		held.magazine = clampi(int(source.magazine), 0, held.def.magazine)
		changed = true

	if held.def.ammo_type != &"" and not held.def.infinite_reserve \
			and arsenal.ammo().count(held.def.ammo_type) != int(source.reserve):
		arsenal.ammo().set_count(held.def.ammo_type, maxi(int(source.reserve), 0))
		changed = true

	return changed


## The server's count for this player's gun: `{magazine, reserve, slot, busy}`, or empty.
func _server_count() -> Dictionary:
	if _offline:
		var world: ZeeWeaponRig = player.weapons if player != null else null
		if world == null or world == weapons or world.arsenal == null or world.arsenal.current() == null:
			return {}
		var def := world.current_def()
		return {
			"magazine": world.arsenal.current().magazine,
			"reserve": world.arsenal.ammo().count(def.ammo_type) if def.ammo_type != &"" else 0,
			"slot": world.arsenal.current_slot(),
			"busy": world.arsenal.is_reloading() or world.arsenal.is_switching(),
		}

	var mine: Variant = bridge._behaviours.get(_watch_id) if bridge != null else null
	if not (mine is ScPlayerNet):
		return {}
	var behaviour := mine as ScPlayerNet
	return {
		"magazine": behaviour.net_magazine, "reserve": behaviour.net_reserve, "slot": behaviour.net_slot,
		"busy": behaviour.net_reloading or behaviour.net_switching,
	}
