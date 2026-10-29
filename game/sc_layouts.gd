extends RefCounted

const ScConfig := preload("sc_config.gd")
const ScPaths := preload("sc_paths.gd")

## What shape the platform field takes this round, as a catalogue of documents.
##
## The same platforms rearranged are a different round, for free: knocking out a column or removing bridges changes where the cannon can corner a player. A document, not a scene: a layout is six numbers, so one id in the HELLO lets a client rebuild the identical field.

const CHANNEL := "sc.layouts"

## Which cells of the grid carry a platform.
enum Gaps {
	## All of them. The full field.
	NONE,
	## Every other cell, offset by row, so no two neighbours touch.
	CHECKER,
	## Only the outer two columns at each end. Two islands and a lot of air.
	ENDS,
	## Everything except the middle third of the columns: on five, the centre one. The
	## cannon has nothing close to aim at.
	HOLLOW,
	## Every other column, which leaves a gap on each side of every platform.
	COMBED,
}

## Where the walkways between the rows go.
enum Bridges {
	## None. The rows are two separate worlds for the whole round.
	NONE,
	## At the outermost columns only, which is the shape the original map has.
	OUTER,
	## One at every column.
	ALL,
	## Every other column.
	ALTERNATE,
}

## Which jumps between platforms a layout MEANS a player to make, as flags.
##
## A declaration the suite holds the geometry to both ways: named kinds must be inside a running jump (with the dip of the run) and unnamed ones outside it. Pairs are read off the built field; see [method pairs]. A bridged pair is walked and none of these.
enum Jumps {
	## To the next platform along the same row.
	ALONG_ROWS = 1,
	## To the nearest platform along the same row across one or more missing ones.
	ACROSS_HOLES = 2,
	## Straight across to the other row, where no bridge joins the two.
	ACROSS_ROWS = 4,
	## To a platform one column over in the next row.
	DIAGONALS = 8,
}

## What a cell of a layout is, and how high it stands: the cell's `z`.
##
## Two bits of kind and three of level in the integer that was a bridge flag, so older layouts read the same. Level is in steps of [constant LEVEL_RISE]; a bridge's level comes from its two ends.
const KIND_PLATFORM := 0
const KIND_BRIDGE := 1
## A small platform on a taller pillar: a watchtower, or the top of a ramp.
const KIND_TOWER := 2

const LEVEL_SHIFT := 2
const MAX_LEVEL := 7

## Metres one level stands above the one below. [b]Just over the controller's step-up
## (0.45 m) and well under a jump's apex (1.15 m)[/b], so a stepped island is climbed by
## jumping and never by walking, and never needs more than the one jump to get up a step.
const LEVEL_RISE := 0.6

## A tower's side, as a fraction of a platform's.
const TOWER_SCALE := 0.62


static func make_cell(column: int, row: int, kind: int = KIND_PLATFORM, level: int = 0) -> Vector3i:
	return Vector3i(column, row, kind | (clampi(level, 0, MAX_LEVEL) << LEVEL_SHIFT))


static func kind_of(c: Vector3i) -> int:
	return c.z & 3


static func level_of(c: Vector3i) -> int:
	return (c.z >> LEVEL_SHIFT) & MAX_LEVEL


static func is_bridge_cell(c: Vector3i) -> bool:
	return kind_of(c) == KIND_BRIDGE


## One arrangement of the field.
class Layout extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""

	## How likely this layout is against the others. See [method pick].
	var weight: float = 10.0

	var gaps: int = Gaps.NONE
	var bridges: int = Bridges.OUTER

	## Whether a chopper is parked on this layout.
	var with_chopper: bool = false

		## The (column, row) the first chopper is parked in the middle of, or (-1, -1) for the ordinary pad.
		##
		## Server-side only: the machine is replicated where it comes to rest ([code]ScArena.chopper_pad[/code]).
	var chopper_cell := Vector2i(-1, -1)

		## Whether [member chopper_cell] names a BRIDGE (the one leaving row `y` at column `x`) rather than a platform.
		##
		## A bridge is the steadiest ground and is reached along either row; it goes when either platform does. Server-side only.
	var chopper_on_bridge: bool = false

		## What the configured column spacing is multiplied by.
		##
		## Above one is islands with jumps that must be meant; below one, a collapse takes its neighbour's footing.
	var pitch_scale: float = 1.0

		## What the configured ROW spacing is multiplied by.
		##
		## The rows are a bridge apart (13.5 m of air) on every layout but one; a layout that wants them a JUMP apart pulls them in here and says so in [member jumps].
	var row_pitch_scale: float = 1.0

		## How far the whole field is moved along the rows, as a fraction of the row pitch.
		##
		## For the layout whose rows are a jump apart: centred, the cannon's tube would stand in a gap a monolith cannot get up through, so the field moves half a row to put the tube in the missing platform's hole.
	var row_shift: float = 0.0

	## Which jumps this layout means a player to make. A mask of [enum Jumps].
	var jumps: int = 0

		## What the configured platform stiffness is multiplied by.
		##
		## Below one is a wobblier field, which a player feels before they see it.
	var stiffness_scale: float = 1.0

	## A line for the HUD when the round begins, so a player knows what they are looking at.
	var blurb: String = ""

		## How many columns and rows this layout is, or 0 for what [member ScConfig.columns] and [member ScConfig.rows] say.
		##
		## The bigger maps carry their own, since `sc_columns` sizes the ordinary field only.
	var columns: int = 0
	var rows: int = 0

	## An explicit list of cells, for a layout made of pieces rather than of a pattern of
	## gaps. Empty means [member gaps] and [member bridges] decide, as they always did.
	var custom: Array[Vector3i] = []

	func field_columns(config: ScConfig) -> int:
		return columns if columns > 0 else config.columns

	func field_rows(config: ScConfig) -> int:
		return rows if rows > 0 else config.rows

		## Every platform this layout puts out, as (column, row, is_bridge).
		##
		## One description: the field, the spawns, the cannon's targets and the client's copy are all derived from it, so they cannot drift.
	func cells(config: ScConfig) -> Array[Vector3i]:
		if not custom.is_empty():
			return custom.duplicate()

		var out: Array[Vector3i] = []

		for row in range(config.rows):
			for column in range(config.columns):
				if _has_platform(column, row, config):
					out.append(Vector3i(column, row, 0))

		# Bridges join row `r` to row `r + 1`, so there is one fewer set of them than
		# there are rows — and none at all on a single-row layout, where there is nothing
		# to join.
		for row in range(config.rows - 1):
			for column in range(config.columns):
				if _has_bridge(column, row, config):
					out.append(Vector3i(column, row, 1))

		return out

	func _has_platform(column: int, row: int, config: ScConfig) -> bool:
		match gaps:
			Gaps.CHECKER:
				return (column + row) % 2 == 0
			Gaps.ENDS:
				return column < 2 or column >= config.columns - 2
			Gaps.HOLLOW:
								# The middle third, rounded; the count keeps the field's parity so the hole is centred on the tube, and at least one column is left at each end.
				var lost := maxi(1, config.columns / 3)

				if (config.columns - lost) % 2 == 1:
					lost += 1

				lost = mini(lost, maxi(config.columns - 2, 0))
				var low := (config.columns - lost) / 2
				return column < low or column >= low + lost
			Gaps.COMBED:
				return column % 2 == 0
			_:
				return true

	func _has_bridge(column: int, row: int, config: ScConfig) -> bool:
		# A bridge with nothing at either end of it is a diving board. Both platforms it
		# joins have to be there, or it is left out — which is what makes CHECKER a layout
		# with almost no bridges on it however many it asked for.
		if not _has_platform(column, row, config) or not _has_platform(column, row + 1, config):
			return false

				# Never over the cannon's mouth: the tube stands mid-field with its muzzle 3 m under the decks, and on an odd-column, even-row field the middle bridge sits exactly on it, so every shot would go up into its underside. The suite's throat section holds this for every layout.
		if row_shift == 0.0 and config.columns % 2 == 1 and column == config.columns / 2 \
				and config.rows % 2 == 0 and row == config.rows / 2 - 1:
			return false

		match bridges:
			Bridges.ALL:
				return true
			Bridges.OUTER:
				return column == 0 or column == config.columns - 1
			Bridges.ALTERNATE:
				return column % 2 == 1
			_:
				return false

	func describe() -> Dictionary:
		return {
			"id": String(id),
			"gaps": Gaps.keys()[gaps],
			"bridges": Bridges.keys()[bridges],
			"chopper": with_chopper,
			"chopper_cell": "%d,%d%s" % [chopper_cell.x, chopper_cell.y,
				" bridge" if chopper_on_bridge else ""],
			"pitch": "%.2f" % pitch_scale,
			"row_pitch": "%.2f" % row_pitch_scale,
			"row_shift": "%.2f" % row_shift,
			"jumps": jumps,
			"stiffness": "%.2f" % stiffness_scale,
		}


static func _make(
	p_id: StringName,
	p_name: String,
	p_weight: float,
	p_gaps: int,
	p_bridges: int,
	p_blurb: String
) -> Layout:
	var layout := Layout.new()
	layout.id = p_id
	layout.display_name = p_name
	layout.weight = p_weight
	layout.gaps = p_gaps
	layout.bridges = p_bridges
	layout.blurb = p_blurb
	return layout


## Subscribed pack maps (solo only; see sc_workshop.gd): id -> Layout. Empty on a server.
static var workshop: Dictionary = {}


## The game's own layout ids, which a pack map can never take.
static func own_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var saved := workshop
	workshop = {}
	for layout in all(ScConfig.new()):
		out.append(String(layout.id))
	workshop = saved
	return out


## Every layout this game can play, in the order they were written, then any pack map.
static func all(config: ScConfig) -> Array[Layout]:
	var out := _own(config)
	for id: Variant in workshop:
		out.append(workshop[id] as Layout)
	return out


static func _own(config: ScConfig) -> Array[Layout]:
	var out: Array[Layout] = []

	var full := _make(
		&"full", "Full Deck", 20.0, Gaps.NONE, Bridges.OUTER,
		"Every platform is up. Nowhere is safe and everywhere is reachable."
	)
	full.jumps = Jumps.ALONG_ROWS
	out.append(full)

	var checker := _make(
		&"checker", "Chequerboard", 13.0, Gaps.CHECKER, Bridges.ALL,
		"Half the platforms. Every jump is a diagonal."
	)
		# The rows are pulled in to a jump apart so the chequerboard's diagonals (from one row to the other) are the only way anywhere, as the blurb says. At 0.525 of the row pitch a diagonal is 2.8 m of air along a runner's line, inside the 3.2 m reached from a dipped lip, and the next platform along a row is 12.3 m away. Columns stay at the ordinary spacing so the corners are where the jump leaves from.
	checker.row_pitch_scale = 0.525
	# And half a row over, so the tube stands in the hole where (2,1) would be rather than
	# in a 2.1 m slot one metre from (2,0)'s edge, where one shot in twenty went up into
	# its underside. See [member Layout.row_shift].
	checker.row_shift = -0.5
	checker.jumps = Jumps.DIAGONALS
	out.append(checker)

	var islands := _make(
		&"islands", "Two Islands", 10.0, Gaps.ENDS, Bridges.NONE,
		"Two islands and a lot of air between them. Nobody is crossing."
	)
		# The rows are a jump apart and the columns pulled in a little, so each end is ONE island of four platforms crossed every way (1.8 m of air along a row, 1.7 across, 2.6 on a diagonal, against 2.9 m reached). The missing middle column is 14.1 m of air no jump reaches, with the tube 7 m from the nearest edge, so nothing moves half a row over.
	islands.pitch_scale = 1.08
	islands.row_pitch_scale = 0.51
	islands.jumps = Jumps.ALONG_ROWS | Jumps.ACROSS_ROWS | Jumps.DIAGONALS
	out.append(islands)

	var spine := _make(
		&"spine", "The Spine", 11.0, Gaps.NONE, Bridges.ALL,
		"Bridges everywhere. The walkways are the steady ground and everybody knows it."
	)
	# Steadier, because a map whose safe ground is a bridge wants the platforms either
	# side of it to be the dangerous half rather than both halves at once.
	spine.stiffness_scale = 1.15
		# Bridges rest on the two lips they join (`ScPlatforms._rest_bridges`): they fall only with a platform they rest on, so crowding a bridge brings the platforms under it down.
		#
		# Jumps along the rows, 0.90 m of air against a 3.97 m run (the reach section). Between the rows everything is walked: four bridges, the middle column's left out over the tube, and 13.5 m of air no jump reaches.
	spine.jumps = Jumps.ALONG_ROWS
	out.append(spine)

	var airfield := _make(
		&"airfield", "Airfield", 13.0, Gaps.NONE, Bridges.OUTER,
		"There is a chopper on the pad. Somebody is going to take it."
	)
	airfield.with_chopper = config.chopper_enabled
		# The pad is the far bridge, at the end of BOTH rows: the first side runs four jumps, the second three, and they arrive at the two ends of one walkway. The ordinary pad (3,1) was two jumps from the second side and four and a bridge from the first, so the taker was always the same side. A bridge falls with either platform, so the cannon taking (4,0) or (4,1) takes the pad. `headless_run`'s Airfield section runs both sides there.
	airfield.chopper_cell = Vector2i(config.columns - 1, 0)
	airfield.chopper_on_bridge = true
	airfield.jumps = Jumps.ALONG_ROWS
	out.append(airfield)

	var gauntlet := _make(
		&"gauntlet", "The Gauntlet", 11.0, Gaps.COMBED, Bridges.NONE,
		"Every platform stands alone, and none of them is holding still."
	)
	gauntlet.pitch_scale = 0.82
	# The wobbly one. Two thirds of the usual spring is a platform that leans under one
	# person walking, which on a layout with no bridges is the whole round.
	gauntlet.stiffness_scale = 0.66
	# None. "Every platform stands alone" is a claim about reach, and the suite holds it.
	gauntlet.jumps = 0
	out.append(gauntlet)

	var broadside := _make(
		&"broadside", "Broadside", 9.0, Gaps.NONE, Bridges.ALTERNATE,
		"Pushed apart, half the bridges, and a chopper over the middle of it."
	)
	broadside.pitch_scale = 1.22
	broadside.with_chopper = config.chopper_enabled
		# The chopper is over the middle, on the first-row platform at x = 0 on the pillar's axis, where a lean moves it least: two jumps from the first side, a bridge and a jump from the second. The ordinary pad (3,1) always favoured one side. `headless_run`'s Broadside section runs both.
	broadside.chopper_cell = Vector2i(config.columns / 2, 0)
	# 3.4 m of air, which is what "pushed apart" means and is inside a running jump.
	broadside.jumps = Jumps.ALONG_ROWS
	out.append(broadside)

	var hollow := _make(
		&"hollow", "Hollow Centre", 10.0, Gaps.HOLLOW, Bridges.OUTER,
		"Nothing in the middle. The cannon has to reach for you and it will."
	)
	hollow.stiffness_scale = 0.88
		# Only the middle column goes, so each half is a U round the hole: the outer column's two platforms and the bridge between them, and an inner platform off each (a 0.9 m jump, the nearest floor to the tube). The bridge is the half's only way between its rows and falls with either platform, so losing an outer one strands the inner. The missing column is 12.3 m of air no jump reaches. `headless_run`'s Hollow section runs a side round its U.
	hollow.jumps = Jumps.ALONG_ROWS
	out.append(hollow)

	out.append(_terraces())
	out.append(_ring())
	out.append(_watchtowers())

	return out


## The bowl: seven columns by three, rising from the middle out, so every step is one jump.
##
## Each platform stands [constant LEVEL_RISE] above the one nearer the middle, so the high ground is a staircase of leaning platforms and the rim sees the whole bowl. The middle cell is left out for the cannon's mouth; rows are a jump apart as on Two Islands.
static func _terraces() -> Layout:
	var layout := _make(
		&"terraces", "Terraces", 9.0, Gaps.NONE, Bridges.NONE,
		"A bowl of stepped islands. Every step is one jump, and the rim sees everything."
	)
	layout.columns = 7
	layout.rows = 3
	layout.row_pitch_scale = 0.51
	layout.jumps = Jumps.ALONG_ROWS | Jumps.ACROSS_ROWS | Jumps.DIAGONALS

	for row in range(3):
		for column in range(7):
			if column == 3 and row == 1:
				continue

			var level := mini(maxi(absi(column - 3), 2 * absi(row - 1)), MAX_LEVEL)
			layout.custom.append(make_cell(column, row, KIND_PLATFORM, level))

	return layout


## The ring: a loop of platforms round the cannon, bridged down both sides, with a tower at each corner reached by a ramp.
##
## Top and bottom are platforms a jump apart stepped down toward the middle, the sides are columns joined by bridges, and each tower is reached only by the climbing bridge. Every piece is a deck of the same model, so a bridge falls with either end.
static func _ring() -> Layout:
	var layout := _make(
		&"ring", "The Ring", 9.0, Gaps.NONE, Bridges.OUTER,
		"A loop round the cannon. Ramps climb to the corner towers, and every bridge goes with its ends."
	)
	layout.columns = 7
	layout.rows = 5
	layout.pitch_scale = 0.95
	layout.row_pitch_scale = 0.8
	layout.jumps = Jumps.ALONG_ROWS
	var last_row := 4
	var last_column := 6

	for row in range(5):
		for column in range(7):
			var on_side := column == 0 or column == last_column
			var on_end := row == 0 or row == last_row

			if not on_side and not on_end:
				continue

			if on_side and on_end:
				layout.custom.append(make_cell(column, row, KIND_TOWER, 3))
				continue

			var level := 0

			if on_end:
				level = 2 if column == 1 or column == last_column - 1 else 1

			layout.custom.append(make_cell(column, row, KIND_PLATFORM, level))

	for row in range(4):
		for column in [0, last_column]:
			layout.custom.append(make_cell(column, row, KIND_BRIDGE))

	return layout


## Two ramps up to a tower and two down from it, on each side of a field of platforms.
##
## The towers (outer columns, three levels up) are the high ground; the ramps are the only crossing between the rows, so a way up is also someone's way down.
static func _watchtowers() -> Layout:
	var layout := _make(
		&"watchtowers", "Watchtowers", 9.0, Gaps.NONE, Bridges.NONE,
		"The rows meet only at two towers. Climb the ramp, hold the high ground, and mind the drop."
	)
	layout.columns = 5
	layout.rows = 3
	layout.row_pitch_scale = 0.8
	layout.jumps = Jumps.ALONG_ROWS

	for row in [0, 2]:
		for column in range(5):
			layout.custom.append(make_cell(column, row))

	for column in [0, 4]:
		layout.custom.append(make_cell(column, 1, KIND_TOWER, 3))

	for row in range(2):
		for column in [0, 4]:
			layout.custom.append(make_cell(column, row, KIND_BRIDGE))

	return layout


## Every pair of platforms a player could try to jump between, as (a, b, kind).
##
## [param a] and [param b] index [param cells], the field's own order; [param kind] is one [enum Jumps]. Derived, never declared: a layout names the kinds and this turns them into pairs off the same cell list the field is built from.
static func pairs(cells: Array[Vector3i]) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var at: Dictionary = {}
	var bridged: Dictionary = {}

	for i in range(cells.size()):
		var cell := cells[i]

		if kind_of(cell) == KIND_BRIDGE:
			bridged[Vector2i(cell.x, cell.y)] = true
		else:
			at[Vector2i(cell.x, cell.y)] = i

	for key: Vector2i in at:
		var i: int = at[key]

		# Along the row: the nearest platform to the right, however far.
		for column in range(key.x + 1, 64):
			var other := Vector2i(column, key.y)

			if at.has(other):
				var kind := Jumps.ALONG_ROWS if column == key.x + 1 else Jumps.ACROSS_HOLES
				out.append(Vector3i(i, at[other], kind))
				break

		# Straight across to the next row, unless a bridge already joins them.
		var across := Vector2i(key.x, key.y + 1)

		if at.has(across) and not bridged.has(key):
			out.append(Vector3i(i, at[across], Jumps.ACROSS_ROWS))

		for side in [-1, 1]:
			var diagonal := Vector2i(key.x + side, key.y + 1)

			if at.has(diagonal):
				out.append(Vector3i(i, at[diagonal], Jumps.DIAGONALS))

	return out


## Which island each cell is on: a number per entry of [param cells], the same for every two cells a player can get between on foot.
##
## A bridge joins the platforms it rests on; a pair from [method pairs] joins them only if [param jumps] names its kind. An island is numbered by its first cell, so the numbers follow the field's order and two machines agree.
static func islands(cells: Array[Vector3i], jumps: int) -> PackedInt32Array:
	var root := PackedInt32Array()
	var at: Dictionary = {}

	for i in range(cells.size()):
		root.append(i)

		if kind_of(cells[i]) != KIND_BRIDGE:
			at[Vector2i(cells[i].x, cells[i].y)] = i

	var joins: Array[Vector2i] = []

	for i in range(cells.size()):
		var cell := cells[i]

		if kind_of(cell) == KIND_BRIDGE:
			for row in [cell.y, cell.y + 1]:
				var end: int = at.get(Vector2i(cell.x, row), -1)

				if end >= 0:
					joins.append(Vector2i(i, end))

	for pair: Vector3i in pairs(cells):
		if (jumps & pair.z) != 0:
			joins.append(Vector2i(pair.x, pair.y))

	for join in joins:
		var a := _island_of(root, join.x)
		var b := _island_of(root, join.y)
		root[maxi(a, b)] = mini(a, b)

	var out := PackedInt32Array()

	for i in range(cells.size()):
		out.append(_island_of(root, i))

	return out


static func _island_of(root: PackedInt32Array, i: int) -> int:
	while root[i] != i:
		i = root[i]

	return i


## The layout for a round, drawn by weight from [param stream].
##
## Weighted, because the full field is the baseline the variants vary. [param keep] is `(id: StringName) -> bool`, the server's maps.yml; a filter that would leave nothing draws from every allowed layout.
static func pick(config: ScConfig, stream: DotRandomStream, keep: Callable = Callable()) -> Layout:
	var layouts := allowed(config)

	if keep.is_valid():
		var kept: Array[Layout] = []

		for layout in layouts:
			if bool(keep.call(layout.id)):
				kept.append(layout)

		if not kept.is_empty():
			layouts = kept

	if not config.vary_layout or layouts.is_empty():
		return layouts[0] if not layouts.is_empty() else _make(
			&"full", "Full Deck", 1.0, Gaps.NONE, Bridges.OUTER, ""
		)

	var weights := PackedFloat32Array()

	for layout in layouts:
		weights.append(maxf(layout.weight, 0.0))

	var index := stream.next_weighted(weights)
	return layouts[clampi(index, 0, layouts.size() - 1)]


## The layouts this server may draw: [method all], narrowed by [member ScConfig.layout_ids].
##
## An unknown id is dropped with a warning, and a list naming nothing falls back to the whole catalogue: a server with no field is not a server.
static func allowed(config: ScConfig) -> Array[Layout]:
	var every := all(config)

	if config.layout_ids.is_empty():
		return every

	var out: Array[Layout] = []

	for layout in every:
		if config.layout_ids.has(String(layout.id)):
			out.append(layout)

	if out.is_empty():
		DotLog.warn(CHANNEL, "layout_ids names nothing this game has", {
			"asked_for": ", ".join(config.layout_ids),
			"have": ", ".join(ids(config)),
		})
		return every

	for id: Variant in workshop:
		out.append(workshop[id] as Layout)

	return out


## One layout by id, or null. What a console command and the suite use.
static func by_id(config: ScConfig, id: StringName) -> Layout:
	for layout in all(config):
		if layout.id == id:
			return layout

	return null


## Every layout's id, for a console command's completion and for a log line.
static func ids(config: ScConfig) -> PackedStringArray:
	var out := PackedStringArray()

	for layout in all(config):
		out.append(String(layout.id))

	return out


## The layouts a server plays, as a dot-map catalogue: what `map`, `maps`, `mapinfo` and the ballot list.
##
## A def per layout, with the layout's id. `scene_path` names the one scene only to satisfy the def's validation and nothing loads it (see `ScMapSession`). [method allowed] decides which are offered.
static func catalogue(config: ScConfig) -> DotMapCatalogue:
	var out := DotMapCatalogue.new()

	for layout in allowed(config):
		var def := DotMapDef.new()
		def.id = layout.id
		def.display_name = layout.display_name
		def.description = layout.blurb
		def.kind = &"layout"
		def.scene_path = ScPaths.rebase("res://game/sc.tscn")
		var added := out.add(def)

		if not added.ok:
			push_error("A layout could not be listed as a map: %s" % added.error.message)

	return out
