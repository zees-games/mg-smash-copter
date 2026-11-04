extends "headless_run_part4.gd"

## Sections of [code]headless_run.gd[/code], part 5: shared state and helpers are in the base.


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
	var ran := await _hollow_run_the_u(game, runner, inner_near, outer_near, outer_far, inner_far)
	var made: PackedStringArray = ran["made"]
	var length: float = ran["length"]

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


## Runs the runner round the left U; returns the legs made and the route's length.
func _hollow_run_the_u(game: ScGame, runner: ScPlayer, inner_near: int, outer_near: int, outer_far: int, inner_far: int) -> Dictionary:
	var platforms := game.platforms
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

	return {"made": made, "length": length}


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

	var ran := await _airfield_run_routes(game, copter, pad, last, routes)
	var metres: Array[float] = ran["metres"]
	var jumps: Array[int] = ran["jumps"]
	var fastest: float = ran["fastest"]
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

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

	await _airfield_pad_collapses(game, copter, pad, parked, home, across, first, second)
	await _dispose(game)
	_finished()


## Each side along its own row, jump by jump, then into the machine and out again; returns metres, jumps and the slowest top speed.
func _airfield_run_routes(game: ScGame, copter: DotVehicleInstance, pad: int, last: int, routes: Array) -> Dictionary:
	var platforms := game.platforms
	var metres: Array[float] = []
	var jumps: Array[int] = []
	var fastest := INF
	var took := PackedStringArray()

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

	return {"metres": metres, "jumps": jumps, "fastest": fastest}


## The pad goes with the platform it rests on.
func _airfield_pad_collapses(game: ScGame, copter: DotVehicleInstance, pad: int, parked: Vector3, home: int, across: int, first: ScPlayer, second: ScPlayer) -> void:
	var platforms := game.platforms
	var last := game.config.columns - 1
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
