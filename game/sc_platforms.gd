extends "sc_platforms_physics.gd"


## The field of platforms, and the one model that decides how all of them move.
##
## A slab on one pillar that leans toward load and past sixteen degrees falls. Not a rigid body: a slab on a thin cylinder jitters in Godot's solver and is not reproducible across machines, so it is an [AnimatableBody3D] driven by a torsion spring integrated here, four floats that replicate cheaply and let a client be told rather than asked to agree. Per tick: `begin_loads`, `add_load` per player, `step`, then `lift_at` for what the surface did under a rider.


## Kenney's survival kit (CC0, licence beside the file): one fence section is 0.5 m wide.
static var RAIL_MODEL := ScPaths.rebase("res://assets/kenney/survival/fence.glb")
static var RAIL_ATLAS := ScPaths.rebase("res://assets/kenney/survival/Textures/colormap.png")
const RAIL_WIDTH := 0.5
const RAIL_SCALE := 3.0
## Which edge of a tower a side of its rail stands on: a quarter turn each, from +Z.
const RAIL_SIDE_PLUS_Z := 0
const RAIL_SIDE_MINUS_Z := 2


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
## A list, not a layout id: platforms are addressed on the wire by index, so a client deriving the order from its own catalogue would move the wrong floor. Cleared first, because building is also rebuilding and last round's platforms would stand inside this round's.
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
## A plank on two lips: pitch and roll follow the lips' heights, load is shared by position, and it goes when either platform does. As its own spring it pivoted on a pillar it does not have, so a runner at its end had a longer lever than at a platform edge and it leaned in mid-air. `_has_bridge` covers a platform missing at one end.
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

		# A ramp arriving at a tower opens the rail where it lands: the near end is left from
		# its +Z edge, the far end from its -Z edge. See [method _open_rail].
		var span := _footprint(deck).x
		_open_rail(decks[near], RAIL_SIDE_PLUS_Z, deck.centre.x, span)
		_open_rail(decks[far], RAIL_SIDE_MINUS_Z, deck.centre.x, span)


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
## Removed from the tree at once (two fields at one height for the frame would let a spawned body land on the old one) and freed deferred, because a round ends inside the netcode's loop over entities and an immediate `free()` pulls them out from under `DotNetManager.server_tick`.
func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	decks.clear()
	_by_body.clear()


func count() -> int:
	return decks.size()


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
		# On: it is what carries a crate, since otherwise resting bodies are left in mid-air. Players are carried by [method lift_at]; a swept capsule is not a physics body.
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


## Kenney's survival-kit fence round a tower's edge, so the high ground reads as a lookout.
##
## Mesh only and a child of the deck body, so it leans and falls with the piece and adds no collider. Loaded by path via [method ScPaths.rebase] and repainted by hand, because an imported GLB names its texture by an absolute path a delivered pack lacks (see `ScPropBody._paint`).
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
			piece.set_meta(&"rail_side", side)
			piece.set_meta(&"rail_along", along)
			rail.add_child(piece)

			if atlas != null:
				for node in piece.find_children("*", "MeshInstance3D", true, false):
					var mesh := node as MeshInstance3D
					var material := mesh.get_active_material(0) as BaseMaterial3D

					if material != null and material.albedo_texture == null:
						var fixed: BaseMaterial3D = material.duplicate()
						fixed.albedo_texture = atlas
						mesh.set_surface_override_material(0, fixed)


## Takes the rail off the stretch of [param deck]'s [param side] where a ramp arrives.
##
## A fence across a ramp mouth reads as "no way up". Pieces overlapping the bridge's width ([param half_width] each side of [param x]) are left out; both ends build from the same cells.
func _open_rail(deck: Deck, side: int, x: float, half_width: float) -> void:
	if not deck.is_tower or deck.body == null:
		return

	var rail := deck.body.get_node_or_null(^"Rail")

	if rail == null:
		return

	var reach := RAIL_WIDTH * RAIL_SCALE * 0.5
	# A piece's offset is rotated with its side, so along the -Z edge +along points to -X.
	var sign := 1.0 if side == RAIL_SIDE_PLUS_Z else -1.0

	for piece in rail.get_children():
		if int(piece.get_meta(&"rail_side", -1)) != side:
			continue

		var at := deck.centre.x + sign * float(piece.get_meta(&"rail_along", 0.0))

		if absf(at - x) - reach < half_width:
			rail.remove_child(piece)
			piece.queue_free()


## How many rail pieces tower [param index] still has on [param side]; -1 for no rail.
func rail_pieces(index: int, side: int) -> int:
	var deck := deck_at(index)

	if deck == null or deck.body == null:
		return -1

	var rail := deck.body.get_node_or_null(^"Rail")

	if rail == null:
		return -1

	var count := 0

	for piece in rail.get_children():
		if int(piece.get_meta(&"rail_side", -1)) == side:
			count += 1

	return count


## A coloured band around a platform's edge, so a player can see where it stops.
##
## Every platform is at one height, so from eye level neighbours are edge-on and the field reads as one continuous floor. The cannon's colour is worn by nothing else a player stands on. No collider, and a hair proud of the surface so a sliding crate cannot catch on it.
func _build_rim(body: AnimatableBody3D, size: Vector3) -> void:
	var band := 0.55
		# A hair ABOVE zero, because the pivot is the SURFACE: offsets are measured on the plane a player stands on and the slab hangs below it.
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
## A bridge gets none: it is held at both ends by the platforms it joins.
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
## Checked rather than discarded: five games assigned a layout and applied it to nothing, and a refused classify swallowed into `var _put :=` is that bug.
func _classify(body: Node, layer_id: StringName) -> void:
	if _physics == null:
		return

	var applied := _physics.apply_to(body, layer_id)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a body could not be put on its collision layer", {
			"body": body.name, "layer": String(layer_id), "why": applied.error.message,
		})


## Which platform's footprint this point is over, or -1.
##
## Square footprints and a linear scan: a dozen comparisons, and an index would have to track a field rebuilt every round.
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


## The air between two platforms along the line from one's middle to the other's, in metres.
##
## Returns (where that line leaves [param from], the air, where it lands on [param to]), each from [param from]'s middle. Along the runner's line, not the shortest distance: chequerboard squares are 2.1 m apart corner to corner but 2.8 m along the diagonal, and a jump sized by the first lands on an edge.
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
## What the cannon's throat is measured with.
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
## The plane through the pivot with the platform's normal; exact, because it decides who is standing on it and what the platform moved under them.
func surface_y(index: int, x: float, z: float) -> float:
	var deck := deck_at(index)
	return _surface_y_of(deck, x, z) if deck != null else 0.0


## Whether a point is standing on this platform: over its footprint and near its surface.
##
## [param reach] is how far above the surface still counts: a capsule's worth for a player, a prop's half height for a prop.
func is_on(index: int, at: Vector3, reach: float = 1.4) -> bool:
	var deck := deck_at(index)

	if deck == null or not deck.is_live():
		return false

	var surface := _surface_y_of(deck, at.x, at.z)
	return at.y >= surface - 0.6 and at.y <= surface + reach
