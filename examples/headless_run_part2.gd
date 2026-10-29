extends "headless_run_part1.gd"

## Sections of [code]headless_run.gd[/code], part 2: shared state and helpers are in the base.


func _test_the_round() -> void:
	_section("a round is two games with a teleport in the middle")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 4.0
		c.showdown_warmup_seconds = 1.0
		c.showdown_seconds = 20.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
		c.clear_platforms_for_showdown = false
	)

	game.add_player(&"a", "A", 1)
	game.add_player(&"b", "B", 2)
	game.start()

	await _step(game, 4)
	_check(game.phase == ScGame.Phase.SURVIVAL, "it starts on the platforms",
		ScGame.Phase.keys()[game.phase])

	var somewhere: Vector3 = (game.players[&"a"] as ScPlayer).controller.state.position
	_check(somewhere.y > game.config.deck_height * 0.5, "with everybody up in the air",
		"%.1f m" % somewhere.y)

	# Past the survival clock.
	await _step(game, int(4.2 * TICK_RATE))
	_check(game.phase == ScGame.Phase.HANDOVER, "the clock sends them to the corners",
		ScGame.Phase.keys()[game.phase])

	var corner: ScPlayer = game.players[&"a"]
	var expected := game.arena.corner_point(0, game.config.team_count)
	var moved := Vector2(
		corner.controller.state.position.x - expected.x,
		corner.controller.state.position.z - expected.z
	).length()

	_check(moved < game.config.corner_size, "they are actually in their corner",
		"%.1f m from the middle of it" % moved)
	_check(corner.weapons != null, "and they are holding something")
	_check(corner.health.invulnerable, "and cannot be shot yet")

	# [b]Facing inward, and a teleport that gets the position right and the yaw wrong is
	# invisible to every count and obvious to every player.[/b] The corner is on +X for team
	# one, so facing the middle is facing -X, which in this motor's frame is a yaw of -90.
	var facing := Basis.from_euler(Vector3(0.0, deg_to_rad(corner.controller.state.yaw), 0.0))
	var middle := game.arena.showdown_centre()
	var toward_middle := Vector3(
		middle.x - expected.x, 0.0, middle.z - expected.z
	).normalized()
	_check((-facing.z).dot(toward_middle) > 0.7, "looking at the middle",
		"%.2f" % (-facing.z).dot(toward_middle))

	await _step(game, int(1.2 * TICK_RATE))
	_check(game.phase == ScGame.Phase.SHOWDOWN, "and then the weapons go hot",
		ScGame.Phase.keys()[game.phase])
	_check(not corner.health.invulnerable, "with nobody protected any more")

	# The round ends when a side has nobody left, which is dot-match's elimination rule
	# reading this game's own `alive_fn`. Unwired it falls back to a clock, and the tell is
	# visible in the first round played.
	var ended: Array[int] = []
	game.round_over.connect(func(_number: int, winner: int) -> void: ended.append(winner))

	game.players[&"b"].health.health = 0.0
	game.players[&"b"].health.alive = false

	await _step(game, 8)

	_check(not ended.is_empty(), "the round ends when a side is wiped out")
	_check(ended.is_empty() or ended[0] == 1, "and the other side won",
		"winner=%d" % (ended[0] if not ended.is_empty() else -1))

	await _dispose(game)
	_finished()


func _test_specials() -> void:
	_section("specials multiply and stack")

	var plain := ScSpecials.Active.new()
	_check(plain.is_plain(), "nothing in force is nothing in force")
	_check(is_equal_approx(plain.gravity_scale, 1.0), "and multiplies nothing")

	var feather := ScSpecials.by_id(&"feather")
	var barrage := ScSpecials.by_id(&"barrage")
	_check(feather != null and barrage != null, "the catalogue has the ones it says it has")

	var both := ScSpecials.Active.new()
	both.fold(feather)
	both.fold(barrage)

	_check(both.ids.size() == 2, "two at once is two at once")
	_check(both.gravity_scale < 1.0, "low gravity is still low gravity",
		"%.2f" % both.gravity_scale)
	_check(both.cannon_interval_scale < 0.5, "and the barrage is still a barrage",
		"%.2f" % both.cannon_interval_scale)

	# An allow-list of ids that names nothing is an operator's typo, and a server whose
	# specials silently never happen is worse than one that ignores the setting.
	var mistyped := ScConfig.new()
	mistyped.special_ids = PackedStringArray(["not_a_special"])
	_check(ScSpecials.available(mistyped).size() == ScSpecials.all().size(),
		"a special list naming nothing falls back to everything")

	var narrowed := ScConfig.new()
	narrowed.special_ids = PackedStringArray(["feather", "slick"])
	_check(ScSpecials.available(narrowed).size() == 2, "and a real list narrows it")

	# It reaches the world: low gravity is one call on the physics space and one on every
	# player's tunables, and a special that changed neither would be a document nothing reads.
	var game := await _world(func(c: ScConfig) -> void:
		c.specials_enabled = false
	)
	var player := game.add_player(&"light", "Light", 1)
	var before := player.controller.tunables.gravity

	player.retune(both)
	_check(player.controller.tunables.gravity < before, "a player's own gravity comes down",
		"%.1f from %.1f" % [player.controller.tunables.gravity, before])
	_check(player.controller.tunables.max_speed > 0.0, "and they can still move")

	await _dispose(game)
	_finished()


## A player standing on a chopper goes where it goes.
func _test_riding_the_chopper() -> void:
	_section("a player standing on a chopper is carried by it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.layout_ids = PackedStringArray(["airfield"])
	)

	_check(game.layout != null and game.layout.with_chopper and not game._copter_ids.is_empty(),
		"the airfield parks a chopper")

	var copter := game.vehicles.get_vehicle(game._copter_ids[0]) if not game._copter_ids.is_empty() else null

	if copter == null:
		_check(false, "and it can be stood on")
		_check(false, "and it takes its rider with it")
		_check(false, "and the rider is still on it")
		_check(false, "and getting off leaves them where they stepped")
		await _dispose(game)
		_finished()
		return

	var body := copter.body()
	_check(body.has_meta(ScPlayer.META_CARRIER), "it is marked as something that carries")

	# Held where it is and moved by hand, so the check is the carry and not the flying.
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.global_position = Vector3(0.0, game.config.deck_height + 30.0, 0.0)
	body.global_rotation = Vector3.ZERO

	var rider := game.add_player(&"rider", "Rider", 1)
	game.add_player(&"other", "Other", 2)
	rider.place_at(body.global_position + Vector3(0.0, 2.2, 0.0), 0.0)
	await _step(game, 30)

	var on_it := rider.controller.state.ground_id == body.get_instance_id()
	_check(on_it, "and it can be stood on",
		"standing on %s" % str(rider.controller.state.ground_id))

	var start_x := rider.controller.state.position.x
	var start_y := rider.controller.state.position.y

	for _i in range(40):
		body.global_position += Vector3(0.3, 0.05, 0.0)
		game.simulate(TICK)
		await _physics_frame()

	var carried_x := rider.controller.state.position.x - start_x
	var carried_y := rider.controller.state.position.y - start_y
	_check(carried_x > 10.0 and carried_y > 1.0, "and it takes its rider with it",
		"%.1f m along, %.1f m up of 12 and 2" % [carried_x, carried_y])
	_check(rider.controller.state.ground_id == body.get_instance_id(),
		"and the rider is still on it")

	# Off it: sideways, onto nothing, and then it is no longer theirs to move.
	rider.place_at(body.global_position + Vector3(30.0, 2.2, 0.0), 0.0)
	var left_at := rider.controller.state.position.x
	body.global_position += Vector3(5.0, 0.0, 0.0)
	await _step(game, 5)
	_check(absf(rider.controller.state.position.x - left_at) < 1.0,
		"and getting off leaves them where they stepped",
		"%.2f m" % (rider.controller.state.position.x - left_at))

	await _dispose(game)
	_finished()


## dot-core's audit over every layout's field: drawn geometry nothing collides with is walked
## through. Strict, so a new mesh must have a shape or say (`dot_no_collision`) why not.
func _test_collision_audit() -> void:
	_section("nothing drawn in a layout is walked through")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var unshaped := PackedStringArray()

	for layout in ScLayouts.all(game.config):
		game.platforms.build(layout, game.physics)
		await _physics_frame()
		var res := DotCollisionAudit.audit(game, true)

		if res.ok:
			var report: DotCollisionAudit = res.value
			print("  ..    %s collision audit: %d of %d" % [String(layout.id), report.count(), report.examined])

			if report.count() > 0:
				unshaped.append("%s (%d)" % [layout.id, report.count()])

				for line in report.describe_lines().slice(1, 12):
					print("    %s" % line)
		else:
			unshaped.append("%s (audit failed: %s)" % [layout.id, res.error.message])

	_check(unshaped.is_empty(), "every layout's drawn geometry is solid or opted out", ", ".join(unshaped))
	# Gone before the next section: its decks sit in the shared physics space, and a later
	# section's runners would stand on them.
	await _dispose(game)
	_finished()


## The layouts are dot-map's maps: listed, changeable by command, voted from the catalogue.
func _test_the_map_catalogue() -> void:
	_section("the layouts are listed, changed and voted as dot-map maps")

	var config := ScConfig.new()
	var catalogue := ScLayouts.catalogue(config)
	var layouts := ScLayouts.allowed(config)

	_check(catalogue.size() == layouts.size() and catalogue.problems().is_empty(),
		"every layout is a valid map def", "%d of %d; %s" % [
			catalogue.size(), layouts.size(), ", ".join(catalogue.problems())])
	_check(catalogue.has(&"ring") and catalogue.has(&"terraces") and catalogue.has(&"watchtowers"),
		"and the bigger maps are in it")

	var session := ScMapSession.new()
	session.catalogue = catalogue
	var asked: Array[StringName] = []
	session.apply_fn = func(id: StringName) -> DotResult:
		asked.append(id)
		return DotResult.success(id)
	add_child(session)

	var changed := await session.change_to(&"ring")
	_check(changed.ok and asked == [&"ring"] and session.current != null and session.current.id == &"ring",
		"a change through the session reaches the game and becomes current")

	var refused := await session.change_to(&"nowhere")
	_check(not refused.ok and asked.size() == 1, "and an unknown map is refused")

	session.apply_fn = func(_id: StringName) -> DotResult:
		return DotResult.fail(DotError.CODE_STATE, "no")
	var failed := await session.change_to(&"terraces")
	_check(not failed.ok and session.current.id == &"ring", "and a refusal leaves the map as it was")

	remove_child(session)
	session.free()

	# And a server that has the module has the commands.
	var game := await _world()
	var ids := ScLayouts.catalogue(game.config)
	_check(ids.size() >= 9, "the catalogue lists the whole set", "%d maps" % ids.size())
	await _dispose(game)
	_finished()


func _test_the_throat() -> void:
	_section("nothing is built over the cannon's mouth, and every shot gets out")

	var game := await _world(func(c: ScConfig) -> void:
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms
	var muzzle := game.arena.muzzle()
	var active := ScSpecials.Active.new()

	var crowded := PackedStringArray()
	var margins := PackedStringArray()
	var stuck := PackedStringArray()
	var fired := 0

	for layout in ScLayouts.all(config):
		platforms.build(layout, game.physics)
		await _physics_frame()
		await _physics_frame()

		var clear := platforms.clearance_from(muzzle.x, muzzle.z)
		margins.append("%s %.1f" % [layout.id, clear])

		if clear < ScArena.THROAT_CLEARANCE:
			crowded.append("%s %.2f m" % [layout.id, clear])

		# [b]Fired, not only measured[/b], and with every tier unlocked: at the start of a
		# round the cannon throws crates, and a crate gets through a slot a monolith does
		# not. Eight shots a layout, each watched for half a second.
		var blocked := 0

		for _shot in range(8):
			var prop: DotPropInstance = game.cannon.call("_launch_one", 1000.0, active)

			if prop == null:
				continue

			fired += 1
			var top := -INF

			for _t in range(32):
				game.simulate(TICK)
				await _physics_frame()
				var body := prop.body()

				if body == null or not is_instance_valid(body):
					break

				top = maxf(top, body.global_position.y)

			if top < config.deck_height + 2.0:
				blocked += 1

			var _gone := game.props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

		if blocked > 0:
			stuck.append("%s %d of 8" % [layout.id, blocked])

	_check(crowded.is_empty(), "no layout builds anything over the cannon's mouth",
		"; ".join(crowded) if not crowded.is_empty() else ", ".join(margins))
	_check(fired == 8 * ScLayouts.all(config).size() and stuck.is_empty(),
		"and every shot on every layout climbs past the decks",
		"%d fired; %s" % [fired, ", ".join(stuck) if not stuck.is_empty() else "none held"])

	await _dispose(game)
	_finished()


## The ring's cover: one block per team, facing that team's pad, and it covers.
func _test_the_ring_cover() -> void:
	_section("the ring has cover, and it faces the pads")

	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()

		var middle := game.arena.showdown_centre()
		var ring := game.config.corner_size * 0.85
		var cover := game.arena.ring_cover()
		var built := 0

		for index in range(cover.size()):
			if game.arena.has_node(NodePath("Showdown/RingCover%d" % index)):
				built += 1

		var on_ring := true

		for block in cover:
			var d := block.origin - middle
			if absf(d.x) > ring - 1.5 or absf(d.z) > ring - 1.5:
				on_ring = false

		_check(cover.size() == sides and built == sides and on_ring,
			"with %d sides, one block per side stands on the ring" % sides,
			"%d described, %d built, on the ring %s" % [cover.size(), built, on_ring])

		# From every pad: a person crouched right behind that pad's block is out of sight,
		# and a person standing there is not, which is what chest high means.
		var space := game.arena.get_world_3d().direct_space_state
		var hidden := 0
		var seen := 0

		for index in range(sides):
			var eye := game.arena.corner_point(index, sides) + Vector3.UP * 1.6
			var block := cover[index]
			var inward := (middle - block.origin)
			inward.y = 0.0
			inward = inward.normalized()
			var behind := block.origin + inward * (ScArena.RING_COVER_SIZE.z * 0.5 + 0.4)
			var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
			var standing := Vector3(behind.x, middle.y + 1.6, behind.z)

			var low := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched))
			var high := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, standing))

			if not low.is_empty() and String((low["collider"] as Node).name).begins_with("RingCover"):
				hidden += 1
			if high.is_empty():
				seen += 1

		_check(hidden == sides and seen == sides,
			"and from each pad it hides somebody crouched behind it, not somebody standing",
			"%d of %d hidden, %d of %d seen over it" % [hidden, sides, seen, sides])

		await _dispose(game)

	_finished()


func _test_the_zigzag() -> void:
	_section("the chequerboard is crossed on the diagonals and only on them")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.layout_ids = PackedStringArray(["checker"])
	)
	var platforms := game.platforms

	# Through the operator's own knob, so the render and a server running it are the same
	# field this drives.
	_check(game.layout != null and game.layout.id == &"checker",
		"the round is laid out as the chequerboard",
		String(game.layout.id) if game.layout != null else "none")

	var runner := game.add_player(&"runner", "Runner", 1)
	game.add_player(&"other", "Other", 2)

	# Along the whole field: (0,0) (1,1) (2,0) (3,1) (4,0). Four jumps, each one a
	# diagonal, each from the middle of a platform that is leaning under the person on it.
	var route: Array[int] = []

	for column in range(game.config.columns):
		route.append(_deck_at_cell(platforms, column, column % 2))

	_check(not route.has(-1), "the zigzag is all there", str(route))

	var start := platforms.deck_at(route[0])
	runner.place_at(start.centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)

	var made := PackedStringArray()

	for leg in range(route.size() - 1):
		var from := route[leg]
		var to := route[leg + 1]
		await _walk_to(game, runner, platforms.deck_at(from).centre)
		var landed := await _jump_across(game, runner, from, to)
		made.append("%s%s" % [_cell_name(platforms, to), "" if landed else " MISSED"])

		if not landed:
			break

	_check(made.size() == route.size() - 1 and not ", ".join(made).contains("MISSED"),
		"a runner crosses the field on four diagonals", ", ".join(made))
	_check(runner.is_alive() and runner.standing_on == route[route.size() - 1],
		"and is standing on the far corner platform at the end",
		"on %d, alive %s" % [runner.standing_on, runner.is_alive()])
	_check(platforms.standing_count() == platforms.count(),
		"with every platform they crossed still up",
		"%d of %d" % [platforms.standing_count(), platforms.count()])

	# [b]And the straight line is a fall, which is the other half of "every jump is a
	# diagonal".[/b] From the far corner back along the row toward (2,0), jumping at the lip.
	var along := _deck_at_cell(platforms, game.config.columns - 3, 0)
	await _walk_to(game, runner, platforms.deck_at(route[route.size() - 1]).centre)
	var crossed := await _jump_across(game, runner, route[route.size() - 1], along)
	_check(not crossed and runner.controller.state.position.y < game.config.deck_height - 3.0,
		"and running straight along a row is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## Watchtowers: the rail is opened where a ramp arrives (`ScPlatforms._open_rail`); runs a side up one ramp,
## over the tower and down the other onto the far row. The layout checks are in [method _test_watchtowers].
func _watchtowers_layout(game: ScGame) -> void:
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"watchtowers",
		"the round is laid out as Watchtowers",
		String(game.layout.id) if game.layout != null else "none")

	# The rows meet only at the towers: one island with them, and the two rows apart without
	# them and their ramps.
	var cells := platforms.cells()
	var rows_only: Array[Vector3i] = []

	for cell in cells:
		if ScLayouts.kind_of(cell) == ScLayouts.KIND_PLATFORM:
			rows_only.append(cell)

	var whole := ScLayouts.islands(cells, game.layout.jumps)
	var apart := ScLayouts.islands(rows_only, game.layout.jumps)
	var whole_count := {}
	var apart_count := {}

	for i in whole:
		whole_count[i] = true

	for i in apart:
		apart_count[i] = true

	_check(whole_count.size() == 1 and apart_count.size() == 2,
		"the rows are one field through the towers, and two without them",
		"%d island(s) with the towers, %d without" % [whole_count.size(), apart_count.size()])

	# The rail is open where each ramp arrives and closed on the two sides that drop away,
	# on this layout's two towers and on every tower of The Ring.
	var shut := PackedStringArray()

	for id: StringName in [&"watchtowers", &"ring"]:
		if id != &"watchtowers":
			platforms.build(ScLayouts.by_id(config, id), game.physics)
			await _physics_frame()

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if not deck.is_tower:
				continue

			var ramps := {}

			for j in range(platforms.count()):
				var span := platforms.deck_at(j)

				if span.is_bridge and span.supports.x == i:
					ramps[ScPlatforms.RAIL_SIDE_PLUS_Z] = true

				if span.is_bridge and span.supports.y == i:
					ramps[ScPlatforms.RAIL_SIDE_MINUS_Z] = true

			for side in range(4):
				var left := platforms.rail_pieces(i, side)

				if (left == 0) != ramps.has(side):
					shut.append("%s %s side %d: %d pieces%s" % [id, _cell_name(platforms, i), side,
						left, " over a ramp" if ramps.has(side) else ""])

	_check(shut.is_empty(),
		"every tower's rail is open where a ramp arrives, and only there",
		", ".join(shut) if not shut.is_empty() else "watchtowers and ring")


## Runs a side up one ramp and over the tower and down the other, returning what it measured.
func _watchtowers_route(game: ScGame) -> Dictionary:
	var platforms := game.platforms
	var runner := game.add_player(&"runner", "Runner", 1)
	game.start()
	await _step(game, 20)

	var start := _deck_at_cell(platforms, 1, 0)
	var foot := _deck_at_cell(platforms, 0, 0)
	var far := _deck_at_cell(platforms, 0, 2)
	var tower := -1

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_tower and deck.column == 0:
			tower = i

	var made := PackedStringArray()
	var length := 0.0
	var peak := -INF

	if start < 0 or foot < 0 or far < 0 or tower < 0:
		made.append("no route: (1,0) %d, (0,0) %d, tower %d, (0,2) %d MISSED" % [
			start, foot, tower, far])
	else:
		var stops := [start, foot, tower, far]

		for leg in range(stops.size() - 1):
			var a := platforms.deck_at(stops[leg]).centre
			var b := platforms.deck_at(stops[leg + 1]).centre
			length += Vector2(b.x - a.x, b.z - a.z).length()

		runner.place_at(platforms.deck_at(start).centre + Vector3.UP * 0.2, 0.0)
		await _step(game, 20)
		_track(runner)

		await _walk_to(game, runner, platforms.deck_at(start).centre)
		var landed := await _jump_across(game, runner, start, foot)
		made.append("%s%s" % [_cell_name(platforms, foot), "" if landed else " MISSED"])

		if landed:
			# Up the ramp at a run: walked, never jumped.
			await _run_to(game, runner, platforms.deck_at(tower).centre, 0.3)
			await _walk_to(game, runner, platforms.deck_at(tower).centre)
			peak = runner.controller.state.position.y
			var up := runner.is_alive() and runner.standing_on == tower
			made.append("the tower%s" % ("" if up else " MISSED"))

			if up:
				await _run_to(game, runner, platforms.deck_at(far).centre, 0.3)
				await _walk_to(game, runner, platforms.deck_at(far).centre)
				var down := runner.is_alive() and runner.standing_on == far
				made.append("%s%s" % [_cell_name(platforms, far), "" if down else " MISSED"])

	return {
		"runner": runner, "far": far, "tower": tower, "made": made, "length": length, "peak": peak,
	}


## Back up the ramp and off the tower's open side, away from the field: a fall.
func _watchtowers_drop(game: ScGame, runner: ScPlayer, tower: int, far: int) -> void:
	var platforms := game.platforms
	var config := game.config
	var fell := false

	if tower >= 0 and far >= 0 and runner.standing_on == far:
		await _run_to(game, runner, platforms.deck_at(tower).centre, 0.3)
		await _walk_to(game, runner, platforms.deck_at(tower).centre)
		var outside := platforms.deck_at(tower).centre + Vector3(-12.0, 0.0, 0.0)
		await _run_to(game, runner, outside, 0.3)
		await _step(game, 60)
		fell = runner.controller.state.position.y < config.deck_height - 3.0 \
			or not runner.is_alive()

	_check(fell, "and running off the tower's outer side is a fall",
		"%.1f m" % runner.controller.state.position.y)


func _test_watchtowers() -> void:
	_section("Watchtowers: the rows meet only at a tower, up one ramp and down the other")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["watchtowers"])
	)
	var platforms := game.platforms
	var config := game.config

	await _watchtowers_layout(game)

	platforms.build(game.layout, game.physics)
	await _physics_frame()

	var route := await _watchtowers_route(game)
	var runner: ScPlayer = route.runner
	var far: int = route.far
	var tower: int = route.tower
	var made: PackedStringArray = route.made
	var length: float = route.length
	var peak: float = route.peak

	var covered := _covered
	var top := _top_speed
	_track(null)
	var max_speed := ScPlayer.tunables_for(config, null).max_speed
	var rise := 3.0 * ScLayouts.LEVEL_RISE

	_check(made.size() == 3 and not ", ".join(made).contains("MISSED"),
		"a runner jumps to the foot of a ramp, climbs to the tower and runs down to the far row",
		", ".join(made))
	_check(peak >= config.deck_height + rise - 0.1,
		"and stands on the high ground, %.1f m over both rows" % rise,
		"%.2f m against decks at %.1f" % [peak, config.deck_height])
	_check(length > 0.0 and covered >= length * 0.95 and top >= max_speed * 0.95,
		"and covers the route at a run",
		"%.1f m covered of a %.1f m route, top speed %.2f of %.2f m/s" % [
			covered, length, top, max_speed])
	_check(far >= 0 and runner.is_alive() and runner.standing_on == far
			and platforms.standing_count() == platforms.count(),
		"and ends on the far row, with all of it still up",
		"on %d, alive %s, %d of %d up" % [runner.standing_on, runner.is_alive(),
			platforms.standing_count(), platforms.count()])

	await _watchtowers_drop(game, runner, tower, far)
	await _dispose(game)
	_finished()
