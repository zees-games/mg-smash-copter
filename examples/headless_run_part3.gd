extends "headless_run_part2.gd"

## Sections of [code]headless_run.gd[/code], part 3: shared state and helpers are in the base.


## The slide angle is the design: slopes being walkable must not move it.
## A platform leaning 13.5 degrees is held (and walked up), one leaning 15 throws the player.
func _test_a_slope_holds() -> void:
	_section("a leaning platform holds a player below the slide angle, and not above it")

	var drift := {}

	for degrees: float in [13.5, 15.0]:
		for uphill: bool in [false, true]:
			var game := await _world(func(c: ScConfig) -> void:
				c.cannon_enabled = false
				c.specials_enabled = false
				c.layout_ids = PackedStringArray(["full"])
			)
			var platforms := game.platforms
			# Held at an angle rather than leant on: the model would move it under them.
			platforms.authoritative = false
			var lean := Vector2(deg_to_rad(degrees), 0.0)
			var deck := platforms.deck_at(0)
			platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)

			var player := game.add_player(&"stander", "Stander", 1)
			var start := deck.centre + Vector3(2.0, 0.0, 0.0)
			start.y = platforms.surface_y(0, start.x, start.z) + 0.05
			player.place_at(start, 90.0)

			# Settled first, as somebody already standing there when it tipped.
			for _i in range(40):
				platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)
				game.simulate(TICK)
				await _physics_frame()

			var x := player.controller.state.position.x

			for _i in range(TICK_RATE):
				platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)
				var command := DotFpsCommand.new()
				command.yaw = 90.0  # toward -X, up the lean
				command.move = Vector2(0.0, 1.0) if uphill else Vector2.ZERO
				command.set_button(DotFpsCommand.BUTTON_WALK, uphill)
				player.controller.apply_command(command)
				game.simulate(TICK)
				await _physics_frame()

			drift["%.1f %s" % [degrees, "up" if uphill else "idle"]] = \
				player.controller.state.position.x - x
			await _dispose(game)

	# +X is downhill.
	_check(absf(drift["13.5 idle"]) < 0.1, "a player stands still on a platform at 13.5 degrees",
		"%.2f m" % drift["13.5 idle"])
	_check(drift["13.5 up"] < -1.5, "and walks up it",
		"%.2f m in a second" % drift["13.5 up"])
	# Only standing still is asserted at 15: pressing uphill there is the addon's steep-surface air control.
	_check(drift["15.0 idle"] > 0.5,
		"and at 15 a player standing still slides down it",
		"%.2f m in a second; pushing uphill instead, %.2f m" % [
			drift["15.0 idle"], drift["15.0 up"]])
	_finished()


## Every script this game owns. Not `addons/`, which is somebody else's rules.
func _scripts_here() -> PackedStringArray:
	var found := PackedStringArray()

	for directory: String in ["res://game", "res://game/net", "res://props", "res://examples", "res://tools"]:
		for file: String in DirAccess.get_files_at(directory):
			if file.ends_with(".gd"):
				found.append(directory.path_join(file))

	return found


func _prop_scenes() -> PackedStringArray:
	var found := PackedStringArray()

	for file: String in DirAccess.get_files_at("res://props"):
		if file.ends_with(".tscn"):
			found.append("res://props".path_join(file))

	return found




## A watched melee swing is the kit's swing on the right arm, not a pistol's kick: the arm
## leaves the hold pose for the clip's length and comes back to it.
func _test_a_swing_is_drawn() -> void:
	_section("a watched melee swing is drawn as a swing")
	var figure := ScFigure.new()
	add_child(figure)
	figure.build(1.8, str(ScFigure.ATLASES[0]), Color.WHITE)
	figure.hold(&"knife", false)
	# The person's arms are bones: how far both upper arms are turned from where they were.
	var bones: Skeleton3D = figure.person.skeleton() if figure.person != null else null
	var arms: Array[int] = []
	if bones != null:
		arms = [bones.find_bone("UpperArm.L"), bones.find_bone("UpperArm.R")]
	figure.pose(Vector3.ZERO, 0.0, 0.0)
	await get_tree().process_frame
	figure.pose(Vector3.ZERO, 0.0, 0.0)
	# The wall-clock step kept a timestamp; game time leaves it alone.
	_check(figure.person != null and figure._posed_at_usec == -1,
		"a figure animates by game time (frame_delta), not the wall clock", str(figure._posed_at_usec))
	var held_at: Array[Quaternion] = []
	for b in arms:
		held_at.append(bones.get_bone_pose_rotation(b))
	var turned := func() -> float:
		var most := 0.0
		for i in arms.size():
			most = maxf(most, bones.get_bone_pose_rotation(arms[i]).angle_to(held_at[i]))
		return most

	figure.fired(1, ZeeWeaponNet.KIND_SWING)
	var furthest := 0.0
	for i in 40:
		await get_tree().process_frame
		figure.pose(Vector3.ZERO, 0.0, 0.0)
		furthest = maxf(furthest, turned.call() if bones != null else 0.0)
	_check(furthest > 0.5, "the arm swings away from the hold", "%.2f rad at most" % furthest)

	for i in 60:
		await get_tree().process_frame
		figure.pose(Vector3.ZERO, 0.0, 0.0)
	_check(bones != null and turned.call() < 0.3 and not bool(figure.describe()["swinging"]),
		"and comes back to it when the swing is over")
	figure.queue_free()
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := ScSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Smash Copter",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	_check(keys.row_for_setting(&"bind_weapon_previous").get("action", &"") == &"dot_menu_weapon_previous"
		and keys.row_for_setting(&"bind_weapon_next").get("action", &"") == &"dot_menu_weapon_next"
		and keys.row_for_setting(&"bind_weapon_previous").get("default", "") == "Wheel up"
		and keys.row_for_setting(&"bind_weapon_next").get("default", "") == "Wheel down",
		"the wheel is previous and next weapon")
	var wheel_on_jump := keys.rows.filter(func(r: Dictionary) -> bool:
		return r["action"] == &"dot_fps_jump" and str(r["default"]).begins_with("Wheel"))
	_check(wheel_on_jump.is_empty(), "and the wheel is not on jump")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every
## model the weapons table names must be here. Sync it with zee-dot-weapons' tools/sync-art.sh.
func _test_the_weapon_art_is_vendored() -> void:
	_section("every model the weapon art table names is vendored in this game")
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(ScConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = 3
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)
	var a := game.add_player(&"u1", "Ada", 1)
	var _mate := game.add_player(&"u1m", "Ada's mate", 1)
	var b := game.add_player(&"u2", "Bo", 2)
	var _c := game.add_player(&"u3", "Cy", 3)
	game.start()
	await _step(game, 4)
	var id := a.player_id
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, int(ScSpectate.DEATH_CAM_SECONDS * TICK_RATE) + 2)
	_check(b != null and game.spectate.is_spectating(id), "out by a real fall, and watching")
	_check(game.spectate.can_roam(id), "somebody who is out may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")
	_check(game.spectate.line_for(id).contains("free camera"), "and the line says so")
	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")

	var restricted := await _world(func(c: ScConfig) -> void:
		c.spectate_camera = 1)
	_check(restricted.spectate_rules.force_camera == 1 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	var keys := ScBindings.make()
	_check(keys.defaults_on("G").size() == 1 and str(keys.row_for_action(ScBindings.ROAM).get("default", "")) == "G",
		"the free camera is on G, and nothing else defaults to G")
	await _dispose(restricted)
	await _dispose(game)
	_finished()


## The family's rule: M opens the layout list, and solo a choice changes it now (the server's half is in `dedicated`).
## Offline the world samples movement itself, so the client's buttons go onto that sample, not the controller's command.
func _test_offline_trigger() -> void:
	_section("offline, the client's trigger reaches the world's gun")
	var game := await _world()
	var me := game.add_player(&"local", "You", 0, true)
	await _step(game, 2)
	var client := ScClient.new()
	client.game = game
	client._adopt(me)
	client._firing = true
	me.simulate(1, 1.0 / float(TICK_RATE))
	var pressed := game.weapon_command_for(me).is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_check(me.sampler != null and pressed, "the world's weapon command has the trigger the client holds")
	client.free()
	_finished()


## The play test's weapons at the handover, armed: without the offline handover, `give_everything` back,
## no `correct_drawn` or no HIT path, a check fails. Then the HUD's weapon sprite over the counter, per icon style.
func _check_weapon_icons(hud: Node, def: DotWeaponDef, counter: DotAmmoCounter) -> void:
	var icon_script: Script = load("res://game/sc_weapon_icons.gd")
	var icons: DotWeaponIconStyle = icon_script.get("shared")
	var icon_rect: TextureRect = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.visible and icon_rect.texture != null and icon_rect.texture == icons.texture(def.id),
		"the HUD draws the held gun's sprite over the counter, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and not icon_rect.visible, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.visible and icon_rect.get_global_rect().end.y <= counter.get_global_rect().position.y + 4.0,
		"the sprite sits above the ammunition plate, not on it")


func _test_the_drawn_gun() -> void:
	_section("at the handover the hands draw the server's guns, counted on the HUD, with a marker for a hit")
	var client: Node = ScClient.new()
	client.force_offline = true
	client.offline_bots = 1
	client.config_file = "user://cfg/headless-none.json"
	add_child(client)
	var platform: DotGameClient = client.get("platform")
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 8:
		await get_tree().process_frame
	var world: ScGame = client.get("game")
	var me: ScPlayer = client.get("player")
	world._begin_handover()
	for i in 4:
		await get_tree().physics_frame

	var drawn: ZeeWeaponRig = client.get("weapons")
	_check(drawn != null and me.weapons != null and drawn != me.weapons, "offline, the handover arms the hands")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same and drawn.arsenal.current_slot() == me.weapons.arsenal.current_slot(),
		"the drawn gun holds exactly the server's weapons, slot for slot, the same one out", " ".join(held))

	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	var def := drawn.current_def() if drawn != null else null
	var expected := "?"
	if def != null and def.ammo_type != &"":
		expected = "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] \
			if def.magazine > 0 else "%d" % drawn.arsenal.ammo().count(def.ammo_type)
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and (def.ammo_type == &"" or counter.count_text() == expected),
		"the HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])

	_check_weapon_icons(hud, def, counter)

	var corrected := true
	var detail := "melee in hand"
	if def != null and def.magazine > 0:
		var world_count := me.weapons.arsenal.current().magazine
		drawn.arsenal.current().magazine = maxi(world_count - 1, 0)
		client.set("_drawn_quiet", 0.0)
		for i in 10:
			await get_tree().physics_frame
		var early := drawn.arsenal.current().magazine
		for i in 60:
			await get_tree().physics_frame
		corrected = early == maxi(world_count - 1, 0) and drawn.arsenal.current().magazine == world_count
		detail = "after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count]
	_check(corrected, "the drawn gun takes the server's count once quiet, and not before", detail)

	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), true, false)
	_check(marker != null and marker.alpha() > 0.9 and marker.kill, "a hit the world confirms flashes the marker, a kill's")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


func _test_the_map_menu() -> void:
	_section("M opens the layout list, and solo a choice changes it")
	var game := await _world()
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 4)
	var settings := ScSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.layout_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.layout_rows, game.change_layout_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and game.layout.id == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, game.layout.id])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## Every bare `"res://…"` in a shipped script naming one of this game's directories, as `file:line`.
## The rule `dot-server-deploy/tools/check.sh` counts; comments, `rebase("…")` literals and host paths are skipped.
func _bare_own_paths() -> PackedStringArray:
	var skip := ["addons", "examples", "tools", "screenshots"]
	var owned := PackedStringArray()

	for directory: String in DirAccess.get_directories_at("res://"):
		if not directory.begins_with(".") and not skip.has(directory):
			owned.append(directory)

	var wrapped := RegEx.create_from_string("[A-Za-z0-9_]*Paths\\.rebase\\(\"res://[^\"]*\"\\)")
	var bare := RegEx.create_from_string("\"res://([^/\"]+)")
	var hits := PackedStringArray()
	var pending: Array[String] = []

	for directory: String in owned:
		pending.append("res://".path_join(directory))

	while not pending.is_empty():
		var at: String = pending.pop_back()

		for sub: String in DirAccess.get_directories_at(at):
			pending.append(at.path_join(sub))

		for file: String in DirAccess.get_files_at(at):
			if not file.ends_with(".gd"):
				continue

			var path := at.path_join(file)
			var lines := FileAccess.get_file_as_string(path).split("\n")

			for i in lines.size():
				if lines[i].strip_edges().begins_with("#"):
					continue

				for found in bare.search_all(wrapped.sub(lines[i], "", true)):
					if owned.has(found.get_string(1)):
						hits.append("%s:%d" % [path, i + 1])

	return hits
