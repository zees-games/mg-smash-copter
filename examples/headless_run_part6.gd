extends "headless_run_part5.gd"

## Sections of [code]headless_run.gd[/code], part 6: shared state and helpers are in the base.


func _test_delivery() -> void:
	_section("a delivered pack's own paths still resolve")

	# The seventh form of the family's delivery bug, and the one that cost a boot. A
	# publisher REWRITES every `res://` string inside a `.tscn` onto the mount prefix, so an
	# exported `model_path` arrives at runtime already absolute — and rebasing it a second
	# time produced `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/assets/...`,
	# which does not load and is long enough that the doubling is easy to read past.
	#
	# Armed: reverted to the unconditional `root().path_join(...)` this fails, and the two
	# below it pass — which is what makes it worth having as its own check.
	# [b]Against a root given rather than the one this build has.[/b] Built in, `root()` is
	# `res://` and every `res://` path is already under it — so `rebase` is the identity here
	# however it is written, and asserting its behaviour against the real root passes with
	# the bug put back. That is measured: it did. [method ScPaths.rebase_onto] is the same
	# function taking the prefix, and this is the only way the mounted case is reachable
	# from a build.
	const MOUNT := "res://dot_cloud/tmc/smash/0.1.0"

	var once := ScPaths.rebase_onto("res://assets/kenney/car/debris-tire.glb", MOUNT)
	_check(
		once == MOUNT + "/assets/kenney/car/debris-tire.glb",
		"a path a script wrote is moved onto the mount",
		once
	)
	_check(
		ScPaths.rebase_onto(once, MOUNT) == once,
		"and one the publisher already rewrote is left alone"
	)

	_check(
		ScPaths.rebase("res://props/sc_crate.tscn") == ScPaths.root().path_join("props/sc_crate.tscn"),
		"and the real root is what rebase uses"
	)

	_check(
		ScPaths.rebase("user://recording.dat") == "user://recording.dat",
		"a path that is not res:// comes back untouched"
	)

	_check(
		ScPaths.rebase("res://textures/%s.png") % "deck" == ScPaths.rebase("res://textures/deck.png"),
		"a format specifier survives being rebased"
	)

	# Form one: a `class_name` in a game repository is a global the HOST does not register,
	# so a delivered pack mounts with every script in it dead and nothing reporting it. The
	# deploy tool refuses one; this says so here as well, because the deploy tool is not what
	# somebody adding a file runs.
	var declared := PackedStringArray()

	for path: String in _scripts_here():
		var text := FileAccess.get_file_as_string(path)

		for line: String in text.split("\n"):
			if line.begins_with("class_name "):
				declared.append(path)
				break

	_check(declared.is_empty(), "no script in this game declares a class_name", ", ".join(declared))

	_check_pack_references()

	_finished()


func _test_zee_art_root() -> void:
	_section("the client points zee's art at this game, and gives it back")

	# zee's art is `res://assets/…`, the host's root in a delivered pack: the client sets the cache root to
	# `ScPaths.root()` at boot and back on exit. Armed: without the `_ready` line the first check fails.
	const ELSEWHERE := "res://elsewhere/"
	const ART := "res://assets/blaster-kit/blaster-a.glb"

	ZeeModelCache.set_asset_root(ELSEWHERE)

	var client: Node = ScClient.new()
	client.force_offline = true
	client.offline_bots = 0
	client.config_file = "user://cfg/headless-none.json"
	add_child(client)
	# The field used to be drawn, and steered, while it was still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 3:
		await get_tree().process_frame
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	_check(
		ZeeModelCache.resolve(ART) == ScPaths.rebase(ART),
		"a booted client resolves zee's art under this game's root",
		ZeeModelCache.resolve(ART)
	)

	await _check_client_settings(client)

	ZeeModelCache.set_asset_root(ELSEWHERE)
	remove_child(client)
	client.free()

	_check(
		ZeeModelCache.resolve(ART) == ART,
		"a client leaving puts zee's art back at res://",
		ZeeModelCache.resolve(ART)
	)

	ZeeModelCache.set_asset_root("res://")
	_finished()


## What an administrator's blind and beacon draw, which the net and dedicated suites cannot reach.
## A headless viewport is 64 x 64, so the check is armed with an overlay anchored top-left at no size.
func _test_blind_and_beacon_drawn() -> void:
	_section("an admin's blind and beacon, drawn")

	var game := await _world()
	var me := game.add_player(&"me", "Me", 1)
	var them := game.add_player(&"them", "Them", 2)

	var hud := ScHud.new()
	add_child(hud)
	hud.bind(game, me)
	var xh := hud.find_child("Crosshair", true, false) as DotCrosshair
	_check(xh != null and xh.alive_source.is_valid() and bool(xh.alive_source.call()), "the crosshair is a DotCrosshair bound to the player's alive state")

	me.blinded = true
	for _i in range(30):
		hud.present_blind(1.0 / 60.0)
	_check(
		is_equal_approx(hud.blind_overlay.modulate.a, 1.0) and hud.blind_overlay.visible,
		"a blind fades the screen fully black within half a second",
		"%.2f" % hud.blind_overlay.modulate.a
	)
	var screen := hud.get_viewport().get_visible_rect()
	var covered := hud.blind_overlay.get_global_rect()
	_check(
		covered.encloses(screen) and covered.get_area() > 0.0,
		"and covers the whole viewport, not a HUD-sized part of it",
		"%s over %s" % [covered, screen]
	)
	_check(
		hud.blind_overlay.get_index() == 0,
		"under every number the HUD draws, which still say the round is going on"
	)

	_hud_chat_and_theme(hud)
	var vitals: DotVitals = hud.vitals

	# Health and the clock are dot-ui's glance pieces, handed this world's numbers.
	me.health.health = 17.4
	hud._process(0.0)
	_check(
		vitals.number_text() == "18" and vitals.is_low(),
		"the HUD hands health to DotVitals, red at a quarter",
		"%s low=%s" % [vitals.number_text(), str(vitals.is_low())]
	)
	_check(
		hud.strip.under_text() == hud._phase_line()
		and hud.strip.clock == (
			DotScoreStrip.clock_text(game.seconds_left())
			if game.phase != ScGame.Phase.IDLE and game.sides_are_playable() else ""
		),
		"and the clock and the phase line to DotScoreStrip",
		"%s / %s" % [hud.strip.clock, hud.strip.under_text()]
	)
	me.health.health = me.health.max_health

	# A shell whose dot-ui predates these classes cannot parse the pack: requires.json must ask for dot-ui 4.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 13 and FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 13, the weapon icons (requires.floor.json)",
		str(asks.get("dot_ui"))
	)

	me.blinded = false
	for _i in range(30):
		hud.present_blind(1.0 / 60.0)
	_check(not hud.blind_overlay.visible, "and lifts when the flag does")

	_beacon_drawn(me, them)

	hud.queue_free()
	await _dispose(game)
	_finished()


## The full chat log against the health plate, and the menu's theme reaching the HUD.
func _hud_chat_and_theme(hud: ScHud) -> void:
	var vitals: DotVitals = hud.vitals
	# The chat box's full log against the health number, both bottom-anchored, so the
	# arithmetic holds at any height: eight rows once drew over the "100".
	var chat := ScClient.new_chat()
	add_child(chat)
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var plate_bottom := -(vitals.offset_top + vitals.footprint().end.y)
	_check(
		plate_bottom >= log_top,
		"a full chat log stays under the health plate",
		"log reaches %.0f px off the bottom, the plate ends %.0f off it" % [log_top, plate_bottom]
	)
	chat.queue_free()

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var settings := ScSettings.new()
	add_child(settings)
	var _built: Variant = settings.setup(DotSettingsStoreMemory.new())
	hud.follow_menu(settings.menu)
	var plate := hud.vitals.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7, "the HUD is dark by default, in the menu's theme", str(plate))
	var _t := settings.settings.set_value(&"ui_theme", &"contrast")
	var contrast: DotMenuPalette = settings.menu.palette()
	_check(contrast.id == &"contrast" and hud.vitals.colour(&"plate") == contrast.hud_plate and hud.vitals.colour(&"text") == contrast.hud_text,
		"a theme picked in the menu reaches the pieces at once")
	_check(hud.vitals.colour(&"highlight") == Color(0.98, 0.86, 0.40) and hud._field.get_theme_color(&"font_color") == contrast.hud_text,
		"keeping this game's accent, and the HUD's own lines follow it too")
	_t = settings.settings.set_value(&"ui_theme", &"midnight")
	settings.queue_free()


## The beacon's pings, its column on other screens and when its marker goes.
func _beacon_drawn(me: ScPlayer, them: ScPlayer) -> void:
	# The beacon at sixty frames a second for 2.9 s (short of three: float sums land on a period boundary).
	# The promise is a ripple a SECOND; a ping on every frame would be 174.
	them.beacon = true
	var pings := 0
	for _i in range(174):
		if them.present_beacon(1.0 / 60.0, them.global_position, false):
			pings += 1
	_check(pings == 3, "a beacon pings once a second, starting the moment it comes on",
		"%d pings in 2.9 s" % pings)
	_check(
		them.beacon_marker != null and them.beacon_marker.column_shown(),
		"and draws its column on somebody else's screen"
	)

	me.beacon = true
	var _mine := me.present_beacon(1.0 / 60.0, me.global_position, true)
	_check(
		me.beacon_marker != null and not me.beacon_marker.column_shown(),
		"but not on the beaconed player's own, where the camera is inside it"
	)

	them.beacon = false
	var _gone := them.present_beacon(1.0 / 60.0, them.global_position, false)
	_check(them.beacon_marker == null, "the marker goes when the flag does")

	me.health.alive = false
	var _out := me.present_beacon(1.0 / 60.0, me.global_position, true)
	_check(
		me.beacon_marker == null and me.beacon,
		"and while they are out, though the flag waits for the next round"
	)


## Where somebody who is out looks, on the world that decides it.
## Five players on three sides, so a round survives two sides losing people.
func _test_somebody_out_watches() -> void:
	_section("somebody who is out watches, and the server decides whom")

	var game := await _world(func(c: ScConfig) -> void:
		c.spectate_camera = 1
		c.team_count = 3
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)

	var a := game.add_player(&"a", "A", 1)
	var mate := game.add_player(&"mate", "Mate", 1)
	var b := game.add_player(&"b", "B", 2)
	var _d := game.add_player(&"d", "D", 2)
	var c := game.add_player(&"c", "C", 3)
	game.start()
	await _step(game, 4)

	var spectate := game.spectate
	_check(spectate != null and spectate.manager.rules.force_camera == 1,
		"a world configured for own side watches own side only")
	_check(not spectate.is_spectating(&"a"), "nobody who is playing is watching")

	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, 1)

	_check(
		not a.is_alive() and spectate.mode_of(&"a") == DotSpectatorView.Mode.DEATH_CAM,
		"falling off starts the death camera"
	)

	# Armed: without `on_died`'s fall case this camera is 2 m above the kill height, looking at itself.
	var drop := spectate.camera_for(&"a")
	_check(
		drop.origin.y > game.config.deck_height and (-drop.basis.z).y < -0.9,
		"from up over the field, looking straight down the drop — not from the floor",
		"y %.1f, looking %.2f down" % [drop.origin.y, -(-drop.basis.z).y]
	)

	await _step(game, int(ScSpectate.DEATH_CAM_SECONDS * TICK_RATE) + 2)

	_check(
		spectate.mode_of(&"a") == DotSpectatorView.Mode.FIRST_PERSON
			and spectate.watching(&"a") == &"mate",
		"then through the eyes of the team-mate still up",
		"%s on %s" % [
			DotSpectatorView.Mode.keys()[spectate.mode_of(&"a")], String(spectate.watching(&"a"))
		]
	)

	var eye := mate.controller.render_state().position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0)
	_check(spectate.camera_for(&"a").origin.distance_to(eye) < 0.05,
		"where their eyes are drawn this frame")

	_check(
		not spectate.manager.may_watch("a", "b").ok and spectate.step(&"a", 1).ok
			and spectate.watching(&"a") == &"mate",
		"own side only: next is the only team-mate, and the other sides are refused"
	)
	_check(
		not spectate.step(&"a", 0).ok
			and spectate.mode_of(&"a") == DotSpectatorView.Mode.FIRST_PERSON,
		"and a chase camera is refused, because behind a team-mate sees round corners"
	)

	await _watch_anybody_allowed(game, spectate, a, b, mate)
	await _watch_side_with_nobody_up(game, spectate, a, mate)
	await _watch_next_round(game, spectate, a, c)

	await _dispose(game)
	_finished()


func _watch_anybody_allowed(game: ScGame, spectate: ScSpectate, a: ScPlayer, b: ScPlayer, mate: ScPlayer) -> void:
	spectate.set_force_camera(0)
	_check(
		spectate.step(&"a", 0).ok and spectate.mode_of(&"a") == DotSpectatorView.Mode.CHASE,
		"with anybody allowed, the other camera is behind them"
	)

	var _moved := spectate.step(&"a", 1)
	_check(spectate.watching(&"a") == &"b",
		"and a viewer stepping through the list may land on another side, and stays there",
		String(spectate.watching(&"a")))

	# The server's OWN choice: b goes, the retarget sweep has to put `a` somewhere, and the
	# first allowed name in key order is `c`. Armed: with `_prefer_side` returning at once,
	# this is `c`.
	var at_b := b.controller.state.position
	b.place_at(Vector3(at_b.x, game.config.kill_height - 5.0, at_b.z), 0.0)
	await _step(game, 2)
	_check(spectate.watching(&"a") == &"mate",
		"when the server chooses, it chooses a team-mate first",
		String(spectate.watching(&"a")))


func _watch_side_with_nobody_up(game: ScGame, spectate: ScSpectate, a: ScPlayer, mate: ScPlayer) -> void:
	spectate.set_force_camera(1)
	var at_mate := mate.controller.state.position
	mate.place_at(Vector3(at_mate.x, game.config.kill_height - 5.0, at_mate.z), 0.0)
	await _step(game, 2)
	_check(
		spectate.mode_of(&"a") == DotSpectatorView.Mode.FIXED,
		"a side with nobody left up watches from a fixed camera",
		DotSpectatorView.Mode.keys()[spectate.mode_of(&"a")]
	)

	var over := spectate.camera_for(&"a")
	_check(over.origin.y > game.config.deck_height + 10.0 and (-over.basis.z).y < 0.0,
		"over the field, looking down at it", "y %.1f" % over.origin.y)

	var was := game.phase
	game.phase = ScGame.Phase.SHOWDOWN
	var corners := spectate.camera_for(&"a")
	game.phase = was
	_check(
		corners.origin.distance_to(game.arena.showdown_centre())
			< over.origin.distance_to(game.arena.showdown_centre()),
		"and in the showdown, over the corners instead, where the round has gone"
	)


func _watch_next_round(game: ScGame, spectate: ScSpectate, a: ScPlayer, c: ScPlayer) -> void:
	# A round starting is everybody's new body. `c` going leaves one side, which ends it.
	var at_c := c.controller.state.position
	c.place_at(Vector3(at_c.x, game.config.kill_height - 5.0, at_c.z), 0.0)
	await _step(game, 12)
	_check(
		a.is_alive() and not spectate.is_spectating(&"a")
			and spectate.camera_for(&"a") == Transform3D.IDENTITY,
		"and the next round puts them back in the world, watching nothing",
		"round %d, alive %s" % [game.round_number, a.is_alive()]
	)


## What this game makes a noise about, both ways round.
## An id with no recipe stays silent with nothing logged above DEBUG; a recipe naming an unknown id reaches nothing.
func _test_the_game_makes_a_noise() -> void:
	_section("the game makes a noise, and every id has one")

	_noise_catalogue_is_whole()

	var game := await _world()
	var audio := ScAudio.new()
	add_child(audio)
	_check(audio.setup().ok and audio.manager.sink is DotAudioSinkNull,
		"it comes up headless, on the sink that records rather than plays")

	var sink := audio.manager.sink as DotAudioSinkNull
	audio.muzzle = game.arena.muzzle()

	await _noise_cannon_and_landings(game, audio, sink)

	sink.forget()
	var _yours := audio.on_death(Vector3(0.0, 1.5, 0.0), true, true)
	var _theirs := audio.on_death(Vector3(0.0, 1.5, 0.0), true, false)
	var heard := sink.played()
	_check(
		heard.size() == 2 and str(heard[0]["id"]) == String(ScAudio.YOU_ARE_OUT)
			and int(heard[0]["kind"]) == DotAudioDef.Kind.FLAT
			and str(heard[1]["id"]) == String(ScAudio.PLAYER_FELL)
			and int(heard[1]["kind"]) == DotAudioDef.Kind.POSITIONAL_3D,
		"your own fall is flat and everybody else's comes from where they went",
		str(sink.played_ids())
	)

	_noise_creaks(game, audio, sink)

	audio.queue_free()
	await _dispose(game)
	_finished()


## Every id the catalogue lists has a recipe, and every recipe an id, and the synthesiser bakes them.
func _noise_catalogue_is_whole() -> void:
	var catalogue := ScAudio.sound_catalogue()
	var recipes := ScAudio.sound_recipes()

	_check(catalogue.validate().ok, "the catalogue is a valid document")

	var declared := ScAudio.ids()
	var catalogued := catalogue.ids()
	var unlisted := catalogued.filter(func(id: StringName) -> bool: return not declared.has(id))
	var uncatalogued := declared.filter(func(id: StringName) -> bool: return not catalogued.has(id))
	_check(unlisted.is_empty() and uncatalogued.is_empty(),
		"the id list and the catalogue name the same sounds",
		"unlisted %s, uncatalogued %s" % [unlisted, uncatalogued])

	# dot-audio's stock footsteps and beds are files the addon ships, so they need no stand-in.
	var stock := DotAudioStock.ids()
	var synthesised := catalogued.filter(func(id: StringName) -> bool: return not stock.has(id))
	var silent := synthesised.filter(func(id: StringName) -> bool: return not recipes.has(id))
	_check(silent.is_empty(), "every catalogued id has a stand-in voice", str(silent))

	var nowhere: Array = recipes.keys().filter(
		func(id: Variant) -> bool: return not catalogue.has(StringName(id))
	)
	_check(nowhere.is_empty(), "and every stand-in names an id the catalogue has", str(nowhere))

	var bank := DotAudioSynth.bank(catalogue, recipes)
	var unbaked := synthesised.filter(func(id: StringName) -> bool: return not bank.has(id))
	_check(unbaked.is_empty(), "the synthesiser bakes all of them", str(unbaked))

	var kinds := [
		ZeeWeaponNet.KIND_SHOT, ZeeWeaponNet.KIND_SWING, ZeeWeaponNet.KIND_SPAWN,
		ZeeWeaponNet.KIND_BEAM, ZeeWeaponNet.KIND_THROW,
	]
	var unheard := kinds.filter(func(kind: int) -> bool:
		return not catalogue.has(ScAudio.weapon_sound(kind))
	)
	_check(
		unheard.is_empty() and ScAudio.weapon_sound(ZeeWeaponNet.KIND_NONE) == &"",
		"every kind of weapon use the snapshot can carry has a sound, and none has none",
		str(unheard)
	)


func _noise_cannon_and_landings(game: ScGame, audio: ScAudio, sink: DotAudioSinkNull) -> void:
	# The cannon is heard from anywhere on the map — and the corners are the far end of it.
	# Armed: at a corridor shooter's 90 m cull the showdown hears no cannon at all.
	audio.listen_from(game.arena.showdown_centre())
	_check(
		audio.on_prop_appeared(game.arena.muzzle() + Vector3(0.0, 1.0, 0.0)),
		"a prop at the muzzle is the cannon firing, heard from the showdown's corners",
		"%.0f m away" % game.arena.showdown_centre().distance_to(game.arena.muzzle())
	)

	audio.listen_from(game.arena.muzzle())
	_check(
		not audio.on_prop_appeared(game.arena.muzzle() + Vector3(20.0, 5.0, 0.0)),
		"and one that turns up anywhere else was already in the air — a join is not a volley"
	)

	_check(
		not audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.NONE)
			and audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.WOBBLE, 400.0)
			and audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.SHATTERED, 5000.0),
		"a landing that did nothing is silent, and the others are not"
	)
	_check(
		sink.count_of(ScAudio.IMPACT_LIGHT) == 1 and sink.count_of(ScAudio.IMPACT_HEAVY) == 1,
		"and a wobble and a shattering are two different noises"
	)


func _noise_creaks(game: ScGame, audio: ScAudio, sink: DotAudioSinkNull) -> void:
	# The creak, from the lean alone. Armed: with the hysteresis taken out, the held lean
	# creaks on every frame and this reads 1 + 29 more.
	sink.forget()
	var deck := game.platforms.deck_at(0)
	var limit := game.config.platform_collapse_lean
	audio.listen_from(deck.centre)
	deck.lean = Vector2(limit * 0.75, 0.0)
	var creaks := 0
	for _i in range(30):
		creaks += audio.present(game.platforms, limit)
	_check(
		creaks == 1 and sink.count_of(ScAudio.PLATFORM_CREAK) == 1,
		"a platform past seven tenths of its collapse angle creaks once, not every frame",
		"%d creaks, %d heard" % [creaks, sink.count_of(ScAudio.PLATFORM_CREAK)]
	)

	deck.lean = Vector2(limit * 0.3, 0.0)
	var _settled := audio.present(game.platforms, limit)
	deck.lean = Vector2(0.0, limit * 0.8)
	_check(audio.present(game.platforms, limit) == 1,
		"and again once it has settled and gone back over")

	deck.lean = Vector2(limit * 0.6, 0.0)
	var _held := audio.present(game.platforms, limit)
	deck.lean = Vector2(limit * 0.75, 0.0)
	_check(audio.present(game.platforms, limit) == 0,
		"but not for wobbling on the threshold without settling below half")


## The numbers a round produces, the achievements over them, and who is never counted.
## Three sides, so `b` going over with their platform leaves the round running.
func _check_progress_schema() -> void:
	_check(ScProgress.schema().validate().ok and ScProgress.catalogue().validate().ok,
		"the numbers and the achievements are both valid documents")

	var declared := ScProgress.ids()
	var in_schema: Array[StringName] = []
	for def in ScProgress.schema().stats:
		# dot-stats' hitzone declarations ride in the same schema and are not this game's list.
		if String(def.id).begins_with("sc."):
			in_schema.append(def.id)
	var watched := ScProgress.catalogue().watched_stats()
	var unread := watched.filter(func(id: Variant) -> bool:
		return not in_schema.has(StringName(id)))
	_check(
		unread.is_empty() and in_schema.size() == declared.size()
			and declared.all(func(id: StringName) -> bool: return in_schema.has(id)),
		"every stat an achievement reads is one the schema declares, and the list is the schema",
		"unread %s" % [unread]
	)


func _test_what_a_player_keeps() -> void:
	_section("what a player keeps from a round")

	_check_progress_schema()

	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = 3
		c.survival_seconds = 30.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 30.0
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)

	var a := game.add_player(&"a", "A", 1)
	var a2 := game.add_player(&"a2", "A2", 1)
	var b := game.add_player(&"b", "B", 2)
	var bot := game.add_player(&"bot", "Stand-in", 3)
	bot.is_bot = true

	var earned: Array[String] = []
	game.achievement_earned.connect(func(id: StringName, title: String, _points: int) -> void:
		earned.append("%s:%s" % [id, title]))

	game.start()
	# Long enough to land: a player still in the air stands on nothing.
	await _step(game, 40)

	var progress := game.progress
	_check(progress != null, "an authoritative world keeps progress")

	await _keeps_a_fall(game, progress, a)
	_keeps_dodges(game, progress, a2)
	_keeps_tipping(game, progress, b, earned)
	await _keeps_round_ends(game, progress, a, a2, b, earned)
	await _keeps_showdown_win(game, progress, a, a2, bot)

	# Armed: with the bot guard taken out of `record`, the stand-in has a row.
	_check(not progress.stats.has_player(&"bot"),
		"and the stand-in, who survived, was shot and lost, was never counted at all")

	game.remove_player(&"a2")
	_check(not progress.stats.has_player(&"a2") and not progress.achievements.has("a2"),
		"somebody who leaves stops being counted, and their progress is let go of")

	await _dispose(game)
	_finished()


func _keeps_a_fall(game: ScGame, progress: ScProgress, a: ScPlayer) -> void:
	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, 1)
	var mine := progress.session_values(&"a")
	_check(
		mine.get_value(ScProgress.DEATHS, 0.0) == 1.0 and mine.get_value(ScProgress.FALLS, 0.0) == 1.0,
		"a fall is a death and a fall"
	)


func _keeps_dodges(game: ScGame, progress: ScProgress, a2: ScPlayer) -> void:
	# Three landings on a2's platform, far side: each a WOBBLE, each a miss.
	var index := a2.standing_on
	var deck := game.platforms.deck_at(maxi(index, 0))
	var away := deck.centre + (deck.centre - a2.controller.state.position).normalized() * 3.0
	away.y = deck.centre.y
	for _i in range(3):
		var _hit := game.platforms.report_impact(index, 12.0, 5.0, Vector3(away.x, deck.centre.y, away.z))
	var dodged := progress.session_values(&"a2").get_value(ScProgress.PROPS_DODGED, 0.0)
	var lifetime := progress.achievements.progress_of("a2").value_of(ScProgress.PROPS_DODGED) \
		if progress.achievements.has("a2") else -1.0
	_check(index >= 0 and dodged == 3.0, "three things landing on your platform and missing you are three dodges",
		"%.0f on platform %d" % [dodged, index])
	# Armed: with the link bypassed (recorded wired straight into record), this is 1+2+3.
	_check(lifetime == 3.0, "and the lifetime total is three, not the running totals added up",
		"%.0f" % lifetime)


func _keeps_tipping(game: ScGame, progress: ScProgress, b: ScPlayer, earned: Array[String]) -> void:
	# b's platform goes over by LEAN with b on it: that is b's doing.
	var tipped_at := b.standing_on
	var _went_over := game.platforms.collapse(tipped_at, ScPlatforms.WHY_LEAN)
	_check(
		tipped_at >= 0 and progress.session_values(&"b").get_value(ScProgress.PLATFORMS_TIPPED, 0.0) == 1.0,
		"a platform that goes over by lean is tipped by whoever was on it"
	)
	_check(earned.has("b:Tipping Point"), "which is a secret achievement, told the moment it is earned",
		", ".join(earned))


func _keeps_round_ends(game: ScGame, progress: ScProgress, a: ScPlayer, a2: ScPlayer, b: ScPlayer, earned: Array[String]) -> void:
	# And out, without waiting the six seconds for the drop (another section checks that).
	var at_b := b.controller.state.position
	b.place_at(Vector3(at_b.x, game.config.kill_height - 5.0, at_b.z), 0.0)
	await _step(game, 1)

	game.round_elapsed = game.config.survival_seconds - 0.02
	await _step(game, 4)
	_check(game.phase == ScGame.Phase.HANDOVER and not b.is_alive(),
		"b reaches the floor, and the clock runs out", ScGame.Phase.keys()[game.phase])
	_check(
		progress.session_values(&"a2").get_value(ScProgress.ROUNDS_SURVIVED, 0.0) == 1.0
			and progress.session_values(&"a").get_value(ScProgress.ROUNDS_SURVIVED, 0.0) == 0.0
			and earned.has("a2:Still Standing"),
		"whoever is still up survived the round, and is told"
	)


func _keeps_showdown_win(game: ScGame, progress: ScProgress, a: ScPlayer, a2: ScPlayer, bot: ScPlayer) -> void:
	game.round_elapsed = game.config.showdown_starts_at() + 0.02
	await _step(game, 2)

	var shot := DotDamage.make(a2.entity_id, bot.entity_id, 1000.0, null)
	shot.point = bot.controller.state.position
	shot.tick = 10000000
	shot.context = {"why": ScGame.DIED_SHOT}
	var ended: Array[int] = []
	game.round_over.connect(func(_n: int, winner: int) -> void: ended.append(winner))
	var _applied := game.combat.apply_damage(shot)
	await _step(game, 6)

	var theirs := progress.session_values(&"a2")
	# Armed: counting moved after `report_kill` reads 0.
	_check(not ended.is_empty() and theirs.get_value(ScProgress.SHOWDOWN_KILLS, 0.0) == 1.0,
		"putting the last of a side out in the corners is a showdown kill, and ends the round",
		"%.0f kills" % theirs.get_value(ScProgress.SHOWDOWN_KILLS, 0.0))
	_check(
		theirs.get_value(ScProgress.ROUNDS_WON, 0.0) == 1.0
			and theirs.get_value(ScProgress.SHOWDOWN_WINS, 0.0) == 1.0
			and theirs.get_value(ScProgress.BEST_ROUND_KILLS, 0.0) == 1.0
			and theirs.get_value(ScProgress.ROUNDS_PLAYED, 0.0) == 1.0,
		"the last side standing won the round, and the one still in the corners won the showdown",
		"winner %s; won %.0f, showdowns %.0f, best %.0f, played %.0f" % [
			ended, theirs.get_value(ScProgress.ROUNDS_WON, 0.0),
			theirs.get_value(ScProgress.SHOWDOWN_WINS, 0.0),
			theirs.get_value(ScProgress.BEST_ROUND_KILLS, 0.0),
			theirs.get_value(ScProgress.ROUNDS_PLAYED, 0.0),
		]
	)
	_check(
		progress.session_values(&"a").get_value(ScProgress.ROUNDS_WON, 0.0) == 1.0
			and progress.session_values(&"a").get_value(ScProgress.SHOWDOWN_WINS, 0.0) == 0.0,
		"a team-mate who fell off wins the round and not the showdown"
	)