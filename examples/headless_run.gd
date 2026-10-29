extends "headless_run_part3.gd"


## Proves the platforms, the cannon, the round and the chopper all actually work.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## [/codeblock]
##
## [b]The checks that matter are the ones that cross an addon boundary, and the ones that
## measure the model this game invented.[/b] dot-props, dot-combat, dot-match and dot-vehicle
## are each tested in their own repository and each of them passes there; what has never run
## before this game is the joins — and [ScPlatforms] has never run anywhere, because nothing
## in the family models a floor that tips. So the sections are named after behaviours a
## player would describe rather than after classes.
##
## [b]It steps the world by hand.[/b] `ScGame._physics_process` drives itself on a server; a
## suite that let it would be asserting against a tick count it does not control, so
## `set_physics_process(false)` goes on first and every section advances the world itself.

## Sections entered, against sections that ran to their last line.
const SECTIONS := 50

## And the total this counter cannot be.
##
## [b]A runtime error inside a section aborts that FUNCTION and nothing says so.[/b] The
## checks that already ran still print ok, the ones after it never happen, and the section
## counter is satisfied because the section announced itself on the way in. dot-settings
## reported "8 sections, 63 passed, 0 failed" and exited 0 with eight checks missing.
const CHECKS := 399


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("smash-copter headless run")
	print("")

	_test_config()
	_test_delivery()
	_test_the_weapon_art_is_vendored()
	await _test_zee_art_root()
	_test_layouts()
	await _test_world_builds()
	await _test_the_toys()
	await _test_a_platform_leans()
	await _test_walking_is_gentler()
	await _test_a_platform_collapses()
	await _test_the_carry()
	await _test_the_cannon()
	await _test_an_impact()
	await _test_falling_off()
	await _test_a_collapse_takes_everybody()
	await _test_the_round()
	await _test_sides_agree()
	await _test_specials()
	await _test_a_shot_lands()
	await _test_a_stand_in_aims()
	await _test_the_chopper()
	await _test_riding_the_chopper()
	await _test_the_pieces()
	await _test_collision_audit()
	await _test_the_map_catalogue()
	await _test_reach()
	await _test_the_throat()
	await _test_the_showdown_walk()
	await _test_catwalks_meet_their_edges()
	await _test_the_ring_cover()
	await _test_the_flanks()
	await _test_the_dais()
	await _test_the_zigzag()
	await _test_the_spine()
	await _test_two_islands()
	await _test_hollow_centre()
	await _test_broadside()
	await _test_the_airfield()
	await _test_watchtowers()
	await _test_a_slope_holds()
	await _test_blind_and_beacon_drawn()
	await _test_somebody_out_watches()
	await _test_free_roam()
	await _test_the_game_makes_a_noise()
	await _test_what_a_player_keeps()
	await _test_a_swing_is_drawn()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_offline_trigger()
	await _test_the_drawn_gun()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


# --- Sections ---------------------------------------------------------------

func _test_world_builds() -> void:
	_section("the world comes up")

	var game := await _world()

	_check(game.platforms != null and game.platforms.count() > 0,
		"there are platforms", "%d" % game.platforms.count())
	_check(game.arena != null, "there is an arena")
	_check(game.cannon != null, "there is a cannon")
	_check(game.physics != null, "the collision layout built")

	# [b]Applied, not merely assigned.[/b] Five games in this family set a layout and put it
	# on no bodies at all; everything stayed on layer one masking layer one. A platform whose
	# layer is still the default is exactly that bug.
	var deck := game.platforms.deck_at(0)
	var world_layer := game.physics.layer_mask(&"world")
	_check(deck.body.collision_layer == world_layer,
		"a platform is on the world layer", "%d vs %d" % [deck.body.collision_layer, world_layer])

	# Every platform except a bridge stands on its own pillar, which is the entire premise.
	var pillars := 0
	var bridges := 0

	for i in range(game.platforms.count()):
		var each := game.platforms.deck_at(i)

		if each.is_bridge:
			bridges += 1
		elif each.pillar != null:
			pillars += 1

	_check(pillars + bridges == game.platforms.count(),
		"every platform is on a pillar or is a bridge", "%d + %d" % [pillars, bridges])

	# The muzzle clears the tube it comes out of. A body spawned inside a collider is two
	# shapes sharing a volume, which the solver resolves by throwing one of them sideways.
	_check(game.arena.muzzle().y > game.config.deck_height * 0.8,
		"the muzzle is above the tube", "%.1f m" % game.arena.muzzle().y)

	_check(game.platforms.index_at(deck.centre.x, deck.centre.z) == 0,
		"a point over a platform finds it")
	_check(game.platforms.index_at(9000.0, 9000.0) == -1,
		"a point over nothing finds nothing")

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

	await _dispose(game)
	_finished()


## A platform that comes off its pillar takes everybody on it, wherever they stood.
## Players really fall from a real collapse and off a real edge (never `place_at` below the floor), and the section waits for the drop.
func _test_a_collapse_takes_everybody() -> void:
	_section("a platform off its pillar takes everybody on it, and the floor is fatal")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 120.0
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = false
	)

	var middle := game.add_player(&"middle", "Middle", 1)
	var near := game.add_player(&"near", "Near", 1)
	var out := game.add_player(&"out", "Out", 1)
	var edge := game.add_player(&"edge", "Edge", 1)
	# One per side kept standing elsewhere, so no side is eliminated and the round does not
	# end and re-lay the field under the four who are falling.
	var keeper := game.add_player(&"keeper", "Keeper", 1)
	var other := game.add_player(&"other", "Other", 2)

	var fell: Dictionary = {}
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName, _weapon_id: StringName) -> void:
		fell[id] = why)

	game.start()
	await _step(game, 20)

	var platforms := game.platforms
	var index := -1
	var spare := -1

	for i in range(platforms.count()):
		var each := platforms.deck_at(i)
		if each.is_bridge or not each.is_standing():
			continue
		if index < 0:
			index = i
		else:
			spare = i

	var deck := platforms.deck_at(index)
	var safe := platforms.deck_at(spare)

	# On the axis, inside the pillar's radius, just outside it, and a step past a standing platform's edge.
	middle.place_at(deck.centre + Vector3(0.0, 1.2, 0.0), 0.0)
	near.place_at(deck.centre + Vector3(0.8, 1.2, 0.3), 0.0)
	out.place_at(deck.centre + Vector3(0.0, 1.2, -3.0), 0.0)
	# Over air on the side with nothing beneath for a few metres: a neighbour is under a metre away.
	var off := Vector3.INF
	for d: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
		var clear := true
		for reach in [safe.half + 1.0, safe.half + 2.5, safe.half + 4.0]:
			var at: Vector3 = safe.centre + d * float(reach)
			if platforms.index_at(at.x, at.z) != -1:
				clear = false
		if clear:
			off = safe.centre + d * (safe.half + 1.0)
			break
	edge.place_at(off + Vector3(0.0, 1.2, 0.0), 0.0)
	keeper.place_at(safe.centre + Vector3(-1.0, 1.2, 1.0), 0.0)
	other.place_at(safe.centre + Vector3(-1.0, 1.2, -1.0), 0.0)
	await _step(game, 30)

	_check(
		middle.is_alive() and near.is_alive() and out.is_alive()
			and middle.standing_on == index and near.standing_on == index and out.standing_on == index,
		"three people are standing on one platform",
		"on %d, %d, %d of %d" % [middle.standing_on, near.standing_on, out.standing_on, index]
	)

	var went := platforms.collapse(index, ScPlatforms.WHY_LEAN)
	_check(went, "which comes off its pillar by lean")

	# Six seconds and a quarter: a forty-metre drop is under three; the rest is who landed on something.
	await _step(game, 400)

	var how := func(who: ScPlayer) -> String:
		return "%s: alive %s at y %.2f, cause %s" % [
			String(who.player_id), who.is_alive(), who.controller.state.position.y,
			String(fell.get(who.player_id, &"-")),
		]

	_check(
		fell.get(&"middle", &"") == ScGame.DIED_FELL,
		"somebody standing over the pillar falls with the platform",
		how.call(middle)
	)
	_check(
		fell.get(&"near", &"") == ScGame.DIED_FELL,
		"and so does somebody inside its radius",
		how.call(near)
	)
	_check(
		fell.get(&"out", &"") == ScGame.DIED_FELL,
		"and somebody outside it, who reaches the floor",
		how.call(out)
	)
	_check(
		fell.get(&"edge", &"") == ScGame.DIED_FELL,
		"and a step off a standing platform's edge is a fall to the floor too",
		how.call(edge)
	)
	_check(
		keeper.is_alive() and other.is_alive() and not fell.has(&"keeper"),
		"while the people on a standing platform are untouched",
		"%s, %s" % [how.call(keeper), how.call(other)]
	)

	# The pillar stays (`pillar_falls_with_platform`) and still stops thrown props; it does not hold a person.
	_check(
		deck.pillar != null and is_instance_valid(deck.pillar) and deck.pillar.is_inside_tree(),
		"the bare pillar is left standing, as the marker it is"
	)
	_check(
		game.physics.collides(&"prop", &"pillar") and game.physics.collides(&"vehicle", &"pillar")
			and not game.physics.collides(&"player", &"pillar")
			and deck.pillar.collision_layer == game.physics.layer_mask(&"pillar"),
		"solid to a prop and a chopper, and never to a person"
	)

	await _dispose(game)
	_finished()


## The gunfight chain in one check: button, arsenal tick, shot, trace, hitbox, damage rules, health record.
## Every other check can pass with health set by hand; only this one fails if a link breaks.
func _test_a_shot_lands() -> void:
	_section("a shot finds a player")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 2.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 60.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
	)

	var shooter := game.add_player(&"shooter", "Shooter", 1)
	var target := game.add_player(&"target", "Target", 2)
	game.start()

	await _step(game, int(3.0 * TICK_RATE))

	var hot := game.phase == ScGame.Phase.SHOWDOWN
	_check(hot, "the showdown is running", ScGame.Phase.keys()[game.phase])

	if not hot:
		# Deliberately NOT returning early: a section that stops adding checks is a section
		# the CHECKS total reports as a hole rather than as a failure, and a hole reads like
		# somebody edited the file. Everything below fails honestly instead.
		pass

	_check(shooter.weapons != null and target.weapons != null, "both are armed")
	_check(not target.health.invulnerable, "and the target can be hurt")

	# Face to face at eight metres, on the shooter's own pad, so the trace has the pad under
	# it and nothing else between them. Placed rather than walked: this check is about the
	# shot, and a bot that fell off on the way would fail it for the wrong reason.
	var stand := shooter.controller.state.position
	var toward := game.arena.showdown_centre() - stand
	toward.y = 0.0
	toward = toward.normalized()

	shooter.place_at(stand, rad_to_deg(atan2(-toward.x, -toward.z)))
	target.place_at(stand + toward * 8.0, rad_to_deg(atan2(toward.x, toward.z)))

	await _step(game, 4)

	var before := target.health.health
	_check(before > 0.0, "the target starts alive", "%.0f hp" % before)

	# Aimed at the chest rather than along the floor: a trace from an eye to a point eight
	# metres away at the same height passes through a standing capsule, and one aimed at the
	# feet does not.
	var eye := shooter.eye_position()
	var at := target.eye_position()
	var line := (at - eye).normalized()

	var fired := 0

	for _i in range(int(1.5 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.pitch = clampf(rad_to_deg(asin(clampf(line.y, -1.0, 1.0))), -89.0, 89.0)
		command.set_button(DotFpsCommand.BUTTON_USER_0, true)
		shooter.controller.apply_command(command)

		fired = maxi(fired, shooter.weapons.fire_seq)
		game.simulate(TICK)
		await _physics_frame()

		if target.health.health < before:
			break

	_check(shooter.weapons.fire_seq > 0, "the weapon fires",
		"%d uses" % shooter.weapons.fire_seq)
	_check(
		target.health.health < before,
		"and the target takes damage",
		"%.0f -> %.0f hp after %d uses"
			% [before, target.health.health, shooter.weapons.fire_seq]
	)

	# [b]The other half of the rule, and the one a game gets wrong quietly.[/b] Friendly fire
	# is off, so a shot down the same line at a team mate has to find nothing to do. A game
	# that resolved it anyway would play correctly right up until two people on one side
	# stood in front of each other.
	var mate := game.add_player(&"mate", "Mate", 1)
	mate.place_at(stand + toward * 8.0, rad_to_deg(atan2(toward.x, toward.z)))
	target.place_at(stand + toward * 40.0, rad_to_deg(atan2(toward.x, toward.z)))

	await _step(game, 4)

	var mate_before := mate.health.health

	for _i in range(int(1.0 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.pitch = 0.0
		command.set_button(DotFpsCommand.BUTTON_USER_0, true)
		shooter.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	_check(
		is_equal_approx(mate.health.health, mate_before),
		"a team mate in the way takes none",
		"%.0f -> %.0f hp" % [mate_before, mate.health.health]
	)

	await _dispose(game)
	_finished()


func _test_the_chopper() -> void:
	_section("the chopper flies")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.chopper_enabled = true
	)

	var copter := game.vehicles.spawn(
		ScContent.COPTER,
		Vector3(0.0, game.config.deck_height + 8.0, 0.0),
		ScContent.WORLD_OWNER
	)

	_check(copter != null, "it spawns")

	if copter == null:
		# Three checks that cannot run without one. Counted anyway, because a section that
		# quietly runs fewer checks than it says is the thing the CHECKS total exists for.
		_check(false, "it has a chassis")
		_check(false, "and the drag it always flew with")
		_check(false, "it climbs on full collective")
		_check(false, "and holds height at neutral")
		_check(false, "and will not climb past its ceiling")
		_check(false, "a pilot who puts it down on the floor has fallen")
		_check(false, "and it is recorded as a fall")
		await _dispose(game)
		_finished()
		return

	var chassis := copter.chassis as ScCopter
	_check(chassis != null, "it has a chassis")

	chassis.lift_ratio = game.config.chopper_lift
	chassis.gravity = game.config.gravity
	copter.meta[ScCopter.META_CEILING] = game.config.deck_height + game.config.chopper_ceiling

	var body := copter.body()
	var started_at := body.global_position.y

	# dot-vehicle writes the tunables' damping onto the body in REPLACE mode (4f4afaf); before,
	# the chopper's 0.12 COMBINED with the project's 0.1. The same 0.22 either way.
	var drag := body.linear_damp + (ProjectSettings.get_setting("physics/3d/default_linear_damp", 0.1) as float if body.linear_damp_mode == RigidBody3D.DAMP_MODE_COMBINE else 0.0)
	_check(is_equal_approx(drag, 0.22), "and the drag it always flew with", "%.2f" % drag)

	# Full collective for two seconds. A helicopter that cannot climb is one nobody can tell
	# from a broken one.
	var climb := DotVehicleCommand.new()
	climb.throttle = 1.0

	for _i in range(int(2.0 * TICK_RATE)):
		chassis.drive(climb, TICK)
		await _physics_frame()

	_check(body.global_position.y > started_at + 1.0, "it climbs on full collective",
		"%.1f m from %.1f m" % [body.global_position.y, started_at])

	# And it holds itself up at neutral, which is what makes the control readable: a machine
	# whose neutral is a slow sink is one a player is fighting the whole time.
	#
	# [b]From rest, because neutral does not arrest a climb and should not.[/b] A helicopter
	# at neutral collective is holding its weight, not braking — so a pilot who lets go at
	# eighteen metres a second keeps going up, which is what the ceiling is for. Measuring
	# that as "drift" would be asserting that the machine has air brakes.
	body.linear_velocity = Vector3.ZERO
	var hovering := body.global_position.y
	var hover := DotVehicleCommand.new()

	for _i in range(int(1.0 * TICK_RATE)):
		chassis.drive(hover, TICK)
		await _physics_frame()

	_check(absf(body.global_position.y - hovering) < 2.5, "and holds height at neutral",
		"%.2f m of drift" % (body.global_position.y - hovering))

	# The ceiling holds rather than shoves. One that pushed back would throw a pilot who
	# touched it through the map.
	body.global_position = Vector3(0.0, float(copter.meta[ScCopter.META_CEILING]) + 3.0, 0.0)
	body.linear_velocity = Vector3.ZERO

	for _i in range(int(1.5 * TICK_RATE)):
		chassis.drive(climb, TICK)
		await _physics_frame()

	_check(body.linear_velocity.y <= 0.5, "and will not climb past its ceiling",
		"%.2f m/s" % body.linear_velocity.y)

	# [b]The floor is the one thing nobody survives, and a seat used to be the exception.[/b]
	# A rider was skipped by the fall check because their own position stops moving while
	# they are carried — so a pilot could park on the floor out of the cannon's reach, or fly
	# off the edge of the map and fall for the rest of the round, and be handed a weapon in
	# the corners either way. Measured by the machine now, parked where it would really rest.
	var pilot := game.add_player(&"pilot", "Pilot", 1)
	game.add_player(&"other", "Other", 2)

	var deaths: Array[StringName] = []
	game.player_died.connect(
		func(id: StringName, _by: StringName, why: StringName, _weapon_id: StringName) -> void:
			if id == &"pilot":
				deaths.append(why)
	)

	body.global_position = Vector3(0.0, game.config.deck_height, game.arena._field_reach() + 10.0)
	body.linear_velocity = Vector3.ZERO
	pilot.place_at(body.global_position + Vector3(1.0, 0.0, 0.0), 0.0)
	var boarded := game.try_board(&"pilot")

	body.global_position.y = game.config.kill_height + 0.9

	for _i in range(4):
		game.simulate(TICK)
		await _physics_frame()

	_check(boarded.ok and not pilot.is_alive() and not pilot.riding,
		"a pilot who puts it down on the floor has fallen",
		"boarded %s, alive %s, riding %s" % [boarded.ok, pilot.is_alive(), pilot.riding])
	_check(deaths.has(ScGame.DIED_FELL), "and it is recorded as a fall",
		", ".join(Array(deaths).map(func(v: Variant) -> String: return String(v))))

	await _dispose(game)
	_finished()


## Every piece the new layouts are made of stands, and comes off its pillar like any other.
func _test_the_pieces() -> void:
	_section("ramps, towers and stepped islands stand at their heights and fall like platforms")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms

	for id: StringName in [&"terraces", &"ring", &"watchtowers"]:
		var layout: ScLayouts.Layout = null

		for candidate in ScLayouts.all(config):
			if candidate.id == id:
				layout = candidate

		_check(layout != null, "%s is a layout" % id)

		if layout == null:
			continue

		platforms.build(layout, game.physics)
		await _physics_frame()
		var label := String(id)

		# Bigger than the ordinary field, and not one flat height.
		var heights: Dictionary = {}
		var towers := 0
		var ramps := 0

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)
			heights["%.2f" % deck.centre.y] = true
			towers += 1 if deck.is_tower else 0

			if deck.is_bridge:
				var near := platforms.deck_at(deck.supports.x)
				var far := platforms.deck_at(deck.supports.y)

				if absf(near.centre.y - far.centre.y) > 0.1:
					ramps += 1
					# A ramp is walkable: its slope is under what the motor climbs.
					var run := deck.lips.y - deck.lips.x
					var slope := rad_to_deg(atan2(absf(near.centre.y - far.centre.y), run))
					_check(slope < ScPlayer.tunables_for(config, null).max_slope_angle,
						"%s ramp (%d,%d) is walkable" % [label, deck.column, deck.row],
						"%.1f degrees" % slope)

		_check(platforms.count() >= 10 and heights.size() >= 3,
			"%s is a bigger field at several heights" % label,
			"%d pieces at %d heights" % [platforms.count(), heights.size()])
		_check(towers > 0 or id == &"terraces", "%s has its towers" % label)
		_check(ramps > 0 or id == &"terraces", "%s has ramps" % label)

		# Every piece has a pillar that reaches the floor from its own height, standing at first.
		var pillars_ok := true

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if not deck.is_standing():
				pillars_ok = false

			if deck.pillar != null:
				var top := deck.pillar.position.y + 0.5 * (
					deck.pillar.get_node(^"Collision").shape as CylinderShape3D).height

				if absf(top - (deck.centre.y - config.platform_thickness)) > 0.01:
					pillars_ok = false

		_check(pillars_ok, "%s: every piece is standing on a pillar of its own height" % label)

		# The cells survive the wire, kinds and levels both.
		var cells := platforms.cells()
		var back := ScEvents.read_layout(DotNetReader.new(ScEvents.write_layout(
			layout.id, platforms.field_columns(), platforms.field_rows(), config.column_pitch,
			config.row_pitch, config.platform_size, config.deck_height, layout.pitch_scale,
			layout.stiffness_scale, cells, layout.row_pitch_scale, layout.row_shift
		)))
		var came: Array[Vector3i] = back["cells"]
		_check(bool(back["ok"]) and came == cells,
			"%s: every piece's kind and level crosses the wire" % label)

		# Each kind of piece comes off its pillar when leant on and takes its bridges along (fresh build each).
		var highest := 0

		for i in range(platforms.count()):
			if not platforms.deck_at(i).is_bridge \
					and platforms.deck_at(i).centre.y > platforms.deck_at(highest).centre.y:
				highest = i

		if platforms.deck_at(highest).is_bridge:
			highest = 0

		var piece := platforms.deck_at(highest)
		var edge := piece.centre + Vector3(piece.half, 0.0, 0.0)

		for _i in range(900):
			if not piece.is_standing():
				break

			platforms.begin_loads()
			platforms.add_load(highest, edge, 800.0, config.run_speed)
			platforms.step(TICK)

		_check(not piece.is_standing(), "%s: its highest piece comes off its pillar" % label,
			"%.3f rad" % piece.tilt())

		for _i in range(4):
			platforms.begin_loads()
			platforms.step(TICK)

		var orphans := 0

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if deck.is_bridge and (deck.supports.x == highest or deck.supports.y == highest) \
					and deck.is_standing():
				orphans += 1

		_check(orphans == 0, "%s: and a bridge resting on it goes too" % label,
			"%d left standing" % orphans)

		# And a shattering hit takes a bridge as it takes a platform.
		platforms.build(layout, game.physics)
		await _physics_frame()

		for i in range(platforms.count()):
			if platforms.deck_at(i).is_bridge:
				var outcome := platforms.report_impact(
					i, config.platform_shatter_impulse * 2.0, 1.0,
					platforms.deck_at(i).centre + Vector3(0.5, 0.0, 0.0))
				_check(outcome == ScPlatforms.Impact.SHATTERED and not platforms.deck_at(i).is_standing(),
					"%s: a bridge shatters from one big hit" % label)
				break

		# [b]Every piece can fall, not only the highest.[/b] The core mechanic is that the floor
		# goes, so a piece that held its pillar whatever stood on it would be a place to hide.
		# Each non-bridge piece gets its own fresh build and a runner on its edge.
		var stuck: Array[int] = []

		for i in range(platforms.count()):
			if platforms.deck_at(i).is_bridge:
				continue

			platforms.build(layout, game.physics)
			await _physics_frame()
			var each := platforms.deck_at(i)
			var rim := each.centre + Vector3(each.half, 0.0, 0.0)

			for _j in range(900):
				if not each.is_standing():
					break

				platforms.begin_loads()
				platforms.add_load(i, rim, 800.0, config.run_speed)
				platforms.step(TICK)

			if each.is_standing():
				stuck.append(i)

		_check(stuck.is_empty(), "%s: every piece comes off its pillar" % label,
			"stuck: %s" % str(stuck))

	await _dispose(game)
	_finished()


## [b]The one thing neither the suite nor the editor can see: what happens once this is a
## pack.[/b] Every finding in this section came from a delivered server rather than from
## here, and each is a check written afterwards so the next one is caught before the boot.
func _test_reach() -> void:
	_section("every jump a layout means is inside a running jump, and no other is")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms

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

	var too_far := PackedStringArray()
	var too_near := PackedStringArray()
	var unmet := PackedStringArray()
	var closest := PackedStringArray()
	var parked := PackedStringArray()

	for layout in ScLayouts.all(config):
		platforms.build(layout, game.physics)
		var cells := platforms.cells()
		var meant := 0
		var tightest := ""
		var tightest_margin := INF

		for pair: Vector3i in ScLayouts.pairs(cells):
			var declared := (layout.jumps & pair.z) != 0

			# Both ways: the dip is the LAUNCH platform's.
			for way: Vector2i in [Vector2i(pair.x, pair.y), Vector2i(pair.y, pair.x)]:
				var air := platforms.clear_air(way.x, way.y)
				var gap := air.y
				var label := "%s %s->%s" % [layout.id, _cell_name(platforms, way.x),
					_cell_name(platforms, way.y)]

				if declared:
					meant += 1
					var dip := _run_up_dip(platforms, config, way.x, way.y, air.x)
					# A landing a level higher is that much more to rise (stepped layouts).
					dip += maxf(
						platforms.deck_at(way.y).centre.y - platforms.deck_at(way.x).centre.y, 0.0)
					var reach := ScPlayer.jump_reach(config, dip)

					if gap > reach:
						too_far.append("%s %.2f m of air, %.2f m reach off a %.2f m dip" % [
							label, gap, reach, dip])
					elif reach - gap < tightest_margin:
						tightest_margin = reach - gap
						tightest = "%s %.2f m of %.2f" % [label, gap, reach]
				elif gap <= flat:
					# The most generous jump: flat, at a run; anything inside it is a crossing nobody meant.
					too_near.append("%s %.2f m of air, inside %.2f m" % [label, gap, flat])

		if layout.jumps != 0 and meant == 0:
			unmet.append(String(layout.id))

		if tightest != "":
			closest.append(tightest)

		if layout.with_chopper:
			for i in range(config.chopper_count):
				var pad := game.chopper_pad_on(layout, i)

				if platforms.index_at(pad.x, pad.z) < 0:
					parked.append("%s chopper %d" % [layout.id, i])

	_check(too_far.is_empty(), "every jump a layout means can be made from a run",
		"; ".join(too_far) if not too_far.is_empty() else ", ".join(closest))
	_check(too_near.is_empty(), "and every jump it does not mean cannot",
		"; ".join(too_near))
	_check(unmet.is_empty(), "and no layout means a kind of jump it has none of",
		", ".join(unmet))
	# The chopper is parked in the air and comes to rest on whatever is under it; over a
	# gap it comes to rest forty metres down, where nobody can get into it.
	_check(parked.is_empty(), "every parked chopper settles onto a platform",
		", ".join(parked))

	await _dispose(game)
	_finished()


## The flanks: a perch between every two pads, joined by catwalks that never touch the ring.
## Walked end to end at a run; `tools/shot.sh --view=flank` renders it.
func _test_the_flanks() -> void:
	_section("the flanks: a perch between every two pads, the long way round at a run")

	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()

		var config := game.config
		var middle := game.arena.showdown_centre()
		var walks := game.arena.flank_walks()
		var perches := 0
		var slabs := 0
		var thin := PackedStringArray()

		for child: Node in game.arena.find_children("*", "StaticBody3D", true, false):
			var kerb_sides: Dictionary = {}

			for piece: Node in child.get_children():
				if String(piece.name).begins_with("KerbHit"):
					kerb_sides[String(piece.name).trim_prefix("KerbHit").get_slice("_", 0)] = true

			if String(child.name).begins_with("Perch"):
				perches += 1
				if kerb_sides.size() != 4:
					thin.append("%s has %d" % [child.name, kerb_sides.size()])
			elif String(child.name).begins_with("Flank"):
				slabs += 1
				if kerb_sides.size() != 2:
					thin.append("%s has %d" % [child.name, kerb_sides.size()])

		_check(perches == sides and slabs == sides * 2 and walks.size() == sides * 2
				and thin.is_empty(),
			"with %d sides, a perch between every two pads and a catwalk to each" % sides,
			"%d perches, %d slabs of %d described%s" % [perches, slabs, walks.size(),
				"" if thin.is_empty() else ", " + ", ".join(thin)])

		# And open where each one arrives: a ray at shin height from the middle of the pad,
		# and of the perch, out along the flank to a metre past the edge meets no kerb. A
		# runner is thrown over a closed kerb since dot-player-controller 2e6d930 and the
		# drive below cannot see one (armed: it passed with the openings uncut), so this is
		# what holds them — a walker, or a body sliding, is still stopped by one.
		var space_here := game.arena.get_world_3d().direct_space_state
		var blocked := PackedStringArray()

		for index in range(walks.size()):
			var walk := walks[index]
			var d := walk["out"] as Vector2
			var pad_mid := game.arena.corner_point(int(walk["pad"]), sides)
			var perch_mid := game.arena.perch_point(int(walk["perch"]), sides)
			var shin := Vector3.UP * 0.15
			var past := Vector3(d.x, 0.0, d.y)
			var legs := [
				[pad_mid + shin, (walk["from"] as Vector3) + past + shin],
				[perch_mid + shin, (walk["to"] as Vector3) - past + shin],
			]

			for leg: Array in legs:
				var hit := space_here.intersect_ray(
					PhysicsRayQueryParameters3D.create(leg[0] as Vector3, leg[1] as Vector3))

				if not hit.is_empty():
					blocked.append("Flank%d at %s" % [index, (hit["collider"] as Node).name])

		_check(blocked.is_empty(),
			"and the kerb is open wherever a flank arrives, at both ends",
			"%d ends clear%s" % [walks.size() * 2 - blocked.size(),
				"" if blocked.is_empty() else ": " + ", ".join(blocked)])

		# The long way round never touches the ring: every flank's centre line stays further
		# from the ring's middle than the ring's own corners plus half a catwalk.
		var ring_corner := config.corner_size * 0.85 * sqrt(2.0)
		var nearest := INF

		for walk: Dictionary in walks:
			var a := walk["from"] as Vector3
			var b := walk["to"] as Vector3
			var closest := Geometry3D.get_closest_point_to_segment(middle, a, b)
			nearest = minf(nearest, Vector2(closest.x - middle.x, closest.z - middle.z).length())

		_check(nearest > ring_corner + ScArena.CATWALK_WIDTH * 0.5 + 2.0,
			"and no flank comes near the ring",
			"nearest %.1f m from its middle, its corners at %.1f" % [nearest, ring_corner])

		# Driven: from pad 0, at a run, through perch 0 and onto pad 1's middle. Steered at
		# each waypoint's centre, running the whole way, which is what the kerb openings and
		# the dropped slab have to let through without a stall.
		var start := game.arena.corner_point(0, sides)
		var perch := game.arena.perch_point(0, sides)
		var goal := game.arena.corner_point(1, sides)
		var route: Array[Vector3] = [perch, goal]
		var length := Vector2(perch.x - start.x, perch.z - start.z).length() \
			+ Vector2(goal.x - perch.x, goal.z - perch.z).length()
		var runner := game.add_player(&"flanker", "Flanker", 1)
		runner.place_at(start + Vector3.UP * 0.2, game.arena.showdown_yaw(0, sides))
		await _step(game, 20)
		_track(runner)

		var next := 0
		var ticks := 0
		var lowest := INF

		for _i in range(int(45.0 * TICK_RATE)):
			var at := runner.controller.state.position
			var toward := Vector3(route[next].x - at.x, 0.0, route[next].z - at.z)

			if toward.length() < 1.0:
				next += 1
				if next >= route.size():
					break
				toward = Vector3(route[next].x - at.x, 0.0, route[next].z - at.z)

			var command := DotFpsCommand.new()
			command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
			command.move = Vector2(0.0, 1.0)
			runner.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()
			ticks += 1
			lowest = minf(lowest, runner.controller.state.position.y)

		var covered := _covered
		var top := _top_speed
		_track(null)
		var max_speed := ScPlayer.tunables_for(config, null).max_speed
		var seconds := float(ticks) / float(TICK_RATE)
		var ended := runner.controller.state.position

		_check(next >= route.size() and runner.is_alive() and lowest > middle.y - 0.5,
			"a runner goes pad 0, perch 0, pad 1 without a fall",
			"reached %d of %d waypoints, lowest %.2f m against %.2f, ended %.1f m from pad 1" % [
				next, route.size(), lowest, middle.y,
				Vector2(ended.x - goal.x, ended.z - goal.z).length()])
		# At a run the whole way: the route over the time is the pace, and a stall on a kerb
		# or a seam at either end of a slab is a second or more lost.
		_check(covered >= length * 0.97 and top >= max_speed * 0.95
				and seconds <= length / max_speed + 1.5,
			"and at a run: the route in its running time",
			"%.1f m of %.1f in %.2f s (%.2f s at %.2f m/s), top %.2f" % [
				covered, length, seconds, length / max_speed, max_speed, top])

		# With two sides a perch is ninety degrees off both blocks, which is the point of it:
		# somebody crouched behind a ring block, hidden from the pad it faces, is in plain
		# sight from either perch. With three the angle is 60 and the block still covers.
		if sides == 2:
			var space := game.arena.get_world_3d().direct_space_state
			var cover := game.arena.ring_cover()
			var seen := 0
			var asked := 0

			for p in range(sides):
				var eye := game.arena.perch_point(p, sides) + Vector3.UP * 1.6

				for block in cover:
					var inward := middle - block.origin
					inward.y = 0.0
					inward = inward.normalized()
					var behind := block.origin + inward * (ScArena.RING_COVER_SIZE.z * 0.5 + 0.4)
					var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
					asked += 1

					if space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched)).is_empty():
						seen += 1

			_check(seen == asked,
				"and from either perch, somebody crouched behind either ring block is in sight",
				"%d of %d lines clear" % [seen, asked])

		await _dispose(game)

	_finished()


## The dais: a 4 m block on the ring's middle, jumped onto, hiding a crouched player from pads and perches.
## `tools/shot.sh --view=dais` renders it.
func _test_the_dais() -> void:
	_section("the ring's dais: one jump up, cover that turns, and the high ground")

	var sides := 2
	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = sides
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	await _physics_frame()

	var config := game.config
	var middle := game.arena.showdown_centre()
	var half := ScArena.DAIS_SIZE.x * 0.5
	var top := middle.y + ScArena.DAIS_SIZE.y

	_check(game.arena.has_node(^"Showdown/RingDais")
			and absf(game.arena.dais().origin.y + ScArena.DAIS_SIZE.y * 0.5 - top) < 0.001
			and ScArena.DAIS_SIZE.y > ScPlayer.tunables_for(config, null).step_height
			and ScArena.DAIS_SIZE.y < config.jump_height,
		"the dais stands on the ring's middle, over a step and under a jump",
		"built %s, %.2f m against step %.2f and jump %.2f" % [
			game.arena.has_node(^"Showdown/RingDais"), ScArena.DAIS_SIZE.y,
			ScPlayer.tunables_for(config, null).step_height, config.jump_height])

	# --- Driven: from pad 0 down its catwalk, across the ring, one jump onto the top. ---
	var start := game.arena.corner_point(0, sides)
	var yaw := game.arena.showdown_yaw(0, sides)
	var runner := game.add_player(&"dais_runner", "Dais Runner", 1)
	runner.place_at(start + Vector3.UP * 0.2, yaw)
	await _step(game, 8)

	# On the catwalk's line to 12 m out, round the pad's own block (it stands on that line
	# 7.2 m out), then at the middle: the way a survivor runs it.
	var out := Vector3(start.x - middle.x, 0.0, start.z - middle.z).normalized()
	var across := Vector3(-out.z, 0.0, out.x)
	var route_points: Array[Vector3] = [
		middle + out * 12.0, middle + out * 4.5 + across * 3.0, middle,
	]
	var from := runner.controller.state.position
	var route := 0.0
	var last := from

	for point in route_points:
		route += Vector2(point.x - last.x, point.z - last.z).length()
		last = point

	route -= half

	_track(runner)
	var ticks := 0
	var next := 0
	var jumped := false
	var on_top := false
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for _i in range(int(14.0 * TICK_RATE)):
		var at := runner.controller.state.position
		var target := route_points[next]
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if next < route_points.size() - 1 and toward.length() < 1.0:
			next += 1
			target = route_points[next]
			toward = Vector3(target.x - at.x, 0.0, target.z - at.z)

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)

		# Off the ring 1.2 m short of the dais' edge, the lead a running jump wants.
		if next == route_points.size() - 1 and not jumped and toward.length() < half + 1.2:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			jumped = true

		runner.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()
		ticks += 1

		var now := runner.controller.state.position

		if jumped and runner.controller.state.mode == DotFpsState.Mode.GROUND \
				and now.y > top - 0.1 and absf(now.x - middle.x) < half \
				and absf(now.z - middle.z) < half:
			on_top = true
			break

	var covered := _covered
	var fastest := _top_speed
	_track(null)
	var seconds := float(ticks) / float(TICK_RATE)
	var ended := runner.controller.state.position
	var pace := covered / seconds if seconds > 0.0 else 0.0

	print("  ..    dais: pad 0 to the dais' top %.1f m (route %.1f) in %.2f s, %.2f m/s, top %.2f against run %.2f" % [
		covered, route, seconds, pace, fastest, max_speed])

	_check(on_top and runner.is_alive(),
		"a runner goes from pad 0 down the catwalk and jumps onto the dais",
		"ended at %.2f m over the ring, %.1f m from its middle" % [
			ended.y - middle.y, Vector2(ended.x - middle.x, ended.z - middle.z).length()])
	_check(on_top and fastest >= max_speed * 0.95 and seconds <= route / max_speed + 1.0,
		"and at a run: the route in its running time",
		"%.1f m in %.2f s (%.2f s at %.2f m/s), top %.2f" % [
			route, seconds, route / max_speed, max_speed, fastest])

	# --- Cover that turns, and the high ground. -----------------------------------------
	#
	# From every pad and every perch: somebody crouched against the dais' far side is out
	# of sight, and somebody standing there is not. A ring block covers from one pad; the
	# dais covers from whichever one a survivor puts it between.
	var space := game.arena.get_world_3d().direct_space_state
	var hidden := 0
	var under := 0
	var over := 0
	var lookers: Array[Vector3] = []

	for index in range(sides):
		lookers.append(game.arena.corner_point(index, sides))
		lookers.append(game.arena.perch_point(index, sides))

	for looker in lookers:
		var eye := looker + Vector3.UP * 1.6
		var away := Vector3(middle.x - looker.x, 0.0, middle.z - looker.z).normalized()
		var behind := middle + away * (half + 0.4)
		var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
		var standing := Vector3(behind.x, middle.y + 1.6, behind.z)
		var low := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched))
		var high := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, standing))

		if not low.is_empty():
			hidden += 1

			if String((low["collider"] as Node).name) == "RingDais":
				under += 1
		if high.is_empty():
			over += 1

	print("  ..    dais: crouched against the far side, %d of %d lines blocked, %d by the dais itself (the perches'; a pad's own block is on its line first)" % [
		hidden, lookers.size(), under])

	_check(hidden == lookers.size() and under >= sides and over == lookers.size(),
		"and crouched against its far side a survivor is hidden from every pad and perch, standing is not",
		"%d of %d hidden (%d by the dais), %d of %d seen standing" % [
			hidden, lookers.size(), under, over, lookers.size()])

	var dais_eye := Vector3(middle.x, top + 1.6, middle.z)
	var seen := 0
	var asked := 0

	for index in range(sides):
		for target: Vector3 in [game.arena.corner_point(index, sides), game.arena.perch_point(index, sides)]:
			asked += 1

			if space.intersect_ray(PhysicsRayQueryParameters3D.create(dais_eye, target + Vector3.UP * 1.6)).is_empty():
				seen += 1

	_check(seen == asked,
		"and from its top every pad and every perch is in sight, over the blocks",
		"%d of %d lines clear" % [seen, asked])

	await _dispose(game)
	_finished()


func _test_the_showdown_walk() -> void:
	_section("a survivor can walk from their corner onto the ring")

	# Two sides, where every catwalk meets its edges square on, and three, where two of
	# them meet the ring at an angle and a gap cut along the edge has to be wider.
	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)

		var corner := sides - 1
		var start := game.arena.corner_point(corner, sides)
		var middle := game.arena.showdown_centre()
		var ring := game.config.corner_size * 0.85
		var walker := game.add_player(&"walker", "Walker", 1)
		var yaw := game.arena.showdown_yaw(corner, sides)
		walker.place_at(start + Vector3.UP * 0.2, yaw)

		var arrived := false
		var lowest := INF

		# Running, which is the case the kerb was stopping. Walking is stopped the same way.
		for _i in range(int(8.0 * TICK_RATE)):
			var command := DotFpsCommand.new()
			command.yaw = yaw
			command.move = Vector2(0.0, 1.0)
			walker.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()

			var at := walker.controller.state.position
			lowest = minf(lowest, at.y)

			if Vector2(at.x - middle.x, at.z - middle.z).length() < ring - 2.0:
				arrived = true
				break

		var ended := walker.controller.state.position
		_check(arrived and lowest > middle.y - 0.5,
			"with %d sides, from corner %d onto the ring" % [sides, corner],
			"%.1f m from the middle, lowest %.2f m against %.2f" % [
				Vector2(ended.x - middle.x, ended.z - middle.z).length(), lowest, middle.y])

		await _dispose(game)

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
	_finished()


## A catwalk stops at the ring's edge and its pad's, at neither short of it.
## Read off the built colliders and marched edges, so a description agreeing only with itself fails.
## Two and four sides meet square on; three meets two of them at an angle.
func _test_catwalks_meet_their_edges() -> void:
	_section("a catwalk meets the ring and its pad, and runs into neither")

	for sides: int in [2, 3, 4]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()
		var middle := game.arena.showdown_centre()
		var ring := game.arena.ring_half()
		var pad_half := game.config.corner_size * 0.5
		var space := game.arena.get_world_3d().direct_space_state
		var in_ring := PackedStringArray()
		var in_pad := PackedStringArray()
		var air := PackedStringArray()
		for index in range(sides):
			var body := game.arena.get_node(NodePath("Showdown/Catwalk%d" % index)) as StaticBody3D
			var corner := game.arena.corner_point(index, sides)
			var inside := func(p: Vector3, centre: Vector3, half: float) -> bool:
				return absf(p.x - centre.x) < half - 0.01 and absf(p.z - centre.z) < half - 0.01

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

			for p in points:
				if inside.call(p, middle, ring):
					in_ring.append("Catwalk%d at %.2f, %.2f" % [index, p.x - middle.x, p.z - middle.z])
					break

			for p in points:
				if inside.call(p, corner, pad_half):
					in_pad.append("Catwalk%d at %.2f, %.2f" % [index, p.x - corner.x, p.z - corner.z])
					break

			# Across the whole width, 5 cm past each edge the ground is this catwalk (edges walked out in cm).
			var out := Vector2(corner.x - middle.x, corner.z - middle.z).normalized()
			var across := Vector2(out.y, -out.x)
			var reach := Vector2(corner.x - middle.x, corner.z - middle.z).length()

			for step in range(9):
				var w := lerpf(-ScArena.CATWALK_WIDTH * 0.5 + 0.05, ScArena.CATWALK_WIDTH * 0.5 - 0.05, step / 8.0)
				var s := 0.0

				while inside.call(_on_line(middle, out, across, s, w), middle, ring + 0.01):
					s += 0.01

				var e := reach

				while inside.call(_on_line(middle, out, across, e, w), corner, pad_half + 0.01):
					e -= 0.01

				for at: float in [s + 0.05, e - 0.05]:
					var p := _on_line(middle, out, across, at, w)
					var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
						p + Vector3.UP * 1.0, p + Vector3.DOWN * 1.0))

					if hit.is_empty() or hit["collider"] != body:
						air.append("Catwalk%d at %.1f m across, %.2f m out" % [index, w, at])
						break

		_check(in_ring.is_empty(),
			"with %d sides, no catwalk or its kerb runs into the ring" % sides, ", ".join(in_ring))
		_check(in_pad.is_empty(),
			"with %d sides, nor into its own pad" % sides, ", ".join(in_pad))
		_check(air.is_empty(),
			"with %d sides, and every catwalk meets both edges with no air at the join" % sides,
			", ".join(air))

		await _dispose(game)

	_finished()


## The Spine: a bridge must not lean more than a platform edge (see [method ScPlatforms._rest_bridges]).
func _test_the_spine() -> void:
	_section("The Spine's walkways are the steady ground")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.layout_ids = PackedStringArray(["spine"])
	)
	var platforms := game.platforms

	var bridges := 0
	var rested := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge:
			bridges += 1
			rested += 1 if deck.is_rested() else 0

	_check(bridges >= 4 and rested == bridges,
		"every bridge on The Spine rests on the two platforms it joins",
		"%d of %d" % [rested, bridges])

	# The model alone, on a field of its own: one runner's weight at a bridge's end against
	# the same at a platform's edge, each held until the spring has found its angle.
	var bridge_end := _spine_lean(true)
	var platform_edge := _spine_lean(false)
	_check(bridge_end < platform_edge * 0.5,
		"a runner at a bridge's end tilts it less than half what a platform's edge does",
		"%.1f deg against %.1f" % [rad_to_deg(bridge_end), rad_to_deg(platform_edge)])

	# Driven: running, not walking, from the middle of (0,0) over the bridge to (0,1).
	var from := _deck_at_cell(platforms, 0, 0)
	var to := _deck_at_cell(platforms, 0, 1)
	var bridge := -1

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge and deck.column == 0 and deck.row == 0:
			bridge = i

	var runner := game.add_player(&"runner", "Runner", 1)
	game.add_player(&"other", "Other", 2)
	runner.place_at(platforms.deck_at(from).centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)

	var target := platforms.deck_at(to).centre
	var span := platforms.deck_at(bridge)
	var worst_bridge := 0.0
	var worst_step := 0.0
	var lowest := INF
	var crossed_on := false
	var arrived := false

	for _i in range(int(6.0 * TICK_RATE)):
		var at := runner.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if toward.length() < 1.0:
			arrived = true
			break

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		runner.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

		lowest = minf(lowest, runner.controller.state.position.y)
		worst_bridge = maxf(worst_bridge, span.tilt())
		crossed_on = crossed_on or runner.standing_on == bridge

		# Where the bridge meets each lip there is no step, whatever the platforms are doing.
		var x := span.centre.x
		worst_step = maxf(worst_step, absf(
			platforms.surface_y(bridge, x, span.lips.x) - platforms.surface_y(from, x, span.lips.x)))
		worst_step = maxf(worst_step, absf(
			platforms.surface_y(bridge, x, span.lips.y) - platforms.surface_y(to, x, span.lips.y)))

	await _step(game, 10)

	_check(crossed_on and arrived and runner.standing_on == to and runner.is_alive(),
		"a runner crosses a bridge from one row to the other",
		"on %d, alive %s, lowest %.2f m against a deck at %.2f" % [
			runner.standing_on, runner.is_alive(), lowest, game.config.deck_height])
	# Not the runner's height: the lip they leave from dips most of a metre under a runner,
	# which is the platform doing its job. The bridge is what is being asked about.
	_check(worst_bridge < deg_to_rad(4.0),
		"and the bridge under them never tilts past four degrees",
		"%.1f deg" % rad_to_deg(worst_bridge))
	_check(worst_step < 0.02, "and meets both lips with no step",
		"%.3f m at worst" % worst_step)

	# And it goes with either platform it rests on.
	var why: Array[StringName] = []
	platforms.collapsed.connect(func(index: int, reason: StringName) -> void:
		if index == bridge:
			why.append(reason))
	var _fell := platforms.collapse(from, ScPlatforms.WHY_SHATTERED)
	await _step(game, 2)
	_check(not span.is_standing() and why.has(ScPlatforms.WHY_UNSUPPORTED),
		"and falls when a platform it rests on does", str(why))

	await _dispose(game)
	_finished()


## Two Islands' blurb: "Two islands and a lot of air between them. Nobody is crossing." Until
## 2026-09-27 it was four: the rows were 13.5 m apart with no bridge, so each end of each row
## was two platforms nobody could leave, and the two sides started on two of them.
func _test_two_islands() -> void:
	_section("Two Islands is two islands, crossed every way, and nobody crosses between them")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["islands"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"islands",
		"the round is laid out as Two Islands",
		String(game.layout.id) if game.layout != null else "none")

	# What a player can get to, off the built field: bridges, and the jumps the layout means
	# (which the reach section holds to a running jump, both ways).
	var island := ScLayouts.islands(platforms.cells(), game.layout.jumps)
	var sizes: Dictionary = {}

	for i in range(platforms.count()):
		sizes[island[i]] = int(sizes.get(island[i], 0)) + 1

	_check(sizes.size() == 2 and sizes.values().all(func(n: int) -> bool: return n == 4),
		"the field is two islands of four platforms",
		"%d islands: %s" % [sizes.size(), str(sizes.values())])

	# Two sides, one to an island. The field is in row order, and the old spread put both
	# at the two ends of the first column.
	var runner := game.add_player(&"runner", "Runner", 1)
	var other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, 20)
	var mine := platforms.index_at(runner.controller.state.position.x, runner.controller.state.position.z)
	var theirs := platforms.index_at(other.controller.state.position.x, other.controller.state.position.z)
	_check(mine >= 0 and theirs >= 0 and island[mine] != island[theirs],
		"two sides start on the two islands, one each",
		"%s and %s" % [
			_cell_name(platforms, mine) if mine >= 0 else "nowhere",
			_cell_name(platforms, theirs) if theirs >= 0 else "nowhere"])

	# Round the left island on every kind of jump it means: along a row, across the rows,
	# back along, and a diagonal. Each from the middle of a platform leaning under the
	# runner, at the lip, as a person would.
	var cells := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(1, 0)]
	var route: Array[int] = []

	for cell: Vector2i in cells:
		route.append(_deck_at_cell(platforms, cell.x, cell.y))

	var length := 0.0

	for leg in range(route.size() - 1):
		var a := platforms.deck_at(route[leg]).centre
		var b := platforms.deck_at(route[leg + 1]).centre
		length += Vector2(b.x - a.x, b.z - a.z).length()

	runner.place_at(platforms.deck_at(route[0]).centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)
	_track(runner)

	var made := PackedStringArray()

	for leg in range(route.size() - 1):
		await _walk_to(game, runner, platforms.deck_at(route[leg]).centre)
		var landed := await _jump_across(game, runner, route[leg], route[leg + 1])
		made.append("%s%s" % [_cell_name(platforms, route[leg + 1]), "" if landed else " MISSED"])

		if not landed:
			break

	await _walk_to(game, runner, platforms.deck_at(route[route.size() - 1]).centre)
	var covered := _covered
	var top := _top_speed
	_track(null)
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	_check(made.size() == route.size() - 1 and not ", ".join(made).contains("MISSED"),
		"a runner goes round an island along, across, along and on a diagonal",
		", ".join(made))
	# [b]At a run, over the whole route[/b] ([bot-drive-1]): a bot that crawled, or that was
	# placed rather than driven, passes the landing checks and fails this one.
	_check(covered >= length * 0.95 and top >= max_speed * 0.95,
		"and covers the route at a run",
		"%.1f m covered of a %.1f m route, top speed %.2f of %.2f m/s" % [
			covered, length, top, max_speed])
	_check(runner.is_alive() and runner.standing_on == route[route.size() - 1]
			and platforms.standing_count() == platforms.count(),
		"and ends on the island, with all of it still up",
		"on %d, alive %s, %d of %d up" % [runner.standing_on, runner.is_alive(),
			platforms.standing_count(), platforms.count()])

	# And the other island is not reached: straight at it from the inner edge of this one,
	# running, is a fall. That is "nobody is crossing".
	var across := _deck_at_cell(platforms, 3, 0)
	var crossed := await _jump_across(game, runner, route[route.size() - 1], across)
	_check(not crossed and runner.controller.state.position.y < config.deck_height - 3.0,
		"and running at the other island is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## Hollow Centre: with only the middle column gone each half is a U round the hole.
## Runs a side round its U, then at the other U, which is a fall.
func _test_hollow_centre() -> void:
	_section("Hollow Centre is two U's round the hole, and the hole is not crossed")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["hollow"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"hollow",
		"the round is laid out as Hollow Centre",
		String(game.layout.id) if game.layout != null else "none")

	var decks := 0
	var spans := 0
	var middle := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge:
			spans += 1
		else:
			decks += 1

		if deck.column == config.columns / 2:
			middle += 1

	var island := ScLayouts.islands(platforms.cells(), game.layout.jumps)
	var sizes: Dictionary = {}

	for i in range(platforms.count()):
		sizes[island[i]] = int(sizes.get(island[i], 0)) + 1

	_check(decks == 8 and spans == 2 and middle == 0
			and sizes.size() == 2 and sizes.values().all(func(n: int) -> bool: return n == 5),
		"only the middle column is gone: two halves of four platforms and a bridge",
		"%d platforms, %d bridges, %d in the middle column, %d islands: %s" % [
			decks, spans, middle, sizes.size(), str(sizes.values())])

	var runner := game.add_player(&"runner", "Runner", 1)
	var other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, 20)
	var mine := platforms.index_at(runner.controller.state.position.x, runner.controller.state.position.z)
	var theirs := platforms.index_at(other.controller.state.position.x, other.controller.state.position.z)
	_check(mine >= 0 and theirs >= 0 and island[mine] != island[theirs],
		"two sides start on the two halves, one each",
		"%s and %s" % [
			_cell_name(platforms, mine) if mine >= 0 else "nowhere",
			_cell_name(platforms, theirs) if theirs >= 0 else "nowhere"])

	# Round the left U: off the inner platform onto the outer one, across the outer bridge
	# at a run, and out to the other row's inner platform. Every jump from the middle of a
	# platform leaning under the runner, at the lip.
	var inner_near := _deck_at_cell(platforms, 1, 0)
	var outer_near := _deck_at_cell(platforms, 0, 0)
	var outer_far := _deck_at_cell(platforms, 0, 1)
	var inner_far := _deck_at_cell(platforms, 1, 1)
	var made := PackedStringArray()
	var length := 0.0

	if inner_near < 0 or outer_near < 0 or outer_far < 0 or inner_far < 0:
		made.append("no U: (1,0) %d, (0,0) %d, (0,1) %d, (1,1) %d MISSED" % [
			inner_near, outer_near, outer_far, inner_far])
	else:
		var stops := [inner_near, outer_near, outer_far, inner_far]

		for leg in range(stops.size() - 1):
			var a := platforms.deck_at(stops[leg]).centre
			var b := platforms.deck_at(stops[leg + 1]).centre
			length += Vector2(b.x - a.x, b.z - a.z).length()

		runner.place_at(platforms.deck_at(inner_near).centre + Vector3.UP * 0.2, 0.0)
		await _step(game, 20)
		_track(runner)

		await _walk_to(game, runner, platforms.deck_at(inner_near).centre)
		var landed := await _jump_across(game, runner, inner_near, outer_near)
		made.append("%s%s" % [_cell_name(platforms, outer_near), "" if landed else " MISSED"])

		if landed:
			# Over the bridge on foot, at a run: it is walked, not jumped.
			await _run_to(game, runner, platforms.deck_at(outer_far).centre, 0.3)
			await _walk_to(game, runner, platforms.deck_at(outer_far).centre)
			var crossed := runner.is_alive() and runner.standing_on == outer_far
			made.append("%s over the bridge%s" % [_cell_name(platforms, outer_far),
				"" if crossed else " MISSED"])

			if crossed:
				await _walk_to(game, runner, platforms.deck_at(outer_far).centre)
				landed = await _jump_across(game, runner, outer_far, inner_far)
				made.append("%s%s" % [_cell_name(platforms, inner_far), "" if landed else " MISSED"])

				if landed:
					await _walk_to(game, runner, platforms.deck_at(inner_far).centre)

	var covered := _covered
	var top := _top_speed
	_track(null)
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	_check(made.size() == 3 and not ", ".join(made).contains("MISSED"),
		"a runner goes round a U: a jump along a row, the outer bridge, a jump back in",
		", ".join(made))
	_check(length > 0.0 and covered >= length * 0.95 and top >= max_speed * 0.95,
		"and covers the route at a run",
		"%.1f m covered of a %.1f m route, top speed %.2f of %.2f m/s" % [
			covered, length, top, max_speed])
	_check(inner_far >= 0 and runner.is_alive() and runner.standing_on == inner_far
			and platforms.standing_count() == platforms.count(),
		"and ends on the far inner platform, with all of it still up",
		"on %d, alive %s, %d of %d up" % [runner.standing_on, runner.is_alive(),
			platforms.standing_count(), platforms.count()])

	# And the other U is not reached: straight across the hole from the inner platform,
	# running, is a fall.
	var across := _deck_at_cell(platforms, config.columns - 2, 1)
	var fell := false

	if inner_far >= 0 and across >= 0 and runner.standing_on == inner_far:
		var reached := await _jump_across(game, runner, inner_far, across)
		fell = not reached and runner.controller.state.position.y < config.deck_height - 3.0

	_check(fell, "and running across the hole at the other half is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## Broadside: the chopper is parked on the middle column; runs both sides to it at the layout's own
## 3.4 m jumps (the reach section only measured them) and puts each of them in it.
func _test_broadside() -> void:
	_section("Broadside's chopper is over the middle, and either side can run to it and take it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["broadside"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"broadside",
		"the round is laid out as Broadside",
		String(game.layout.id) if game.layout != null else "none")

	var first := game.add_player(&"first", "First", 1)
	var second := game.add_player(&"second", "Second", 2)
	game.start()
	# Long enough for the chopper to drop off its pad and come to rest.
	await _step(game, 96)

	var copter: DotVehicleInstance = null if game._copter_ids.is_empty() \
		else game.vehicles.get_vehicle(game._copter_ids[0])
	var parked := copter.body().global_position if copter != null else Vector3.ZERO
	var middle := _deck_at_cell(platforms, config.columns / 2, 0)
	var under := platforms.index_at(parked.x, parked.z) if copter != null else -1

	_check(copter != null and under == middle and absf(parked.x) < 0.5
			and parked.y < config.deck_height + 2.0,
		"the chopper comes to rest on the middle column, over the field's centre line",
		"on %s at x %.2f, %.2f m over the decks" % [
			_cell_name(platforms, under) if under >= 0 else "nothing", parked.x,
			parked.y - config.deck_height])

	# Where the two sides were dealt, which the routes below start from.
	var home := _deck_at_cell(platforms, 0, 0)
	var across := _deck_at_cell(platforms, 1, 1)
	var first_on := platforms.index_at(first.controller.state.position.x,
		first.controller.state.position.z)
	var second_on := platforms.index_at(second.controller.state.position.x,
		second.controller.state.position.z)
	_check(first_on == home and second_on == across,
		"the two sides start at (0,0) and (1,1), a row apart",
		"%s and %s" % [
			_cell_name(platforms, first_on) if first_on >= 0 else "nowhere",
			_cell_name(platforms, second_on) if second_on >= 0 else "nowhere"])

	# The first side: two jumps along its own row. The second: over column 1's bridge to the
	# first row, and one jump. Each then goes to the machine and gets in, and out again.
	var near := _deck_at_cell(platforms, 1, 0)
	var runs := [
		[first, [[home, near, false], [near, middle, false]]],
		[second, [[across, near, true], [near, middle, false]]],
	]
	var metres: Array[float] = []
	var fastest := INF
	var took := PackedStringArray()
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for run: Array in runs:
		var runner: ScPlayer = run[0]
		var made := PackedStringArray()
		_track(runner)

		for leg: Array in run[1]:
			var landed := false

			if leg[2]:
				landed = await _run_to(game, runner, platforms.deck_at(leg[1]).centre, 1.0)
				landed = landed and runner.standing_on == leg[1]
			else:
				await _walk_to(game, runner, platforms.deck_at(leg[0]).centre)
				landed = await _jump_across(game, runner, leg[0], leg[1])

			made.append("%s%s" % [_cell_name(platforms, leg[1]), "" if landed else " MISSED"])

			if not landed:
				break

		# Guarded, because a runner who fell ended the round and took the machine with it.
		if copter != null and copter.body() != null:
			await _run_to(game, runner, copter.body().global_position, 3.5)

		var boarded := game.try_board(runner.player_id)
		await _step(game, 4)
		metres.append(_covered)
		fastest = minf(fastest, _top_speed)
		_track(null)
		took.append("%s: %s, %.1f m, %s" % [runner.player_id, ", ".join(made), metres.back(),
			"in" if boarded.ok and runner.riding else "not in"])

		# Out again, so the other side finds it empty.
		if runner.riding:
			var _out := game.try_board(runner.player_id)
			await _step(game, 20)

		_check(boarded.ok and not ", ".join(made).contains("MISSED"),
			"%s runs to the chopper and gets in" % runner.player_id, took[took.size() - 1])

	_check(fastest >= max_speed * 0.95, "both at a run, over the 3.4 m jumps",
		"slower top speed %.2f of %.2f m/s" % [fastest, max_speed])
	# Over the middle is what makes it contested: neither side has it on the doorstep.
	var ratio: float = float(metres.max()) / maxf(float(metres.min()), 0.01)
	_check(metres.size() == 2 and ratio <= 1.5,
		"and neither side is much nearer it than the other",
		"%.1f m against %.1f m, %.2f to one" % [metres[0], metres[1], ratio])

	var now := copter.body().global_position if copter != null and copter.body() != null \
		else Vector3(INF, INF, INF)
	_check(now.distance_to(parked) < 0.5 and platforms.standing_count() == platforms.count()
			and first.is_alive() and second.is_alive(),
		"and it is where it was after both have landed beside it, with everybody up",
		"moved %.2f m, %d of %d platforms up, alive %s and %s" % [now.distance_to(parked),
			platforms.standing_count(), platforms.count(), first.is_alive(), second.is_alive()])

	await _dispose(game)
	_finished()


func _test_the_airfield() -> void:
	_section("the Airfield's pad is the far bridge, and both sides run their own row to it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["airfield"])
	)
	var platforms := game.platforms
	var config := game.config
	var last := config.columns - 1

	_check(game.layout != null and game.layout.id == &"airfield",
		"the round is laid out as the Airfield",
		String(game.layout.id) if game.layout != null else "none")

	var first := game.add_player(&"first", "First", 1)
	var second := game.add_player(&"second", "Second", 2)
	game.start()
	# Long enough for the chopper to drop off its pad and come to rest.
	await _step(game, 96)

	var copter: DotVehicleInstance = null if game._copter_ids.is_empty() \
		else game.vehicles.get_vehicle(game._copter_ids[0])
	var parked := copter.body().global_position if copter != null else Vector3.ZERO
	var pad := -1

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge and deck.column == last and deck.row == 0:
			pad = i

	var under := platforms.index_at(parked.x, parked.z) if copter != null else -1
	var pad_centre := platforms.deck_at(pad).centre if pad >= 0 else Vector3(INF, 0.0, INF)

	_check(copter != null and pad >= 0 and under == pad
			and Vector2(parked.x - pad_centre.x, parked.z - pad_centre.z).length() < 1.0
			and parked.y < config.deck_height + 2.5,
		"the chopper comes to rest on the middle of the last column's bridge",
		"on %s, %.2f m off its middle, %.2f m over the decks" % [
			_cell_name(platforms, under) if under >= 0 else "nothing",
			Vector2(parked.x - pad_centre.x, parked.z - pad_centre.z).length(),
			parked.y - config.deck_height])

	var home := _deck_at_cell(platforms, 0, 0)
	var across := _deck_at_cell(platforms, 1, 1)
	var first_on := platforms.index_at(first.controller.state.position.x,
		first.controller.state.position.z)
	var second_on := platforms.index_at(second.controller.state.position.x,
		second.controller.state.position.z)
	_check(first_on == home and second_on == across,
		"the two sides start at (0,0) and (1,1), a row apart",
		"%s and %s" % [
			_cell_name(platforms, first_on) if first_on >= 0 else "nowhere",
			_cell_name(platforms, second_on) if second_on >= 0 else "nowhere"])

	# Each side along its own row to the platform the pad rests on, jump by jump, then onto
	# the bridge and into the machine, and out again for the other.
	var routes := []

	for run: Array in [[first, 0, 0], [second, 1, 1]]:
		var legs := []

		for column in range(int(run[1]), last):
			legs.append([_deck_at_cell(platforms, column, run[2]),
				_deck_at_cell(platforms, column + 1, run[2])])

		routes.append([run[0], legs])

	var metres: Array[float] = []
	var jumps: Array[int] = []
	var fastest := INF
	var took := PackedStringArray()
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for route: Array in routes:
		var runner: ScPlayer = route[0]
		var made := PackedStringArray()
		_track(runner)

		for leg: Array in route[1]:
			await _walk_to(game, runner, platforms.deck_at(leg[0]).centre)
			var landed := await _jump_across(game, runner, leg[0], leg[1])
			made.append("%s%s" % [_cell_name(platforms, leg[1]), "" if landed else " MISSED"])

			if not landed:
				break

		var on_pad := false

		if copter != null and copter.body() != null and not ", ".join(made).contains("MISSED"):
			await _run_to(game, runner, copter.body().global_position, 3.5)
			on_pad = runner.standing_on == pad

		var boarded := game.try_board(runner.player_id)
		await _step(game, 4)
		metres.append(_covered)
		jumps.append(made.size())
		fastest = minf(fastest, _top_speed)
		_track(null)
		took.append("%s: %s, %.1f m, %s" % [runner.player_id, ", ".join(made), metres.back(),
			"in" if boarded.ok and runner.riding else "not in"])

		if runner.riding:
			var _out := game.try_board(runner.player_id)
			await _step(game, 20)

		_check(boarded.ok and on_pad and not ", ".join(made).contains("MISSED"),
			"%s runs its own row onto the bridge and gets in" % runner.player_id,
			took[took.size() - 1])

	_check(jumps.size() == 2 and jumps[0] == last and jumps[1] == last - 1 and fastest >= max_speed * 0.95,
		"four jumps and three, at a run",
		"%s jumps, slower top speed %.2f of %.2f m/s" % [str(jumps), fastest, max_speed])
	# The far bridge is what makes it contested: each side has a row of its own to it.
	var ratio: float = float(metres.max()) / maxf(float(metres.min()), 0.01)
	_check(metres.size() == 2 and ratio <= 1.5,
		"and neither side is much nearer it than the other",
		"%.1f m against %.1f m, %.2f to one" % [metres[0], metres[1], ratio])

	var now := copter.body().global_position if copter != null and copter.body() != null \
		else Vector3(INF, INF, INF)
	_check(now.distance_to(parked) < 0.5 and platforms.standing_count() == platforms.count()
			and first.is_alive() and second.is_alive(),
		"and it is where it was after both have boarded it, with everybody up",
		"moved %.2f m, %d of %d platforms up, alive %s and %s" % [now.distance_to(parked),
			platforms.standing_count(), platforms.count(), first.is_alive(), second.is_alive()])

	# The pad goes with the platform it rests on: (last, 1) down, the bridge and the machine
	# on it go with it.
	# Both sides back home first, so nobody falls with it and the round goes on.
	first.place_at(platforms.deck_at(home).centre + Vector3.UP * 1.2, 0.0)
	second.place_at(platforms.deck_at(across).centre + Vector3.UP * 1.2, 0.0)
	await _step(game, 4)
	var lip := _deck_at_cell(platforms, last, 1)
	var _down := platforms.collapse(lip, &"test")
	await _step(game, 150)
	# Gone from the world counts: a machine that reached the floor may have been taken away.
	var after := copter.body().global_position.y \
		if copter != null and is_instance_valid(copter.body()) else -INF
	_check(not platforms.deck_at(pad).is_standing() and after < parked.y - 5.0,
		"and when a platform under the pad goes, the pad and the chopper go with it",
		"bridge standing %s, chopper %.1f m lower" % [platforms.deck_at(pad).is_standing(),
			parked.y - after])

	await _dispose(game)
	_finished()


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

	# The chat box's full log against the health number, both bottom-anchored, so the
	# arithmetic holds at any height: eight rows once drew over the "100".
	var chat := ScClient.new_chat()
	add_child(chat)
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var vitals: DotVitals = hud.vitals
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

	hud.queue_free()
	await _dispose(game)
	_finished()


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

	await _dispose(game)
	_finished()


## What this game makes a noise about, both ways round.
## An id with no recipe stays silent with nothing logged above DEBUG; a recipe naming an unknown id reaches nothing.
func _test_the_game_makes_a_noise() -> void:
	_section("the game makes a noise, and every id has one")

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

	var game := await _world()
	var audio := ScAudio.new()
	add_child(audio)
	_check(audio.setup().ok and audio.manager.sink is DotAudioSinkNull,
		"it comes up headless, on the sink that records rather than plays")

	var sink := audio.manager.sink as DotAudioSinkNull
	audio.muzzle = game.arena.muzzle()

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

	audio.queue_free()
	await _dispose(game)
	_finished()


## The numbers a round produces, the achievements over them, and who is never counted.
## Three sides, so `b` going over with their platform leaves the round running.
func _test_what_a_player_keeps() -> void:
	_section("what a player keeps from a round")

	_check(ScProgress.schema().validate().ok and ScProgress.catalogue().validate().ok,
		"the numbers and the achievements are both valid documents")

	var declared := ScProgress.ids()
	var in_schema: Array[StringName] = []
	for def in ScProgress.schema().stats:
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
	# Long enough to land: everybody is put 1.2 m over their deck, and a player who is still
	# in the air is standing on nothing.
	await _step(game, 40)

	var progress := game.progress
	_check(progress != null, "an authoritative world keeps progress")

	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, 1)
	var mine := progress.session_values(&"a")
	_check(
		mine.get_value(ScProgress.DEATHS, 0.0) == 1.0 and mine.get_value(ScProgress.FALLS, 0.0) == 1.0,
		"a fall is a death and a fall"
	)

	# Three landings on a2's own platform, on the far side of it. Each is a WOBBLE and each
	# missed them.
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

	# b's platform goes over by LEAN with b on it: that is b's doing.
	var tipped_at := b.standing_on
	var _went_over := game.platforms.collapse(tipped_at, ScPlatforms.WHY_LEAN)
	_check(
		tipped_at >= 0 and progress.session_values(&"b").get_value(ScProgress.PLATFORMS_TIPPED, 0.0) == 1.0,
		"a platform that goes over by lean is tipped by whoever was on it"
	)
	_check(earned.has("b:Tipping Point"), "which is a secret achievement, told the moment it is earned",
		", ".join(earned))

	# And out. Not by waiting for the drop, which is six seconds of a section about the tip;
	# that a collapse really takes everybody on it is "a platform off its pillar takes
	# everybody on it", which waits.
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
	# Armed: with the counting moved back after `report_kill`, this reads 0 — the shot that
	# ends a round is counted after the round it ended has been filed.
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

	# Armed: with the bot guard taken out of `record`, the stand-in has a row.
	_check(not progress.stats.has_player(&"bot"),
		"and the stand-in, who survived, was shot and lost, was never counted at all")

	game.remove_player(&"a2")
	_check(not progress.stats.has_player(&"a2") and not progress.achievements.has("a2"),
		"somebody who leaves stops being counted, and their progress is let go of")

	await _dispose(game)
	_finished()

