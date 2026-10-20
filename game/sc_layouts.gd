extends RefCounted

const ScConfig := preload("sc_config.gd")
const ScPaths := preload("sc_paths.gd")

## What shape the platform field takes this round, as a catalogue of documents.
##
## [b]The same platforms in a different arrangement is a different round to play, and it
## costs nothing.[/b] This map's geometry is a grid of squares on pillars; knocking a
## column out of it, taking the bridges away, or pushing the rows apart changes where a
## player can go and therefore where the cannon can corner them — which is the whole of
## the first objective. A round that always looked the same would be a round players
## solve once.
##
## [b]A document rather than a scene each, for the family's usual reason and one of its
## own.[/b] A layout is six numbers, so the whole catalogue travels in the HELLO as one
## id and a client rebuilds the identical field from it. A layout that was a `.tscn` would
## be content to deliver, to version and to keep in step across two machines, in exchange
## for nothing this cannot express.

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
## [b]A declaration, and the suite holds the geometry to it in both directions.[/b] A kind
## a layout names has to be inside the jump a running player actually makes — measured
## with the dip their own run puts in the lip they leave from — and a kind it does not name
## has to be OUTSIDE it, because "nobody is crossing" is as much a promise as "every jump is
## a diagonal". Every pair is read off the built field rather than written down, so moving a
## platform moves the jump with it. See [method pairs] and `headless_run`'s reach section.
##
## A pair joined by a bridge is walked, not jumped, and is none of these.
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
## [b]Two bits of kind and three of level, in the one integer that was a bridge flag.[/b] A
## cell is (column, row, z), and z was 0 for a platform and 1 for a bridge, so every
## layout written before the pieces below reads the same: kind 0 and level 0. The level is
## in steps of [constant LEVEL_RISE] above the deck height, and a bridge's own level is
## whatever its two ends make it, so it is never written for one.
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

	## The (column, row) the first chopper is parked in the middle of, or (-1, -1) for the
	## ordinary pad off to one side ([code]ScArena.chopper_pad[/code]).
	##
	## [b]For a layout whose blurb puts the chopper somewhere.[/b] Server-side only: the
	## machine is replicated where it comes to rest, so this never travels.
	var chopper_cell := Vector2i(-1, -1)

	## Whether [member chopper_cell] names a BRIDGE rather than a platform: the one leaving
	## row `y` at column `x` for the next row, the chopper parked on its middle.
	##
	## [b]For the Airfield, whose pad is the far bridge.[/b] A bridge is the steadiest ground
	## on the field and it rests on a platform of each row, so the machine on it is reached
	## along either row, and it goes when either of them does. Server-side only, like
	## [member chopper_cell].
	var chopper_on_bridge: bool = false

	## What the configured column spacing is multiplied by.
	##
	## Above one is a map of islands with jumps that have to be meant; below one is a map
	## where a collapsing platform takes its neighbour's footing with it.
	var pitch_scale: float = 1.0

	## What the configured ROW spacing is multiplied by.
	##
	## [b]The rows are a bridge apart on every layout but one.[/b] At the configured 24 m
	## there is 13.5 m of air between the rows, which is the point of a bridge; a layout
	## that wants the rows to be a JUMP apart pulls them in with this, and says so in
	## [member jumps].
	var row_pitch_scale: float = 1.0

	## How far the whole field is moved along the rows, as a fraction of the row pitch.
	##
	## [b]For the one layout whose rows are a jump apart.[/b] Centred, the gap between two
	## rows is where the cannon's tube stands, and a gap a player can jump is a gap a
	## monolith cannot get up through — so the chequerboard moves its field half a row over
	## and puts the tube in the hole where its missing middle platform would be.
	var row_shift: float = 0.0

	## Which jumps this layout means a player to make. A mask of [enum Jumps].
	var jumps: int = 0

	## What the configured platform stiffness is multiplied by.
	##
	## Below one is a wobblier field. It is the one property of a layout a player feels
	## before they can see it, so a layout that uses it says so in its name.
	var stiffness_scale: float = 1.0

	## A line for the HUD when the round begins, so a player knows what they are looking at.
	var blurb: String = ""

	## How many columns and rows this layout is, or 0 for what [member ScConfig.columns] and
	## [member ScConfig.rows] say. [b]The bigger maps carry their own[/b], because a
	## server's `sc_columns` is the size of the ordinary field and a ring is a ring at seven by
	## five whatever it is.
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
	## [b]One description, and the field, the spawns, the cannon's target list and the
	## client's copy are all derived from it.[/b] This family has shipped the same list
	## twice and watched the copies drift more than once.
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
				# The middle third, rounded so a five-column field loses its centre one —
				# which until 2026-10-03 this said and did not do: `column < columns / 3 or
				# column > columns - 1 - columns / 3` keeps 0 and 4 of five, so the field was
				# two strips of two. The count is kept to the field's own parity so the hole
				# is centred on the tube, and at least one column is left at each end.
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

		# [b]Never over the cannon's mouth, and The Spine put one there from the day it was
		# written.[/b] The tube stands in the middle of the field with its muzzle three
		# metres under the decks, and on a field with an odd number of columns and an even
		# number of rows the middle column's middle bridge is exactly on top of it. Every
		# shot on that layout went up into its underside — forty in forty, measured — and
		# the cannon on one round in nine did nothing but shake a bridge. The suite's throat
		# section is what holds this now, for every layout rather than this one.
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
	# [b]The rows pulled in to a jump apart, and until 2026-09-23 there was no jump on it at
	# all.[/b] The diagonals of a chequerboard run from one ROW to the other, and the rows
	# were 13.5 m of air apart on every layout — so this was five islands under a blurb
	# promising diagonals, and the 0.88 column scale that sat here under a comment saying it
	# "widened" the diagonals narrowed a spacing no diagonal crosses. At 0.525 of the row
	# pitch a diagonal is 2.8 m of air along the line a runner takes, inside the 3.2 m a
	# runner reaches from the lip their own run has dipped, and the next platform along a
	# row is 12.3 m away, which nothing reaches. So the only way anywhere is a diagonal,
	# which is what the blurb always said. Columns at the ordinary spacing, because a corner
	# is where the jump leaves from and 0.9 m between corners is the part that reads.
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
	# [b]Four islands until 2026-09-27, under a blurb that says two.[/b] The rows were 13.5 m
	# of air apart with no bridge, so each end of each row was an island of its own — two
	# platforms nobody could leave, four of them, measured with [method islands] — and two
	# sides started on two of them and never met. The rows are pulled in to a jump apart now
	# and the columns in a little, so each end is ONE island of four platforms crossed every
	# way: 1.8 m of air along a row, 1.7 m across one and 2.6 m on a diagonal, against the
	# 2.9 m a runner reaches off a corner their own run has dipped. Between the two islands
	# is the missing middle column, 14.1 m of air that no jump reaches — and the cannon's tube
	# stands in it, 7 m from the nearest edge, so nothing needs moving half a row over.
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
	# [b]And the walkways only became steady on 2026-09-24.[/b] Until then a bridge was a
	# spring of its own on a pillar it does not have, longer than a platform is wide, so a
	# runner at its end leaned it 9.7 degrees against 7.9 at a platform's edge, two runners
	# took it down while the platform beside it held, and it met each lip with up to 0.85 m
	# of step. It rests on the two lips it joins now (`ScPlatforms._rest_bridges`): one
	# runner at its end tilts it 3.0, its middle not at all, and it falls only with a
	# platform it is resting on — so crowding a bridge is what brings the two platforms
	# under it down, which is the "everybody knows it" half of the blurb.
	#
	# Jumps along the rows, 0.90 m of air against a 3.97 m run (the reach section). Between
	# the rows everything is walked: four bridges, the middle column's left out over the
	# tube, and 13.5 m of air there that no jump reaches.
	spine.jumps = Jumps.ALONG_ROWS
	out.append(spine)

	var airfield := _make(
		&"airfield", "Airfield", 13.0, Gaps.NONE, Bridges.OUTER,
		"There is a chopper on the pad. Somebody is going to take it."
	)
	airfield.with_chopper = config.chopper_enabled
	# [b]The pad is the far bridge, and until 2026-10-13 it was the second side's
	# doorstep.[/b] The chopper was parked on the ordinary pad, a third of the way out along
	# a 45 degree line, which on the full field is (3,1): two jumps from where the second
	# side starts and four jumps and a bridge from the first, so "somebody" was always the
	# same somebody (Broadside had the same pad until 2026-09-30). On the last column's
	# bridge it is at the end of BOTH rows: the first side runs its own row, four jumps, the
	# second its own, three, and they arrive at the two ends of one walkway with the machine
	# in the middle of it. A bridge falls with either platform it rests on, so the cannon
	# taking (4,0) or (4,1) takes the pad and the chopper with it. `headless_run`'s Airfield
	# section runs both sides there.
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
	# [b]And the chopper is over the middle, which until 2026-09-30 it was not.[/b] It was
	# parked on the ordinary pad, the Airfield's, a third of the way out along a 45 degree
	# line — which on this field is (3,1), two jumps from where the second side starts and
	# four jumps and a bridge from the first, so "somebody is going to take it" was always
	# the same somebody. On the middle column's first-row platform it is at x = 0, on the
	# pillar's axis where a lean moves it least, two jumps from the first side and a bridge
	# and a jump from the second. `headless_run`'s Broadside section runs both there.
	broadside.chopper_cell = Vector2i(config.columns / 2, 0)
	# 3.4 m of air, which is what "pushed apart" means and is inside a running jump.
	broadside.jumps = Jumps.ALONG_ROWS
	out.append(broadside)

	var hollow := _make(
		&"hollow", "Hollow Centre", 10.0, Gaps.HOLLOW, Bridges.OUTER,
		"Nothing in the middle. The cannon has to reach for you and it will."
	)
	hollow.stiffness_scale = 0.88
	# [b]Two strips of two until 2026-10-03, under a rule whose comment said one column
	# goes.[/b] It took three, so each side had a platform, a bridge and a platform, and
	# nothing to do about a shot but walk across to the other one. With only the middle
	# column gone each half is a U round the hole: the outer column's two platforms and the
	# bridge between them, and an inner platform off each, a 0.9 m jump along the row and
	# the nearest floor to the tube. The bridge is the half's only way between its rows,
	# and it falls with either platform it rests on — so losing an outer platform strands
	# the inner one beyond it. Between the halves is the missing column, 12.3 m of air no
	# jump reaches, with the tube in the middle of it. `headless_run`'s Hollow section runs
	# a side round its U and at the other one.
	hollow.jumps = Jumps.ALONG_ROWS
	out.append(hollow)

	out.append(_terraces())
	out.append(_ring())
	out.append(_watchtowers())

	return out


## The bowl: seven columns by three, rising from the middle out, so every step is one jump.
##
## [b]Stepped islands, and the first layout whose platforms are not all at one height.[/b]
## Each platform stands [constant LEVEL_RISE] above the one nearer the middle, so getting to
## the high ground is a run of jumps UP a staircase of platforms that all lean toward
## whoever is on them, and the rim sees the whole bowl. The middle cell is left out for the
## cannon's mouth. Rows are a jump apart, as on Two Islands, so any neighbour is one jump.
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


## The ring: a loop of platforms round the cannon, bridged down both sides, with a tower
## at each corner reached by a ramp.
##
## [b]Rings, bridges, ramps and towers in one field.[/b] The top and bottom of the loop are
## platforms a jump apart and stepped down toward the middle; each side is a column of
## platforms joined by bridges; and each corner is a small tower on a tall pillar that is
## reached only by the bridge that climbs to it, which is a ramp. Every piece is a
## deck of the same model, so every piece comes off its pillar when it is leant on enough,
## and a bridge falls with either end.
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
## [b]The towers are the high ground, and getting to one is a walk up a ramp that is
## also somebody else's way down.[/b] The towers stand on the outer columns between the two
## rows, three levels up; the bridge up to one and the bridge down from it are slopes.
## Nothing else joins the rows, so the ramps are the only crossing and a tower is the one
## place that holds both of them.
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
## [param a] and [param b] are indices into [param cells], which is the field's own order,
## and [param kind] is one [enum Jumps] value. [b]Derived, never declared[/b]: a layout names
## the KINDS it means, and this is what turns the kinds into pairs off the same cell list the
## field is built from.
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


## Which island each cell is on: a number per entry of [param cells], the same for every
## two cells a player can get between on foot.
##
## [b]Walked or jumped, and only the jumps a layout means.[/b] A bridge joins the two
## platforms it rests on; a pair [method pairs] finds joins them only if [param jumps] names
## its kind — the suite's reach section holds every meant jump inside a running jump and
## every other one outside even a flat one, which is what makes a declaration a fact about
## where a person can go. An island is numbered by the first cell on it, so the numbers are
## the field's own order and two machines agree about them.
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
## [b]Weighted rather than uniform, because the full field is the one a player should see
## most.[/b] A round that is a variant every time has no baseline to be a variant of.
##
## [param keep] is `(id: StringName) -> bool`, the server's maps.yml: a layout it leaves out is
## never drawn. Unset, or a filter that would leave nothing, draws from every allowed layout.
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
## An id that names nothing is dropped with a warning rather than refused, and a list that
## names nothing at all falls back to the whole catalogue — a server with no field is not a
## server, and the operator who typed the list is better served by a log line than by one.
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


## The layouts a server plays, as a dot-map catalogue: what `map`, `maps`, `mapinfo` and the
## ballot list.
##
## [b]A def per layout, and the id is the layout's.[/b] A layout is this game's map, picked
## per round on one scene, so `scene_path` names that scene only to satisfy the def's
## validation and nothing loads it (see `ScMapSession`). Which of them are offered is
## [method allowed]'s, so an operator who narrowed `layout_ids` narrows the catalogue too.
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
