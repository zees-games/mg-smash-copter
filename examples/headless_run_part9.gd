extends "headless_run_part8.gd"

## The terraces section of the headless_run suite (headless_run.gd extends this): the layout's shape, its climb and what can be seen from it.


func _test_terraces() -> void:
	_section("Terraces: a bowl climbed one level a jump, to a rim that sees all of it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["terraces"])
	)
	var platforms := game.platforms

	_check(game.layout != null and game.layout.id == &"terraces",
		"the round is laid out as Terraces",
		String(game.layout.id) if game.layout != null else "none")

	if game.layout == null or game.layout.id != &"terraces":
		await _dispose(game)
		_finished()
		return

	_terraces_shape(game.layout, game.config)
	platforms.build(game.layout, game.physics)
	await _physics_frame()

	var along := game.add_player(&"along", "Along", 1)
	var across := game.add_player(&"across", "Across", 1)
	game.start()
	await _step(game, 20)

	# From the floor beside the mouth to the rim: out along the middle row, and up across the rows.
	for climb in [
		[along, "along the middle row", [Vector2i(2, 2), Vector2i(1, 2), Vector2i(0, 2)]],
		[across, "across the rows", [Vector2i(4, 2), Vector2i(4, 3), Vector2i(4, 4)]],
	]:
		var made := await _terraces_climb(game, climb[0], climb[2])
		_check(not ", ".join(made).contains("MISSED"),
			"a runner climbs from the floor to the rim %s, one level a jump" % climb[1],
			", ".join(made))

	var rim_a := _deck_at_cell(platforms, 0, 2)
	var rim_b := _deck_at_cell(platforms, 4, 4)
	_check(along.is_alive() and across.is_alive() and along.standing_on == rim_a
			and across.standing_on == rim_b and platforms.standing_count() == platforms.count(),
		"and both end on the rim, with all of the bowl still up",
		"on %d and %d, %d of %d up" % [along.standing_on, across.standing_on,
			platforms.standing_count(), platforms.count()])

	_terraces_sight(game)
	await _dispose(game)
	_finished()


## The rim is every edge cell at one height and nothing else reaches it; every jump the layout means is one level at most, and the bowl is one island.
func _terraces_shape(layout: ScLayouts.Layout, config: ScConfig) -> void:
	var cells := layout.cells(config)
	var columns := layout.field_columns(config)
	var rows := layout.field_rows(config)
	var top := 0
	var wrong := PackedStringArray()
	var levels := {}

	for cell in cells:
		top = maxi(top, ScLayouts.level_of(cell))
		levels[ScLayouts.level_of(cell)] = true

	for cell in cells:
		var rim := cell.x == 0 or cell.y == 0 or cell.x == columns - 1 or cell.y == rows - 1

		if rim != (ScLayouts.level_of(cell) == top):
			wrong.append("(%d,%d) level %d" % [cell.x, cell.y, ScLayouts.level_of(cell)])

	_check(wrong.is_empty() and levels.size() == 3,
		"every edge cell is the rim at one height, above three terraces' worth of bowl",
		", ".join(wrong) if not wrong.is_empty() else "%dx%d, rim at level %d, %d levels" % [
			columns, rows, top, levels.size()])

	var steep := PackedStringArray()

	for pair in ScLayouts.pairs(cells):
		if (layout.jumps & pair.z) == 0:
			continue

		var a := cells[pair.x]
		var b := cells[pair.y]

		if absi(ScLayouts.level_of(a) - ScLayouts.level_of(b)) > 1:
			steep.append("(%d,%d)-(%d,%d)" % [a.x, a.y, b.x, b.y])

	var island := {}

	for i in ScLayouts.islands(cells, layout.jumps):
		island[i] = true

	_check(steep.is_empty() and island.size() == 1,
		"no jump the bowl means climbs more than one level, and it is one island",
		", ".join(steep) if not steep.is_empty() else "%d island(s)" % island.size())


## Places [param runner] on the first of [param stops] and jumps it to each of the rest, noting each landing's rise.
func _terraces_climb(game: ScGame, runner: ScPlayer, stops: Array) -> PackedStringArray:
	var platforms := game.platforms
	var made := PackedStringArray()
	var decks: Array[int] = []

	for stop: Vector2i in stops:
		decks.append(_deck_at_cell(platforms, stop.x, stop.y))

	if decks.has(-1):
		made.append("no route %s MISSED" % str(stops))
		return made

	runner.place_at(platforms.deck_at(decks[0]).centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)
	await _walk_to(game, runner, platforms.deck_at(decks[0]).centre)
	var height := runner.controller.state.position.y

	for leg in range(1, decks.size()):
		var landed := await _jump_across(game, runner, decks[leg - 1], decks[leg])

		if landed:
			await _walk_to(game, runner, platforms.deck_at(decks[leg]).centre)

		var y := runner.controller.state.position.y
		var one_level := absf(y - height - ScLayouts.LEVEL_RISE) < 0.2
		made.append("%s +%.2f m%s" % [_cell_name(platforms, decks[leg]), y - height,
			"" if landed and runner.standing_on == decks[leg] and one_level else " MISSED"])
		height = y

		if not landed:
			break

	return made


## From every rim platform, a person standing on any other platform is in sight: no deck is between their eyes.
func _terraces_sight(game: ScGame) -> void:
	var platforms := game.platforms
	var space := game.arena.get_world_3d().direct_space_state
	var top := -INF
	var rays := 0
	var hidden := PackedStringArray()

	for i in range(platforms.count()):
		top = maxf(top, platforms.deck_at(i).centre.y)

	for i in range(platforms.count()):
		var from := platforms.deck_at(i)

		if from.centre.y < top - 0.05:
			continue

		var eye := from.centre + Vector3.UP * 1.6

		for j in range(platforms.count()):
			if j == i:
				continue

			var body := platforms.deck_at(j).centre + Vector3.UP * 1.0
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, body))
			rays += 1

			if not hit.is_empty() and platforms.index_of_body(int(hit["collider_id"])) >= 0:
				hidden.append("%s from %s" % [_cell_name(platforms, j), _cell_name(platforms, i)])

	_check(rays > 0 and hidden.is_empty(),
		"and from every rim platform, somebody standing anywhere in the bowl is in sight",
		"%d sight lines, hidden: %s" % [rays, ", ".join(hidden) if not hidden.is_empty() else "none"])
