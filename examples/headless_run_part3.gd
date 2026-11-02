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
	_check(not game.spectate.toggle_roam(b.player_id).ok and not game.spectate.can_roam(b.player_id), "somebody still playing cannot roam")

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
	var icon_rect: DotWeaponIconPlate = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.texture != null and icon_rect.texture == icons.texture(def.id),
		"the HUD draws the held gun's sprite over the counter, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.texture == null, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.texture != null and icon_rect.get_global_rect().end.y <= counter.get_global_rect().position.y + 4.0,
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

	_check_wheel_step(client, drawn)

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


## The wheel steps to the next carried slot.
func _check_wheel_step(client: Node, drawn: ZeeWeaponRig) -> void:
	var ring: Array = drawn.arsenal.slots()
	var step := InputEventAction.new()
	step.action = &"dot_menu_weapon_next"
	step.pressed = true
	# The pointer is never captured headless, so only that clause of the block is lifted.
	client.call("_wheel_pressed", InputEventAction.new())
	var wheel: DotWeaponWheel = client.get(&"_wheel")
	wheel.blocked = func() -> bool: return false
	var slot_before: int = client.get(&"_slot")
	var took: bool = client.call("_wheel_pressed", step)
	var slot_after: int = client.get(&"_slot")
	client.set(&"_slot", slot_before)
	var want: int = ring[posmod(ring.find(drawn.arsenal.current_slot()) + 1, ring.size())] if ring.size() > 1 else 0
	_check(ring.size() < 2 or (took and slot_after == want),
		"the wheel steps to the next carried slot", "took %s, slot %s, want %d" % [took, slot_after, want])


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


## The showdown's pads and catwalks are edged: counted per side, since the walk section says whether the gaps are real.
func _check_showdown_edges(game: ScGame) -> void:
	# [b]The showdown's edges, which were designed, documented twice and built nowhere.[/b]
	# `_pad` was described as "one flat surface with a kerb around it", `CORNER_LIP` had a
	# doc comment explaining why the lip is not cover, and no line put one in the world. A
	# render found it; nothing here could have, so this is the check that keeps it.
	#
	# Counted rather than measured: a pad is four kerbs and a catwalk is two, because a kerb
	# across a catwalk's short end is a step in the middle of the walkway rather than a rail
	# beside it.
	#
	# Counted by SIDE rather than by piece, because a side a catwalk joins is two pieces
	# with the catwalk between them. Whether that gap is really there is not something a
	# count can say — the showdown walk below is what says it.
	var pads := 0
	var walks := 0
	var thin := PackedStringArray()

	for child: Node in game.arena.find_children("*", "StaticBody3D", true, false):
		var sides: Dictionary = {}

		for piece: Node in child.get_children():
			var piece_name := String(piece.name)

			if piece_name.begins_with("KerbHit"):
				sides[piece_name.trim_prefix("KerbHit").get_slice("_", 0)] = true

		var kerbs := sides.size()

		if String(child.name).begins_with("Catwalk"):
			walks += 1

			if kerbs != 2:
				thin.append("%s has %d" % [child.name, kerbs])
		elif String(child.name).begins_with("Pad") or child.name == "Ring":
			pads += 1

			if kerbs != 4:
				thin.append("%s has %d" % [child.name, kerbs])

	_check(pads == game.config.team_count + 1,
		"every corner and the ring is a pad", "%d pads" % pads)
	_check(walks == game.config.team_count,
		"and every corner has a catwalk to the ring", "%d walks" % walks)
	_check(thin.is_empty(),
		"a pad is edged on four sides and a catwalk on two",
		", ".join(thin))


## Forms four and three of the delivery bug: art the pack carries, and no bare own-file res:// path.
func _check_pack_references() -> void:
	# Form four: the pack carries what it references. Every model and atlas named in a prop
	# scene has to exist, because a missing one is a prop that spawns, falls, lands and
	# damages a platform while being invisible — which is what game-buses-from-hell shipped.
	var missing := PackedStringArray()
	var referenced := 0

	for path: String in _prop_scenes():
		var text := FileAccess.get_file_as_string(path)

		for line: String in text.split("\n"):
			if not (line.begins_with("model_path") or line.begins_with("atlas_path")):
				continue

			var quoted := line.get_slice("\"", 1)

			if quoted == "":
				continue

			referenced += 1

			if not ResourceLoader.exists(quoted) and not FileAccess.file_exists(quoted):
				missing.append(quoted)

	_check(referenced > 0, "the prop scenes name their art by path", "%d references" % referenced)
	_check(missing.is_empty(), "every model and atlas a prop scene names is in this repository", ", ".join(missing))

	# Form three: a script naming this game's own file by a bare `"res://…"` resolves it
	# against the HOST's root once mounted. Every such path is rebased where it is defined
	# (`static var X := ScPaths.rebase("res://…")`), because a `const` rebased at each use
	# is one new use away from a prop that silently does not spawn in a delivered round.
	# Armed: with `sc_content.gd`'s CRATE_SCENE put back to a bare `const`, this fails and
	# names the line.
	var bare := _bare_own_paths()
	_check(
		_scripts_here().size() > 0 and bare.is_empty(),
		"no shipped script names this game's own file by a bare res:// path",
		", ".join(bare)
	)


## The booted client's settings: read by sampler and camera, kept over a respawn, Escape and Tab.
func _check_client_settings(client: Node) -> void:
	# And the settings: Escape used to let go of the mouse and offer nothing to click. The
	# document is built, the sampler and the camera read it, and Escape opens the screen.
	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and bool(settings.describe().get("look_bound", 0)) \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its sampler and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)

	# [b]The sensitivity survives a respawn.[/b] `ScPlayer.retune` (every respawn, every
	# special) hands the sampler a fresh tunables object at DotFpsTunables' default, and the
	# settings stayed bound to the old one: offline, the first respawn put the view back to
	# 0.25 degrees per count whatever the slider said. Armed: without `_follow_look` both fail.
	var me: ScPlayer = client.get("player")
	if me != null:
		me.retune(me.active)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var per_count := DotMenuApplier.DEGREES_PER_COUNT
	var look_after: DotFpsTunables = me.sampler.tunables if me != null and me.sampler != null else null
	_check(
		look_after != null and settings != null and is_equal_approx(look_after.mouse_sensitivity,
			settings.settings.get_float(&"sensitivity") * per_count),
		"a respawn's fresh tunables still turn at the player's sensitivity",
		"%.4f" % (look_after.mouse_sensitivity if look_after != null else -1.0)
	)
	# Read off the applier rather than by moving the slider: this client is on the player's
	# real settings document, and `sensitivity` is ACCOUNT scope, shared by every game.
	_check(
		look_after != null and settings != null and settings.applier._look.has(look_after),
		"and the slider is bound to them, so moving it after a respawn still turns the view"
	)

	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()

	# The Tab board, held: the menu's, drawn from the local world offline.
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	settings.menu.handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().size() >= 1
		and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player on it and picked out",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	settings.menu.handle_event(tab)
	_check(board != null and not board.is_open() and not settings.is_open(), "and letting go puts it away")


## The pad's kerb closed across its catwalk, walked over at walking pace.
func _walk_over_a_kerb() -> void:
	# [b]And over a kerb, at walking pace.[/b] The openings above were cut on 2026-09-23
	# because step-up refused this game's 0.34 m kerb 0.6 m deep at any speed, whatever
	# `step_height` (0.45) said. dot-player-controller 2e6d930 fixed the step; this closes
	# the pad's kerb across its catwalk again and walks over it with the brake held, so a
	# regression in the step shows up here rather than as a survivor stuck on their pad.
	# The height reached is in the detail, for the addon's [kerb-pop-1] (a fast body is
	# thrown well over the kerb).
	var closed := await _world(func(c: ScConfig) -> void:
		c.team_count = 2
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var pad := closed.arena.get_node(^"Showdown/Pad0") as StaticBody3D
	var none: Array[Vector2] = []
	closed.arena._build_kerb(pad, Vector2(closed.config.corner_size, closed.config.corner_size),
		true, none)
	await _physics_frame()

	var home := closed.arena.corner_point(0, 2)
	var facing := closed.arena.showdown_yaw(0, 2)
	var stepper := closed.add_player(&"stepper", "Stepper", 1)
	stepper.place_at(home + Vector3.UP * 0.2, facing)
	var highest := -INF
	var over := false

	for _i in range(int(8.0 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = facing
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_WALK, true)
		stepper.controller.apply_command(command)
		closed.simulate(TICK)
		await _physics_frame()

		var now := stepper.controller.state.position
		highest = maxf(highest, now.y - home.y)

		# Two metres past the pad's edge is on the catwalk.
		if Vector2(now.x - home.x, now.z - home.z).length() > closed.config.corner_size * 0.5 + 2.0:
			over = true
			break

	_check(over and stepper.is_alive() and highest < ScArena.CORNER_LIP + 0.3,
		"a survivor walks over their pad's kerb onto the catwalk",
		"over %s, highest %.2f m over the pad against a %.2f m kerb" % [
			over, highest, ScArena.CORNER_LIP])

	await _dispose(closed)


## The reach is the movement's own; returns the flat reach.
func _check_reach_arithmetic(config: ScConfig) -> float:
	# The arithmetic first, read off the controller's tunables: flat, a jump is run speed times airtime.
	var t := ScPlayer.tunables_for(config, null)
	var flat := ScPlayer.jump_reach(config, 0.0)
	var airtime := 2.0 * sqrt(2.0 * t.gravity * t.jump_height) / t.gravity
	_check(
		absf(flat - t.max_speed * airtime) < 0.001
			and ScPlayer.jump_reach(config, 0.5) < flat
			and is_zero_approx(ScPlayer.jump_reach(config, t.jump_height + 0.01)),
		"the reach is the movement's own, and shrinks as the landing rises",
		"%.2f m flat, %.2f m onto 0.5 m" % [flat, ScPlayer.jump_reach(config, 0.5)]
	)

	return flat


## Every point of the slab's top, sampled, and every corner of every kerb, in world space.
func _catwalk_points(body: StaticBody3D) -> Array[Vector3]:
	# Every point of the slab's top, sampled, and every corner of every kerb.
	var points: Array[Vector3] = []

	for piece: Node in body.get_children():
		var collider := piece as CollisionShape3D

		if collider == null:
			continue

		var to_world := body.global_transform * collider.transform
		var convex := collider.shape as ConvexPolygonShape3D
		var box := collider.shape as BoxShape3D

		if convex != null:
			var top: Array[Vector3] = []

			for i in range(4):
				top.append(to_world * convex.points[i])

			for u in range(11):
				for v in range(41):
					var a := top[0].lerp(top[1], u / 10.0)
					var b := top[3].lerp(top[2], u / 10.0)
					points.append(a.lerp(b, v / 40.0))
		elif box != null:
			var h := box.size * 0.5

			for x: float in [-h.x, h.x]:
				for z: float in [-h.z, h.z]:
					points.append(to_world * Vector3(x, -h.y, z))

	return points


## The choppers of this layout whose parking spot is over no platform.
func _unparked_choppers(game: ScGame, layout: ScLayouts.Layout) -> PackedStringArray:
	var lost := PackedStringArray()

	if layout.with_chopper:
		for i in range(game.config.chopper_count):
			var pad := game.chopper_pad_on(layout, i)

			if game.platforms.index_at(pad.x, pad.z) < 0:
				lost.append("%s chopper %d" % [layout.id, i])

	return lost
