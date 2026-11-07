extends "headless_run_part7.gd"


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
const SECTIONS := 52

## And the total this counter cannot be.
##
## [b]A runtime error inside a section aborts that FUNCTION and nothing says so.[/b] The
## checks that already ran still print ok, the ones after it never happen, and the section
## counter is satisfied because the section announced itself on the way in. dot-settings
## reported "8 sections, 63 passed, 0 failed" and exited 0 with eight checks missing.
const CHECKS := 419


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
	await _test_terraces()
	await _test_a_slope_holds()
	await _test_blind_and_beacon_drawn()
	await _test_somebody_out_watches()
	await _test_free_roam()
	await _test_the_flashlight()
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

		_pieces_heights_and_ramps(platforms, config, id, label)

		_pieces_stand_on_pillars(platforms, config, label)

		_pieces_cross_the_wire(platforms, config, label, layout)

		_pieces_highest_comes_off(platforms, config, label)

		await _pieces_bridge_shatters(game, platforms, config, label, layout)

		await _pieces_every_one_falls(game, platforms, config, label, layout)

	await _dispose(game)
	_finished()


## Every piece can fall, not only the highest.
func _pieces_every_one_falls(game: ScGame, platforms: ScPlatforms, config: ScConfig, label: String, layout: ScLayouts.Layout) -> void:
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


## A shattering hit takes a bridge as it takes a platform.
func _pieces_bridge_shatters(game: ScGame, platforms: ScPlatforms, config: ScConfig, label: String, layout: ScLayouts.Layout) -> void:
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


## The highest piece comes off its pillar when leant on and takes its bridges along.
func _pieces_highest_comes_off(platforms: ScPlatforms, config: ScConfig, label: String) -> void:
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


## The cells survive the wire, kinds and levels both.
func _pieces_cross_the_wire(platforms: ScPlatforms, config: ScConfig, label: String, layout: ScLayouts.Layout) -> void:
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


## Every piece stands on a pillar that reaches the floor from its own height.
func _pieces_stand_on_pillars(platforms: ScPlatforms, config: ScConfig, label: String) -> void:
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


## The layout is bigger than the ordinary field, at several heights, with walkable ramps.
func _pieces_heights_and_ramps(platforms: ScPlatforms, config: ScConfig, id: StringName, label: String) -> void:
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

		_flank_kerbs_open(game, sides, walks)

		_flank_ring_clear(game, middle, walks)

		await _flank_run_pads(game, sides, middle)

		_flank_perch_sight(game, sides, middle)

		await _dispose(game)

	_finished()


## A ray at shin height from each flank's ends meets no kerb.
func _flank_kerbs_open(game: ScGame, sides: int, walks: Array) -> void:
	# And open where each one arrives: a ray at shin height from the middle of the pad,
	# and of the perch, out along the flank to a metre past the edge meets no kerb. A
	# runner is thrown over a closed kerb since dot-player-controller 2e6d930 and the
	# drive below cannot see one (armed: it passed with the openings uncut), so this is
	# what holds them — a walker, or a body sliding, is still stopped by one.
	var space_here := game.arena.get_world_3d().direct_space_state
	var blocked := PackedStringArray()

	for index in range(walks.size()):
		var walk := walks[index] as Dictionary
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


## No flank comes near the ring.
func _flank_ring_clear(game: ScGame, middle: Vector3, walks: Array) -> void:
	# The long way round never touches the ring: every flank's centre line stays further
	# from the ring's middle than the ring's own corners plus half a catwalk.
	var ring_corner := game.config.corner_size * 0.85 * sqrt(2.0)
	var nearest := INF

	for walk: Dictionary in walks:
		var a := walk["from"] as Vector3
		var b := walk["to"] as Vector3
		var closest := Geometry3D.get_closest_point_to_segment(middle, a, b)
		nearest = minf(nearest, Vector2(closest.x - middle.x, closest.z - middle.z).length())

	_check(nearest > ring_corner + ScArena.CATWALK_WIDTH * 0.5 + 2.0,
		"and no flank comes near the ring",
		"nearest %.1f m from its middle, its corners at %.1f" % [nearest, ring_corner])


## From either perch somebody crouched behind a ring block is in sight.
func _flank_perch_sight(game: ScGame, sides: int, middle: Vector3) -> void:
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


## A runner goes pad 0, perch 0, pad 1 at a run without a stall or a fall.
func _flank_run_pads(game: ScGame, sides: int, middle: Vector3) -> void:
	var config := game.config
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

	await _dais_run_on(game, sides, middle, half, top)

	_dais_hides_a_crouch(game, sides, middle, half)

	_dais_top_sees_all(game, sides, top, middle)

	await _dispose(game)
	_finished()


## From its top every pad and every perch is in sight.
func _dais_top_sees_all(game: ScGame, sides: int, top: float, middle: Vector3) -> void:
	var space := game.arena.get_world_3d().direct_space_state
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


## Crouched against the dais' far side a survivor is hidden from every pad and perch, standing is not.
func _dais_hides_a_crouch(game: ScGame, sides: int, middle: Vector3, half: float) -> void:
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


## The planar length of the route from a start through its points.
func _dais_route_length(from: Vector3, route_points: Array[Vector3]) -> float:
	var route := 0.0
	var last := from

	for point in route_points:
		route += Vector2(point.x - last.x, point.z - last.z).length()
		last = point

	return route


## A runner goes from pad 0 down its catwalk, across the ring and jumps onto the dais at a run.
func _dais_run_on(game: ScGame, sides: int, middle: Vector3, half: float, top: float) -> void:
	var config := game.config
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
	var route := _dais_route_length(runner.controller.state.position, route_points) - half

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
