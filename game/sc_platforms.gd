extends Node3D

const ScConfig := preload("sc_config.gd")
const ScLayouts := preload("sc_layouts.gd")
const ScTextures := preload("sc_textures.gd")
const ScPaths := preload("sc_paths.gd")

## The field of platforms, and the one model that decides how all of them move.
##
## [b]A platform is a slab balanced on a single pillar, and everything this game is about
## comes out of that.[/b] Walk to the edge of one and it leans toward you; run to the edge
## and it leans faster; put a boulder on the far corner and it leans away. Past sixteen
## degrees it comes off the pillar and takes whoever is on it down forty metres.
##
## [b]It is not a rigid body, and that is the decision this file exists to defend.[/b] A
## slab genuinely balanced on a thin cylinder in Godot's solver is a body in permanent
## marginal contact: it jitters at rest, it is decided by contact-point ordering, and it
## is not reproducible across two machines — which in a game where the platform under your
## feet is the whole of the first objective means a client and a server that disagree
## about whether you are standing on anything. dot-props has the same finding from the
## other end and refuses to predict a crate for it.
##
## So a platform is an [AnimatableBody3D] driven by a torsion spring this file integrates:
## a lean, a lean velocity, a sink and a sink velocity, four floats that are a pure
## function of the loads on it. It is deterministic, it costs nothing, it replicates in
## four numbers, and a client can be told exactly what the server decided rather than
## asked to agree with it.
##
## [codeblock]
## platforms.begin_loads()
## for player in players: platforms.add_load(index, offset, mass, speed)
## platforms.step(delta)                       # integrate, collapse, fall
## var lift := platforms.lift_at(index, x, z)  # what the surface did under a player
## [/codeblock]

const CHANNEL := "sc.platforms"

## What a platform is doing.
enum State {
	## On its pillar. The ordinary case.
	STANDING,
	## Off its pillar and on the way down, with whoever was on it.
	FALLING,
	## Gone. The pillar may still be standing; see [member ScConfig.pillar_falls_with_platform].
	GONE,
}

## What an impact did, so a caller can decide what to draw and what to say.
enum Impact {
	## It missed, or the platform was already gone.
	NONE,
	## It leaned it. The ordinary case, and most of the round.
	WOBBLE,
	## It leaned it past its own collapse angle.
	TOPPLED,
	## It was big enough to take the platform out in one hit, whatever its health.
	SHATTERED,
}

## A platform came off its pillar. [param why] is one of the WHY_* constants.
signal collapsed(index: int, why: StringName)

## A platform finished falling and has been taken away.
signal removed(index: int)

## Something landed on a platform hard enough to matter.
signal struck(index: int, at: Vector3, impulse: float, outcome: Impact)

const WHY_LEAN := &"lean"        ## Somebody stood in the wrong place for too long.
const WHY_BROKEN := &"broken"    ## Enough impacts added up.
const WHY_SHATTERED := &"shattered"  ## One impact was simply too big.
const WHY_ROUND := &"round"      ## The round asked for the field to be cleared.
const WHY_UNSUPPORTED := &"unsupported"  ## A bridge lost a platform it was resting on.

## Radians per second a falling platform tips over at, on top of the lean it fell with.
##
## [b]It keeps turning on the way down, and that is what sells it.[/b] A slab that fell
## flat would read as a lift descending; one that rotates as it goes reads as something
## that has come off the thing holding it up, which is what happened.
const FALL_TIP_RATE := 0.85

## Metres per second squared a falling platform accelerates downward at, as a fraction of
## the world's gravity. Below one, because a forty-metre slab is not a stone.
const FALL_GRAVITY_SCALE := 0.62

## One platform: where it is, what it is doing, and the four numbers it is doing it with.
##
## An inner class rather than parallel arrays. The arrays would be faster and this is a
## dozen entries; what they would cost is the one thing that matters in a file like this,
## which is being able to read one platform's whole state in one place.
class Deck extends RefCounted:
	## Where the pillar's axis meets the deck plane. The platform pivots about this.
	var centre := Vector3.ZERO

	## Which cell of the layout grid this came from, for logs and for the HUD.
	var column: int = 0
	var row: int = 0

	## Whether this is a walkway between two rows rather than a platform on a pillar.
	var is_bridge: bool = false

	## A tower is a platform that is narrower and stands higher. See [constant ScLayouts.KIND_TOWER].
	var is_tower: bool = false

	## Steps above the ordinary deck height, [constant ScLayouts.LEVEL_RISE] metres each.
	var level: int = 0

	## For a bridge: the platforms it rests on, at its row's end and at the next row's, as
	## deck indices. `-1` where there is none, and a bridge missing either is a free spring.
	var supports := Vector2i(-1, -1)

	## And the world Z of the two lips it rests on, in the same order.
	var lips := Vector2.ZERO

	## Half the platform's side, in metres. Its footprint is a square about [member centre].
	var half: float = 5.25

	var state: int = State.STANDING

	## Radians of lean. `x` tips the +X edge down, `y` tips the +Z edge down.
	var lean := Vector2.ZERO

	## Radians per second.
	var lean_velocity := Vector2.ZERO

	## Metres the whole slab has been pressed down by, and how fast.
	var sink: float = 0.0
	var sink_velocity: float = 0.0

	## What is left of it, in kilogram metres per second of impact.
	var health: float = 1.0

	## Seconds it has been falling.
	var falling_for: float = 0.0

	## The torque the loads on it are applying this tick, in kilogram metres.
	var load_torque := Vector2.ZERO

	## And their total weight, which is what presses it down.
	var load_mass: float = 0.0

	## The body a player's motor actually sweeps against.
	var body: AnimatableBody3D = null

	## The column under it. Kept so it can be taken away with the platform, or not.
	var pillar: StaticBody3D = null

	## The plane normal last time [method ScPlatforms.step] ran, for the carry.
	var previous_normal := Vector3.UP

	## And the height of the pivot, which sink moves.
	var previous_sink: float = 0.0

	func is_standing() -> bool:
		return state == State.STANDING

	## Whether this is a bridge carried by two platforms rather than a spring of its own.
	func is_rested() -> bool:
		return is_bridge and supports.x >= 0 and supports.y >= 0

	## Whether this platform can still be stood on at all.
	func is_live() -> bool:
		return state != State.GONE

	## The surface's normal, from the lean.
	##
	## [b]A lean of `+x` puts the +X edge DOWN, and the normal therefore tips toward +X —
	## which is the opposite of what it looks like it should be.[/b] Work it through on the
	## plane rather than on the picture: a plane through the pivot with normal
	## `(sin t, cos t, 0)` puts a point at `+x` at `y = pivot - x * tan(t)`, which is below
	## the pivot. The first version wrote `-sin`, every lean came out leaning away from
	## whatever was standing on it, and the suite caught it as the far side of a platform
	## being the low one. Nothing about it errors: the platform still tips, still collapses
	## and still carries people — in the wrong direction.
	func normal() -> Vector3:
		return Vector3(sin(lean.x), 1.0, sin(lean.y)).normalized()

	## How far this platform's surface is from level, in radians.
	func tilt() -> float:
		return lean.length()

	func describe() -> Dictionary:
		return {
			"cell": "%d,%d" % [column, row],
			"state": State.keys()[state],
			"lean": "%.1f deg" % rad_to_deg(tilt()),
			"health": "%.0f%%" % (health * 100.0),
		}


@export var config: ScConfig = null

## Whether this instance decides anything. A client mirrors what it is told instead.
##
## [b]A client runs no model at all.[/b] It is handed a lean and a sink twice a second and
## interpolates between them, which is the same bargain dot-props makes about a crate and
## is made for a stronger reason: a platform is the floor, and a floor that disagrees
## between two machines is a player falling through one.
@export var authoritative: bool = true

## Every platform, in layout order. The index is what the wire carries.
var decks: Array[Deck] = []

## The world's gravity, handed in by the game so this file reads one number rather than
## asking a physics space it does not own.
var gravity: float = 20.0

## How slippery the decks are this round. See [member ScConfig.platform_grip].
var grip: float = 1.0

## Multiplies [member ScConfig.platform_stiffness] for a whole round. A special turns it
## down; a layout can too.
var stiffness_scale: float = 1.0

## Node instance id -> deck index, so a motor's `ground_id` answers in one lookup.
##
## [b]The reverse index the motor needs, kept here rather than searched for.[/b]
## `DotFpsState.ground_id` is the instance id of whatever is underfoot and it is read once
## per player per tick; walking every deck to match it would be the same scan dot-entity
## exists to remove, in miniature.
var _by_body: Dictionary = {}

var _physics: DotPhysicsLayout = null

## What the configured column spacing was multiplied by for this field.
var _pitch_scale: float = 1.0

## What the configured row spacing is multiplied by. See [member ScLayouts.Layout.row_pitch_scale].
var _row_pitch_scale: float = 1.0

## How far the field is moved along the rows, in row pitches. See [member ScLayouts.Layout.row_shift].
var _row_shift: float = 0.0

## The grid this field was built on. Zero means the config's, which is every layout that
## does not carry a grid of its own.
var _columns: int = 0
var _rows: int = 0

## `(kind, level)` of every non-bridge cell, so a bridge can be sized and set at the height
## of the two pieces it joins.
var _cell_info: Dictionary = {}


## Kenney's survival kit (CC0, licence beside the file): one fence section is 0.5 m wide.
static var RAIL_MODEL := ScPaths.rebase("res://assets/kenney/survival/fence.glb")
static var RAIL_ATLAS := ScPaths.rebase("res://assets/kenney/survival/Textures/colormap.png")
const RAIL_WIDTH := 0.5
const RAIL_SCALE := 3.0


func _ready() -> void:
	if config == null:
		config = ScConfig.new()


## Lays out the field a layout describes. What the authority calls.
func build(layout: ScLayouts.Layout, physics: DotPhysicsLayout = null) -> void:
	build_cells(
		layout.cells(config), layout.pitch_scale, layout.stiffness_scale, physics,
		layout.row_pitch_scale, layout.row_shift,
		layout.field_columns(config), layout.field_rows(config)
	)

	DotLog.info(CHANNEL, "the platforms are up", {
		"layout": String(layout.id),
		"platforms": decks.size(),
		"deck": "%.0f m" % config.deck_height,
	})


## Lays out an explicit list of cells: `(column, row, is_bridge)`.
##
## [b]A list rather than a layout id, and that is what makes the client's field
## STRUCTURALLY the same as the server's rather than probably the same.[/b] Every platform
## is addressed on the wire by its index in this array, so the two ends have to agree about
## the order — and if the client derived it from a catalogue of its own, a build that was
## one layout behind would put its platform seven somewhere else and every snapshot after
## that would move the wrong floor. Thirty-odd bytes once a round buys the whole class of
## bug.
##
## [b]Cleared first, because building is also REBUILDING.[/b] Called twice without it the
## previous round's platforms stand inside this round's, and a player walks on a floor they
## cannot see and falls through the one they can.
func build_cells(
	cells: Array[Vector3i],
	p_pitch_scale: float,
	p_stiffness_scale: float,
	physics: DotPhysicsLayout = null,
	p_row_pitch_scale: float = 1.0,
	p_row_shift: float = 0.0,
	p_columns: int = 0,
	p_rows: int = 0
) -> void:
	clear()

	_columns = p_columns
	_rows = p_rows
	_cell_info.clear()

	for info: Vector3i in cells:
		if not ScLayouts.is_bridge_cell(info):
			_cell_info[Vector2i(info.x, info.y)] = Vector2i(
				ScLayouts.kind_of(info), ScLayouts.level_of(info)
			)

	_physics = physics
	_pitch_scale = maxf(p_pitch_scale, 0.05)
	_row_pitch_scale = maxf(p_row_pitch_scale, 0.05)
	_row_shift = p_row_shift
	stiffness_scale = p_stiffness_scale
	grip = config.platform_grip

	for cell: Vector3i in cells:
		# `cell.z` carries the kind and the level (see `ScLayouts.make_cell`). A bridge is the only
		# thing joining two rows, so it is built from the same description with a different
		# footprint rather than from a second code path.
		_build_deck(
			cell.x, cell.y, ScLayouts.kind_of(cell) == ScLayouts.KIND_BRIDGE,
			ScLayouts.kind_of(cell) == ScLayouts.KIND_TOWER, ScLayouts.level_of(cell)
		)

	_rest_bridges()


## Sets every bridge down on the two platforms it joins.
##
## [b]A bridge was a spring of its own until 2026-09-24, pivoting on a pillar it does not
## have.[/b] The Spine's blurb calls the walkways "the steady ground", and the model made
## them the least steady thing on the map: a bridge is longer than a platform is wide, so a
## runner at its end had a longer lever than one at a platform's edge — 9.7 degrees against
## 7.9 on The Spine, measured — and two runners at one end took a bridge down while the
## platform next to it held at 15.7. It leaned in mid-air about its own middle, so where it
## met a platform's lip there was a step whenever the two leaned differently.
##
## Now it is a plank on two lips. Its pitch is the line between the two lips' heights, its
## roll is theirs, a load on it is carried by the two platforms in proportion to where it
## stands, and it goes when either of them does. A bridge with a platform missing at one
## end is still built as a spring, which no layout here does (see `_has_bridge`).
func _rest_bridges() -> void:
	var at: Dictionary = {}

	for i in range(decks.size()):
		if not decks[i].is_bridge:
			at[Vector2i(decks[i].column, decks[i].row)] = i

	for deck in decks:
		if not deck.is_bridge:
			continue

		var near: int = at.get(Vector2i(deck.column, deck.row), -1)
		var far: int = at.get(Vector2i(deck.column, deck.row + 1), -1)

		if near < 0 or far < 0:
			continue

		deck.supports = Vector2i(near, far)
		deck.lips = Vector2(
			decks[near].centre.z + _footprint(decks[near]).y,
			decks[far].centre.z - _footprint(decks[far]).y
		)


## Columns and rows of the grid the field was built on, which a layout may set for itself.
func field_columns() -> int:
	return _columns if _columns > 0 else config.columns


func field_rows() -> int:
	return _rows if _rows > 0 else config.rows


## How wide a piece of this kind is, as a fraction of an ordinary platform.
static func _scale_of(kind: int) -> float:
	return ScLayouts.TOWER_SCALE if kind == ScLayouts.KIND_TOWER else 1.0


## The cells this field was built from, in index order. What the wire carries.
func cells() -> Array[Vector3i]:
	var out: Array[Vector3i] = []

	for deck in decks:
		var kind := ScLayouts.KIND_PLATFORM

		if deck.is_bridge:
			kind = ScLayouts.KIND_BRIDGE
		elif deck.is_tower:
			kind = ScLayouts.KIND_TOWER

		out.append(ScLayouts.make_cell(deck.column, deck.row, kind, deck.level))

	return out


## Everything a previous [method build] put here.
##
## [b]Taken out of the tree at once and freed at the end of the frame, which is not the
## same as either half alone.[/b] `remove_child` is what stops two fields existing at the
## same height for the rest of the frame — two floors, one of which a body spawned in that
## frame can land on. The deferred free is what stops a node being destroyed in the middle
## of somebody else's iteration: a round ends inside the netcode's own loop over replicated
## entities, because the first behaviour through a tick is what runs the whole world, so an
## immediate `free()` here pulls identities out from under `DotNetManager.server_tick`
## while it is walking them. It reports that as "Nonexistent function can_simulate in base
## previously freed", once per entity, per tick, for ever.
func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	decks.clear()
	_by_body.clear()


func count() -> int:
	return decks.size()


func deck_at(index: int) -> Deck:
	return decks[index] if index >= 0 and index < decks.size() else null


## How many platforms are still on their pillars.
func standing_count() -> int:
	var total := 0

	for deck in decks:
		if deck.is_standing():
			total += 1

	return total


func _build_deck(
	column: int, row: int, is_bridge: bool, is_tower: bool = false, level: int = 0
) -> void:
	var deck := Deck.new()
	deck.column = column
	deck.row = row
	deck.is_bridge = is_bridge
	deck.is_tower = is_tower
	deck.level = level

	var pitch := config.column_pitch * _pitch_scale
	var span := float(field_columns() - 1) * pitch
	var row_pitch := config.row_pitch * _row_pitch_scale
	var row_span := float(field_rows() - 1) * row_pitch
	# Where row zero is: centred on the tube, then moved by the layout's shift.
	var row_origin := -row_span * 0.5 + _row_shift * row_pitch

	deck.centre = Vector3(
		float(column) * pitch - span * 0.5,
		config.deck_height + float(level) * ScLayouts.LEVEL_RISE,
		float(row) * row_pitch + row_origin
	)

	var side := config.platform_size * (ScLayouts.TOWER_SCALE if is_tower else 1.0)
	var size := Vector3(side, config.platform_thickness, side)

	if is_bridge:
		# A bridge sits between two rows and spans the gap. Narrow across and long along,
		# so it is a walkway rather than a second platform: a place you cross, not a place
		# you hold. It is centred between the rows, which is why its `row` is a half step.
		var near_info: Vector2i = _cell_info.get(Vector2i(column, row), Vector2i.ZERO)
		var far_info: Vector2i = _cell_info.get(Vector2i(column, row + 1), Vector2i.ZERO)
		var near_half := config.platform_size * 0.5 * _scale_of(near_info.x)
		var far_half := config.platform_size * 0.5 * _scale_of(far_info.x)
		var near_edge := float(row) * row_pitch + row_origin + near_half
		var far_edge := float(row + 1) * row_pitch + row_origin - far_half
		deck.centre.z = (near_edge + far_edge) * 0.5
		# Midway in height too. The pitch is taken from the two lips' surfaces, so this is
		# only where its sink starts from, and a ramp that starts at zero reads as flat.
		deck.centre.y = config.deck_height + float(near_info.y + far_info.y) * 0.5 \
				* ScLayouts.LEVEL_RISE
		size.x = config.platform_size * 0.55
		# Never shorter than a pace. A layout that pulls the rows in to a jump apart has no
		# use for a bridge and should declare none, but a box with no length is not one.
		size.z = maxf(far_edge - near_edge - 0.6, 0.5)

	deck.half = maxf(size.x, size.z) * 0.5
	deck.health = 1.0

	var body := AnimatableBody3D.new()
	body.name = "Deck_%d_%d%s" % [column, row, "_bridge" if is_bridge else ""]
	body.position = deck.centre
	# [b]On, and it is what carries a crate.[/b] Without it Godot teleports the body and
	# every rigid body resting on it is left behind in mid-air for a frame and then falls
	# through. A player is carried by [method lift_at] instead, because a swept capsule is
	# not a physics body and never was.
	body.sync_to_physics = true

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	# Hung below the pivot, so the pivot is the SURFACE rather than the middle of the
	# slab. Every offset in this file is measured on the plane a player stands on, and a
	# pivot in the middle of a 0.6 m slab would put every one of them 30 cm out.
	collider.position = Vector3(0.0, -size.y * 0.5, 0.0)
	body.add_child(collider)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = collider.position
	mesh.material_override = ScTextures.surface(ScTextures.Role.DECK)
	body.add_child(mesh)

	_build_rim(body, size)

	if is_tower:
		_build_rail(body, size)

	_classify(body, &"world")
	add_child(body)
	deck.body = body

	if not is_bridge:
		deck.pillar = _build_pillar(deck.centre)

	deck.previous_normal = Vector3.UP
	deck.previous_sink = 0.0

	decks.append(deck)
	_by_body[body.get_instance_id()] = decks.size() - 1


## Kenney's survival-kit fence round a tower's edge, so the high ground reads as a lookout
## and a runner sees where the deck stops from the ramp below.
##
## [b]Mesh only and a child of the deck body[/b], so it leans and falls with the piece and
## adds no collider to catch a sliding crate. The model is loaded by path through
## [method ScPaths.rebase] and repainted from the atlas by hand, because an imported GLB
## names its texture by an absolute path a delivered pack does not have (see
## `ScPropBody._paint`, the same repair).
func _build_rail(body: AnimatableBody3D, size: Vector3) -> void:
	var scene := load(ScPaths.rebase(RAIL_MODEL)) as PackedScene

	if scene == null:
		DotLog.warn(CHANNEL, "the tower rail model would not load", {"path": RAIL_MODEL})
		return

	var atlas := load(ScPaths.rebase(RAIL_ATLAS)) as Texture2D
	var step := RAIL_WIDTH * RAIL_SCALE
	var half := size.x * 0.5 - 0.3
	var count := maxi(int(floor(size.x / step)), 1)
	var rail := Node3D.new()
	rail.name = "Rail"
	body.add_child(rail)

	for side in range(4):
		var turn := float(side) * PI * 0.5

		for k in range(count):
			var along := (float(k) + 0.5 - float(count) * 0.5) * step
			var piece := scene.instantiate() as Node3D

			if piece == null:
				return

			piece.scale = Vector3.ONE * RAIL_SCALE
			piece.rotation.y = turn
			piece.position = Vector3(along, 0.0, half).rotated(Vector3.UP, turn)
			rail.add_child(piece)

			if atlas != null:
				for node in piece.find_children("*", "MeshInstance3D", true, false):
					var mesh := node as MeshInstance3D
					var material := mesh.get_active_material(0) as BaseMaterial3D

					if material != null and material.albedo_texture == null:
						var fixed: BaseMaterial3D = material.duplicate()
						fixed.albedo_texture = atlas
						mesh.set_surface_override_material(0, fixed)


## A coloured band around a platform's edge, so a player can see where it stops.
##
## [b]Found by looking at what a player actually sees, and it is the one readability
## problem this map has.[/b] Every platform is at the same height, so from eye level the
## neighbouring ones are edge-on — and with a gap of under a metre between them the whole
## field reads as one continuous floor stretching to the horizon. A player walking toward
## what looks like more floor falls down a gap they had no way to see. The grid does not
## help: it is the same grid on both platforms and it runs straight across the join.
##
## A band in the cannon's colour does, because it is the one colour nothing else a player
## stands on wears, and because an EDGE seen edge-on is still a line. It carries no
## collider: it is drawn a hair proud of the surface so it cannot become a lip that catches
## a sliding crate.
func _build_rim(body: AnimatableBody3D, size: Vector3) -> void:
	var band := 0.55
	# [b]A hair ABOVE zero, because the pivot is the SURFACE.[/b] Every offset in this file
	# is measured on the plane a player stands on and the slab hangs below it, so a rim
	# placed relative to the slab's middle is a rim inside the slab — which is what the first
	# one was, and the screenshot that was supposed to prove it looked identical to the one
	# before it.
	var lift := 0.005
	var material := ScTextures.surface(ScTextures.Role.CANNON)

	var edges: Array[Vector3] = [
		Vector3(0.0, 0.0, size.z * 0.5 - band * 0.5),
		Vector3(0.0, 0.0, -size.z * 0.5 + band * 0.5),
		Vector3(size.x * 0.5 - band * 0.5, 0.0, 0.0),
		Vector3(-size.x * 0.5 + band * 0.5, 0.0, 0.0),
	]

	for i in range(edges.size()):
		var along_x := i >= 2
		var mesh := MeshInstance3D.new()
		mesh.name = "Rim%d" % i
		var box := BoxMesh.new()
		box.size = Vector3(
			band if along_x else size.x,
			0.06,
			size.z if along_x else band
		)
		mesh.mesh = box
		mesh.position = edges[i] + Vector3(0.0, lift, 0.0)
		mesh.material_override = material
		body.add_child(mesh)


## The single column, which is the whole reason the platform above it is unstable.
##
## [b]A bridge gets none.[/b] It spans a gap and is held at both ends by the platforms it
## joins — which is why a bridge is the steady place to stand and also the place everybody
## else is heading for.
func _build_pillar(at: Vector3) -> StaticBody3D:
	var height := at.y - config.platform_thickness

	var body := StaticBody3D.new()
	body.name = "Pillar"
	body.position = Vector3(at.x, at.y - config.platform_thickness - height * 0.5, at.z)

	var shape := CylinderShape3D.new()
	shape.radius = config.pillar_radius
	shape.height = height

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	body.add_child(collider)

	var column := CylinderMesh.new()
	column.top_radius = config.pillar_radius
	column.bottom_radius = config.pillar_radius
	column.height = height
	column.radial_segments = 12

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = column
	mesh.material_override = ScTextures.surface(ScTextures.Role.PILLAR)
	body.add_child(mesh)

	# Its own layer, which a person does not collide with: see `ScGame._build_physics`.
	_classify(body, &"pillar")
	add_child(body)
	return body


## Puts a body on a named collision layer, and says so when it cannot.
##
## [b]Checked rather than discarded, because five games in this family assigned a layout
## and applied it to nothing.[/b] Everything stayed on layer one masking layer one, which
## works until two things that should pass through each other do not. A refused classify
## swallowed into `var _put :=` is the exact shape of that bug.
func _classify(body: Node, layer_id: StringName) -> void:
	if _physics == null:
		return

	var applied := _physics.apply_to(body, layer_id)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a body could not be put on its collision layer", {
			"body": body.name, "layer": String(layer_id), "why": applied.error.message,
		})


# --- Asking about a platform ------------------------------------------------

## Which platform's footprint this point is over, or -1.
##
## Square footprints and a linear scan. A dozen platforms is a dozen comparisons and this
## runs a few hundred times a tick; a spatial index here would be a structure to keep in
## step with a field that is rebuilt every round.
func index_at(x: float, z: float) -> int:
	for i in range(decks.size()):
		var deck := decks[i]

		if not deck.is_live():
			continue

		var size := _footprint(deck)

		if absf(x - deck.centre.x) <= size.x and absf(z - deck.centre.z) <= size.y:
			return i

	return -1


## Which platform this collider belongs to, or -1. What `DotFpsState.ground_id` answers.
func index_of_body(instance_id: int) -> int:
	return int(_by_body.get(instance_id, -1))


## Half the platform's footprint on each axis, in metres.
func _footprint(deck: Deck) -> Vector2:
	var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D

	if collider == null:
		return Vector2(deck.half, deck.half)

	var box := collider.shape as BoxShape3D
	return Vector2(box.size.x, box.size.z) * 0.5 if box != null else Vector2(deck.half, deck.half)


## The air between two platforms along the line from one's middle to the other's, in metres.
##
## Returns (where that line leaves [param from], the air, where it lands on [param to]),
## each measured from [param from]'s middle. [b]Along the line a runner takes, and not the
## shortest distance between the two footprints[/b]: two chequerboard squares are 2.1 m
## apart corner to corner and 2.8 m apart along the diagonal a player actually runs, and a
## jump sized by the first is one that lands on the second's edge.
func clear_air(from: int, to: int) -> Vector3:
	var a := deck_at(from)
	var b := deck_at(to)

	if a == null or b == null:
		return Vector3.ZERO

	var line := Vector2(b.centre.x - a.centre.x, b.centre.z - a.centre.z)
	var length := line.length()

	if length < 0.001:
		return Vector3.ZERO

	var leave := _leaves_at(_footprint(a), line / length)
	var land := length - _leaves_at(_footprint(b), -line / length)

	return Vector3(leave, maxf(land - leave, 0.0), land)


## How close any platform still up comes to a vertical line through (x, z), in metres.
##
## What the cannon's throat is measured with: a platform whose footprint is over the tube's
## mouth is a platform every shot goes up into.
func clearance_from(x: float, z: float) -> float:
	var nearest := INF

	for deck in decks:
		if not deck.is_live():
			continue

		var half := _footprint(deck)
		var dx := maxf(absf(x - deck.centre.x) - half.x, 0.0)
		var dz := maxf(absf(z - deck.centre.z) - half.y, 0.0)
		nearest = minf(nearest, Vector2(dx, dz).length())

	return nearest


## How far along [param direction] from a box's middle its edge is.
static func _leaves_at(half: Vector2, direction: Vector2) -> float:
	var along_x := half.x / absf(direction.x) if absf(direction.x) > 0.0001 else INF
	var along_z := half.y / absf(direction.y) if absf(direction.y) > 0.0001 else INF
	return minf(along_x, along_z)


## Where the surface of platform [param index] is at a world XZ, in metres.
##
## The plane through the pivot with the platform's own normal. Exact rather than
## approximate, because it is what decides whether somebody is standing on it and what
## the platform moved under them.
func surface_y(index: int, x: float, z: float) -> float:
	var deck := deck_at(index)
	return _surface_y_of(deck, x, z) if deck != null else 0.0


func _surface_y_of(deck: Deck, x: float, z: float) -> float:
	var normal := deck.normal()

	if absf(normal.y) < 0.001:
		return deck.centre.y + deck.sink

	var offset := Vector2(x - deck.centre.x, z - deck.centre.z)
	return deck.centre.y + deck.sink - (normal.x * offset.x + normal.z * offset.y) / normal.y


## Whether a point is standing on this platform: over its footprint and near its surface.
##
## [param reach] is how far above the surface still counts, which is a capsule's worth for
## a player and a prop's half height for a prop.
func is_on(index: int, at: Vector3, reach: float = 1.4) -> bool:
	var deck := deck_at(index)

	if deck == null or not deck.is_live():
		return false

	var surface := _surface_y_of(deck, at.x, at.z)
	return at.y >= surface - 0.6 and at.y <= surface + reach


# --- The model --------------------------------------------------------------

## Clears the loads gathered for the previous tick. Call before the first [method add_load].
func begin_loads() -> void:
	for deck in decks:
		deck.load_torque = Vector2.ZERO
		deck.load_mass = 0.0


## Puts a weight on a platform at a world position.
##
## [param motion] is how fast the load is moving over the deck, in metres per second. It is
## the walk key: see [member ScConfig.platform_motion_gain]. A prop passes zero and is
## simply a weight; a player sprinting across the edge is worth three of themselves.
func add_load(index: int, at: Vector3, kilos: float, motion: float = 0.0) -> void:
	var deck := deck_at(index)

	if deck == null or not deck.is_standing():
		return

	# A bridge's weight goes to the lips it rests on, shared by where along it the load is:
	# the whole of it at one end, half each in the middle. That is what makes the middle of
	# a bridge the steadiest place on the map and its ends a platform's edge by proxy.
	if deck.is_rested():
		var share := _share_along(deck, at.z)
		deck.load_mass += kilos
		add_load(deck.supports.x, Vector3(at.x, at.y, deck.lips.x), kilos * (1.0 - share), motion)
		add_load(deck.supports.y, Vector3(at.x, at.y, deck.lips.y), kilos * share, motion)
		return

	var offset := Vector2(at.x - deck.centre.x, at.z - deck.centre.z)
	var gain := 1.0

	if config.platform_motion_gain > 0.0 and config.run_speed > 0.0:
		gain += config.platform_motion_gain * clampf(motion / config.run_speed, 0.0, 1.6)

	deck.load_torque += offset * kilos * gain * config.platform_load_gain
	deck.load_mass += kilos


## One tick of every platform. The only thing that moves one.
##
## [b]Semi-implicit, and explicit Euler is wrong here in a way that takes a while to
## see.[/b] Integrating the position from the old velocity adds energy at every step, so a
## spring that should settle grows instead — a platform that should have stopped wobbling
## keeps going and eventually throws itself off its own pillar with nobody standing on it.
## zee-dot-weapons paid for exactly this in its recoil spring; the fix is one line, which
## is to advance the velocity first and the angle from the NEW velocity.
func step(delta: float) -> void:
	if not authoritative or delta <= 0.0:
		return

	for i in range(decks.size()):
		var deck := decks[i]

		# Afterwards, because a bridge lies wherever its two platforms have just put it.
		if deck.is_rested() and deck.is_standing():
			continue

		match deck.state:
			State.STANDING:
				_step_standing(i, deck, delta)
			State.FALLING:
				_step_falling(i, deck, delta)

	for i in range(decks.size()):
		var deck := decks[i]

		if deck.is_rested() and deck.is_standing():
			_step_rested(i, deck, delta)


## How far along a rested bridge a world Z is, from its near lip (0) to its far one (1).
func _share_along(deck: Deck, z: float) -> float:
	var length := deck.lips.y - deck.lips.x
	return clampf((z - deck.lips.x) / length, 0.0, 1.0) if absf(length) > 0.001 else 0.5


## Lays a bridge on its two lips. See [method _rest_bridges].
func _step_rested(index: int, deck: Deck, delta: float) -> void:
	var near := decks[deck.supports.x]
	var far := decks[deck.supports.y]

	if not near.is_standing() or not far.is_standing():
		_collapse(index, deck, WHY_UNSUPPORTED)
		return

	deck.previous_normal = deck.normal()
	deck.previous_sink = deck.sink

	var was_lean := deck.lean
	var was_sink := deck.sink
	var high := _surface_y_of(near, deck.centre.x, deck.lips.x)
	var low := _surface_y_of(far, deck.centre.x, deck.lips.y)
	var length := maxf(deck.lips.y - deck.lips.x, 0.001)
	var middle := (deck.lips.x + deck.lips.y) * 0.5

	# The plane's Z slope is sin(lean.y) (see [method Deck.normal]); the roll is the two
	# lips' own, averaged, because each end lies across a lip tilted by its platform's.
	var pitch := clampf((high - low) / length, -1.0, 1.0)
	deck.lean = Vector2((near.lean.x + far.lean.x) * 0.5, asin(pitch))
	deck.sink = (high + low) * 0.5 - deck.centre.y + pitch * (middle - deck.centre.z)
	deck.lean_velocity = (deck.lean - was_lean) / delta
	deck.sink_velocity = (deck.sink - was_sink) / delta

	_draw(deck)


func _step_standing(index: int, deck: Deck, delta: float) -> void:
	deck.previous_normal = deck.normal()
	deck.previous_sink = deck.sink

	var stiffness := config.platform_stiffness * maxf(stiffness_scale, 0.01)
	var inertia := maxf(config.platform_inertia, 1.0)

	# Torque from the loads, a spring pulling it level, and a damper. The three terms are
	# the whole model, and every knob an operator has moves exactly one of them.
	var acceleration := deck.load_torque / inertia
	acceleration -= deck.lean * stiffness
	acceleration -= deck.lean_velocity * config.platform_damping

	deck.lean_velocity += acceleration * delta
	deck.lean += deck.lean_velocity * delta

	# The sink is the same spring on one axis, and it is what a player feels as the
	# platform taking their weight. It is cosmetic in that nothing is decided by it — but
	# a platform that never moves vertically reads as scenery, and this map needs every
	# platform to read as something balanced.
	var rest := -deck.load_mass / maxf(config.platform_inertia, 1.0)
	var sink_acceleration := (rest - deck.sink) * stiffness * 2.4
	sink_acceleration -= deck.sink_velocity * config.platform_damping * 2.0
	deck.sink_velocity += sink_acceleration * delta
	deck.sink += deck.sink_velocity * delta
	deck.sink = clampf(deck.sink, -0.6, 0.6)

	if deck.lean.length() >= config.platform_collapse_lean:
		_collapse(index, deck, WHY_LEAN)
		return

	_draw(deck)


func _step_falling(index: int, deck: Deck, delta: float) -> void:
	deck.falling_for += delta

	# It keeps turning as it goes, about the axis it was already leaning on. A slab that
	# fell flat would read as a lift going down.
	var axis := deck.lean.normalized() if deck.lean.length() > 0.001 else Vector2(1.0, 0.0)
	deck.lean += axis * FALL_TIP_RATE * delta
	deck.sink_velocity -= gravity * FALL_GRAVITY_SCALE * delta
	deck.sink += deck.sink_velocity * delta

	_draw(deck)

	if deck.falling_for < config.platform_fall_seconds:
		return

	deck.state = State.GONE

	if deck.body != null and is_instance_valid(deck.body):
		_by_body.erase(deck.body.get_instance_id())
		deck.body.queue_free()
		deck.body = null

	if config.pillar_falls_with_platform and deck.pillar != null:
		deck.pillar.queue_free()
		deck.pillar = null

	removed.emit(index)


## Writes a deck's four numbers onto the body a player actually collides with.
##
## [b]The basis is built from the normal rather than from two Euler angles.[/b] Composing
## rotations about X and Z gives a different surface depending on which order they are
## applied in, and the order that happens to be right at five degrees is visibly wrong at
## fifteen — which is exactly the range this game lives in. A plane has one normal and one
## basis that carries UP onto it.
func _draw(deck: Deck) -> void:
	# [b]In the tree as well as valid.[/b] A field cleared between two ticks leaves its
	# bodies out of the tree and queued for freeing for the rest of the frame, and writing a
	# transform onto one of those is an engine error with a backtrace attached. See
	# [method ScPropNet._drawable].
	if deck.body == null or not is_instance_valid(deck.body) or not deck.body.is_inside_tree():
		return

	var normal := deck.normal()
	var axis := Vector3.UP.cross(normal)
	var basis := Basis.IDENTITY

	# [b]The near-parallel case first, and the general formula produces NaN in it.[/b] Two
	# vectors with a zero cross product have no rotation axis, so the axis-angle spelling
	# divides by zero and fills the basis with NaN — and a NaN transform draws nothing and
	# collides with nothing, silently. zee-dot-weapons found the same trap in a weapon's
	# orientation, where it presented as a gun that had failed to load.
	if axis.length() > 0.0001:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(normal))

	deck.body.global_transform = Transform3D(
		basis, deck.centre + Vector3(0.0, deck.sink, 0.0)
	)


## Metres the surface moved under a point since the last [method step].
##
## [b]The same offset on both sides of the subtraction, which is the whole trick.[/b] What
## is wanted is what the PLATFORM did, not what the player did: measuring the surface under
## where they are now against the surface under where they were last tick would fold their
## own walking into the answer and carry them twice.
func lift_at(index: int, x: float, z: float) -> float:
	var deck := deck_at(index)

	if deck == null or not deck.is_live():
		return 0.0

	var offset := Vector2(x - deck.centre.x, z - deck.centre.z)

	var before := deck.previous_normal
	var now := deck.normal()

	if absf(before.y) < 0.001 or absf(now.y) < 0.001:
		return 0.0

	var was := deck.previous_sink - (before.x * offset.x + before.z * offset.y) / before.y
	var is_now := deck.sink - (now.x * offset.x + now.z * offset.y) / now.y

	return is_now - was


# --- Being hit --------------------------------------------------------------

## Something landed on a platform. Returns what it did.
##
## [param kilos] and [param speed] are the falling body's mass and how fast it arrived;
## everything below is decided from their product, because that is the momentum the
## platform has to absorb and it is the one number that separates a crate from a monolith.
func report_impact(index: int, kilos: float, speed: float, at: Vector3) -> Impact:
	var deck := deck_at(index)

	if deck == null or not deck.is_standing():
		return Impact.NONE

	var impulse := absf(kilos) * absf(speed)

	if impulse <= 0.0:
		return Impact.NONE

	var offset := Vector2(at.x - deck.centre.x, at.z - deck.centre.z)

	# Dead centre is the one case with no lever arm and it still has to do something, or a
	# monolith dropped exactly on the pillar would be absorbed by a platform that cannot
	# tell it happened. A minimum arm of a quarter of the platform is a hit that lands
	# "somewhere", which is the honest answer when the geometry has none.
	if offset.length() < deck.half * 0.25:
		var direction := offset.normalized() if offset.length() > 0.01 else Vector2(1.0, 0.0)
		offset = direction * deck.half * 0.25

	if deck.is_rested():
		# A bridge has no spring to lean, so the blow goes to the two lips it rests on, shared
		# as a weight is. Its own health below still takes the damage.
		var share := _share_along(deck, at.z)
		var ends := [deck.supports.x, deck.supports.y]
		var lips := [deck.lips.x, deck.lips.y]
		var weights := [1.0 - share, share]

		for end in range(2):
			var support: Deck = decks[int(ends[end])]

			if not support.is_standing():
				continue

			var arm := Vector2(at.x - support.centre.x, float(lips[end]) - support.centre.z)
			support.lean_velocity += arm * impulse * float(weights[end]) \
				* config.platform_impact_gain / maxf(config.platform_inertia, 1.0)
			support.sink_velocity -= impulse * float(weights[end]) \
				/ maxf(config.platform_inertia * 4.0, 1.0)
	else:
		deck.lean_velocity += offset * impulse * config.platform_impact_gain \
			/ maxf(config.platform_inertia, 1.0)

		# And it is pressed down, so a heavy landing is visible even on a platform that was
		# hit square.
		deck.sink_velocity -= impulse / maxf(config.platform_inertia * 4.0, 1.0)

	var outcome := Impact.WOBBLE

	if impulse >= config.platform_shatter_impulse:
		# [b]Gone, whatever its health.[/b] This is the tier-four case and it is the one
		# thing in the round nobody can do anything about except not be there.
		outcome = Impact.SHATTERED
		struck.emit(index, at, impulse, outcome)
		_collapse(index, deck, WHY_SHATTERED)
		return outcome

	deck.health -= impulse / maxf(config.platform_toughness, 1.0)

	if deck.health <= 0.0:
		outcome = Impact.TOPPLED
		struck.emit(index, at, impulse, outcome)
		_collapse(index, deck, WHY_BROKEN)
		return outcome

	struck.emit(index, at, impulse, outcome)
	return outcome


## Leans every platform at once, which is what an earthquake is.
##
## [param strength] is in radians per second of lean velocity, in a direction drawn from
## [param stream] so that two peers running the same seed shake the same way.
func shake_all(stream: DotRandomStream, strength: float) -> void:
	for deck in decks:
		if not deck.is_standing():
			continue

		var angle := stream.next_range_f(0.0, TAU)
		deck.lean_velocity += Vector2(cos(angle), sin(angle)) * strength


## Takes a platform off its pillar by hand: a round ending, an admin, a test.
func collapse(index: int, why: StringName = WHY_ROUND) -> bool:
	var deck := deck_at(index)

	if deck == null or not deck.is_standing():
		return false

	_collapse(index, deck, why)
	return true


func _collapse(index: int, deck: Deck, why: StringName) -> void:
	deck.state = State.FALLING
	deck.falling_for = 0.0
	deck.sink_velocity = minf(deck.sink_velocity, -0.4)
	deck.health = 0.0

	# [b]The collider goes now, not when the slab has finished falling.[/b] A platform on
	# its way down is not somewhere to stand: a player left riding it would be carried
	# forty metres by a floor that is already gone from every other point of view, and
	# would land alive on the map's own kill plane. What they get instead is the floor
	# disappearing from under them, which is what a collapse is.
	var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D if deck.body != null else null

	if collider != null:
		collider.disabled = true

	if deck.body != null and is_instance_valid(deck.body):
		_by_body.erase(deck.body.get_instance_id())

	collapsed.emit(index, why)
	DotLog.debug(CHANNEL, "a platform came off its pillar", {
		"index": index, "cell": "%d,%d" % [deck.column, deck.row], "why": String(why),
	})


# --- Mirroring --------------------------------------------------------------

## Adopts a platform's state from the wire. Client side; see [ScPlatformNet].
##
## [b]The state is adopted and the collider follows it.[/b] A client that was told a
## platform is falling has to take the floor away at the same moment the server did, or a
## player who is being told they are falling is standing on something.
func adopt(index: int, lean: Vector2, sink: float, state: int) -> void:
	var deck := deck_at(index)

	if deck == null:
		return

	deck.previous_normal = deck.normal()
	deck.previous_sink = deck.sink

	deck.lean = lean
	deck.sink = sink

	if state != deck.state:
		deck.state = state

		var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D if deck.body != null else null

		if collider != null:
			collider.disabled = state != State.STANDING

		# [b]Out of the reverse index the moment it stops STANDING, not when it is gone.[/b]
		# That index is what a motor's `ground_id` is resolved through, so a platform left in
		# it while it falls is one a client still believes somebody is standing on — and the
		# server took it out the instant it came off its pillar. The two ends disagreeing
		# about what is underfoot is the one thing this whole model exists to prevent.
		if state != State.STANDING and deck.body != null and is_instance_valid(deck.body):
			_by_body.erase(deck.body.get_instance_id())

		if state == State.GONE and deck.body != null and is_instance_valid(deck.body):
			deck.body.queue_free()
			deck.body = null

	_draw(deck)


# --- Reporting --------------------------------------------------------------

func describe() -> Dictionary:
	var standing := 0
	var falling := 0
	var worst := 0.0

	for deck in decks:
		match deck.state:
			State.STANDING:
				standing += 1
				worst = maxf(worst, deck.tilt())
			State.FALLING:
				falling += 1

	return {
		"platforms": decks.size(),
		"standing": standing,
		"falling": falling,
		"worst_lean": "%.1f deg" % rad_to_deg(worst),
		"grip": "%.2f" % grip,
		"pitch": "%.2f" % _pitch_scale,
		"row_pitch": "%.2f" % _row_pitch_scale,
		"row_shift": "%.2f" % _row_shift,
		"stiffness": "%.2f" % (config.platform_stiffness * stiffness_scale),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["platforms"])

	for i in range(decks.size()):
		var facts := decks[i].describe()
		lines.append("  %2d  %-7s %-9s lean %-9s hp %s" % [
			i, facts["cell"], facts["state"], facts["lean"], facts["health"],
		])

	return lines
