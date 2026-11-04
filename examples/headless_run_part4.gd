extends "headless_run_part3.gd"

## Sections of [code]headless_run.gd[/code], part 4: shared state and helpers are in the base.


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

	_check_showdown_edges(game)

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

	var flat := _check_reach_arithmetic(config)

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

		parked.append_array(_unparked_choppers(game, layout))

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

	await _walk_over_a_kerb()
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

			var points := _catwalk_points(body)

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
