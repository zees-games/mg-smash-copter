extends Node3D

const ScConfig := preload("sc_config.gd")
const ScTextures := preload("sc_textures.gd")
const ScLayouts := preload("sc_layouts.gd")

## Everything in the world that is not a platform: the sky, the floor a player lands on, the tube in the middle, and the corners the round is finished in.
##
## Built in code with prototype textures: a player reads height, distance and tilt off a one-metre grid better than off art. The floor is drawn even though nobody survives it: forty metres of grid going past is a drop they can count, and it tells a faller they are falling rather than that the game stopped.

const CHANNEL := "sc.arena"

## Metres of floor beyond the outermost platform, so the map has a horizon.
const FLOOR_MARGIN := 46.0

## How tall the tube in the middle is, as a fraction of the deck height.
##
## Below one on purpose: the muzzle is under the platforms, so a prop climbs past the decks; a taller tube would be a wall down the middle.
const TUBE_HEIGHT_FRACTION := 0.86

## The tube's radius, in metres. Wide enough to read as a mouth from across the map.
const TUBE_RADIUS := 3.1

## Metres above the top of the tube that a prop is actually created at.
##
## Clear of the rim: a body overlapping the tube's collider is thrown sideways by the solver, so shots went out flat instead of up.
const MUZZLE_CLEARANCE := 2.6

## How far every platform has to stay from the line the cannon fires up, in metres.
##
## The widest thing the tube throws (a 3.4 x 1.4 x 3.0 m monolith, tumbling) sweeps 2.4 m, and the muzzle is 3 m under the decks, so a closer edge is one the shot goes up into. The suite's throat section measures every layout against this.
const THROAT_CLEARANCE := 2.5

## How wide a catwalk between a corner pad and the middle of the showdown ring is.
const CATWALK_WIDTH := 3.4

## How high the lip around a corner pad and the ring is.
##
## Low, a kerb and not cover: falling stays the map's one rule, and the lip only stops sliding off something you were not looking at.
const CORNER_LIP := 0.34

## How wide the band around a pad's edge is, in metres.
##
## Same answer as the platforms: a pad 60 m up against a flat sky has no horizon, so its edge seen from standing height is a one-pixel line of the same brightness.
const PAD_BAND := 0.6
const LIP_HEIGHT := 0.55

@export var config: ScConfig = null

## The collision layout everything here is classified against.
var physics: DotPhysicsLayout = null

## Where the showdown happens. Built once and left standing, because it is visible from
## the platforms and a player who can see where the round ends plays the first half
## differently.
var _showdown: Node3D = null

var _floor_body: StaticBody3D = null


func _ready() -> void:
	if config == null:
		config = ScConfig.new()


## Lays the world out. Called again every round, which is why it clears first.
func build() -> void:
	_clear()
	_build_light()
	_build_floor()
	_build_tube()
	_build_showdown()

	DotLog.info(CHANNEL, "the arena is up", describe())


## Out of the tree at once, freed at the end of the frame. See [method ScPlatforms.clear]
## for why neither half of that is enough on its own.
func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	_showdown = null
	_floor_body = null



## The sun and the sky, as a dot-lighting document.
##
## Built here, not left to the host scene: with no [DirectionalLight3D] and [WorldEnvironment] a scene is FLAT (every surface its own albedo), so the depth a player judges a forty-metre drop by is absent. The sun is high on purpose, since a low one shades every deck by its neighbour and hides the tilt. Angles follow dot-lighting's source convention (negative pitch is a sun in the sky); fog distances are source units (metres / 0.01905), haze from 120 m.
const DAYLIGHT := {
	"sun": {
		"pitch_src": -58.0,
		"yaw_src": -35.0,
		"colour": [1.0, 0.93, 0.80],
		"brightness": 380.0,
		"spread_degrees": 1.0,
		"ambient_colour": [0.74, 0.78, 0.92],
	},
	"fog": {
		"enabled": true,
		"colour": [0.80, 0.89, 1.0],
		"start": 6300.0,
		"end": 31500.0,
		"max_density": 0.2,
	},
	"sky_top": [0.30, 0.56, 0.96],
}


func _build_light() -> void:
	var holder := Node3D.new()
	holder.name = "Lighting"
	add_child(holder)
	var sun := DotLightRig.apply(holder, DotLightDocument.from_dictionary(DAYLIGHT), light_profile())
	for node in holder.get_children():
		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				var top: Array = DAYLIGHT["sky_top"]
				material.sky_top_color = Color(float(top[0]), float(top[1]), float(top[2]))
				material.ground_bottom_color = material.sky_top_color
	if sun != null:
		sun.shadow_blur = 1.5


## What this machine draws of [constant DAYLIGHT]: dot-lighting's `painted()`.
##
## Shadows stay on in the browser, unlike dot-lighting's `web()`: a platform's shadow on the deck below is how a player sees where a deck is from above. `painted()` is the family's profile for flat colours (lower exposure, so the grid a tilt is read from is not 30 % white).
static func light_profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	p.sky_below_horizon = true
	return p



func _build_floor() -> void:
	var reach := _field_reach() + FLOOR_MARGIN

	var body := StaticBody3D.new()
	body.name = "Floor"
	body.position = Vector3(0.0, config.kill_height - 1.0, 0.0)

	var shape := BoxShape3D.new()
	shape.size = Vector3(reach * 2.0, 2.0, reach * 2.0)

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	body.add_child(collider)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = shape.size
	mesh.mesh = box
		# Its own muted sky blue (`ScTextures.Role.FLOOR`): the hazard red filled ninety percent of every frame and reduced the platforms to specks. The drop says "do not go there"; the floor only has to be far away and carry a grid so the drop can be counted.
	mesh.material_override = ScTextures.surface(ScTextures.Role.FLOOR)
	body.add_child(mesh)

	_classify(body, &"world")
	add_child(body)
	_floor_body = body


## How far the platform field reaches from the middle, in metres.
##
## The field alone: [method showdown_centre] is placed from it, and a reach including the showdown would chase itself.
func _field_reach() -> float:
	# The widest of every layout, because this arena is built once and the layout changes
	# under it every round. A reach taken from the configured grid alone puts the showdown
	# inside the bigger maps' corner towers.
	var reach := 0.0

	for layout in ScLayouts.all(config):
		var across := float(layout.field_columns(config) - 1) * config.column_pitch * 0.5 \
				+ config.platform_size
		var deep := float(layout.field_rows(config) - 1) * config.row_pitch * 0.5 \
				+ config.platform_size
		reach = maxf(reach, maxf(across, deep))

	return reach


## How far the floor has to reach to be under everything, in metres.
func _map_reach() -> float:
	var showdown := showdown_centre()
	var to_showdown := Vector2(showdown.x, showdown.z).length() \
		+ config.corner_distance + config.corner_size
	return maxf(_field_reach(), to_showdown)



## Where a launched prop leaves from.
##
## One number the tube, the cannon and the client's copy all read, so a mouth drawn in one place cannot fire from another.
func muzzle() -> Vector3:
	return Vector3(0.0, config.deck_height * TUBE_HEIGHT_FRACTION + MUZZLE_CLEARANCE, 0.0)


func _build_tube() -> void:
	var height := config.deck_height * TUBE_HEIGHT_FRACTION

	var body := StaticBody3D.new()
	body.name = "Tube"
	body.position = Vector3(0.0, height * 0.5, 0.0)

	var shape := CylinderShape3D.new()
	shape.radius = TUBE_RADIUS
	shape.height = height

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	body.add_child(collider)

	var column := CylinderMesh.new()
	column.top_radius = TUBE_RADIUS
	column.bottom_radius = TUBE_RADIUS * 1.35
	column.height = height
	column.radial_segments = 16

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = column
	mesh.material_override = ScTextures.surface(ScTextures.Role.CANNON)
	body.add_child(mesh)

	_classify(body, &"world")
	add_child(body)

		# A collar at the mouth, mesh only, so the tube reads as a barrel; no collider, since a lip at the height props pass through would catch them.
	var collar := MeshInstance3D.new()
	collar.name = "Collar"
	var ring := CylinderMesh.new()
	ring.top_radius = TUBE_RADIUS * 1.5
	ring.bottom_radius = TUBE_RADIUS * 1.5
	ring.height = 1.1
	ring.radial_segments = 16
	collar.mesh = ring
	collar.position = Vector3(0.0, height - 0.55, 0.0)
	collar.material_override = ScTextures.surface(ScTextures.Role.HAZARD)
	add_child(collar)



## Where the showdown happens: a structure in the sky, well clear of the platform field.
##
## A map's width away along -Z, not over the middle: there it shares volume with the tube, the cannon's arc and the chopper pad, and a spawned chopper sat pinned under the ring with every number correct. Still in plain sight, since a player who sees where the round ends plays the first half differently.
func showdown_centre() -> Vector3:
	return Vector3(
		0.0,
		config.deck_height + config.corner_rise,
		-(_field_reach() + config.corner_distance * 1.6)
	)


## Where team [param index] of [param count] finishes the round, on the pad's surface.
##
## Evenly round a circle from +X, so two teams are opposite and the team count does not change what a corner means.
func corner_point(index: int, count: int) -> Vector3:
	var teams := maxi(count, 1)
	var angle := TAU * float(index) / float(teams)
	var centre := showdown_centre()

	return Vector3(
		centre.x + cos(angle) * config.corner_distance,
		centre.y,
		centre.z + sin(angle) * config.corner_distance
	)


## Where one player stands when they arrive in a corner.
##
## Spread along the pad's inner edge: sixteen capsules at one coordinate is dot-spawn's documented failure.
func showdown_spawn(team_index: int, team_count: int, slot: int, slots: int) -> Vector3:
	var centre := corner_point(team_index, team_count)
	var middle := showdown_centre()
	var inward := Vector3(middle.x - centre.x, 0.0, middle.z - centre.z).normalized()

	if inward.length() < 0.001:
		inward = Vector3.FORWARD

	var across := Vector3(-inward.z, 0.0, inward.x)
	var spread := config.corner_size * 0.6
	var places := maxi(slots, 1)
	var offset := 0.0

	if places > 1:
		offset = -spread * 0.5 + spread * float(slot) / float(places - 1)

	return centre + across * offset - inward * config.corner_size * 0.25 + Vector3.UP * 1.2


## Which way a player faces when they arrive: toward the middle, in degrees.
##
## Degrees because [DotFpsState.yaw] is, while `DotSpawnSite.yaw` is radians. The motor's forward is `(-sin y, 0, -cos y)`, so the yaw is `atan2(-dx, -dz)`; a wrong one passes every count and the player arrives facing a wall.
func showdown_yaw(team_index: int, team_count: int) -> float:
	var centre := corner_point(team_index, team_count)
	var middle := showdown_centre()
	var inward := Vector3(middle.x - centre.x, 0.0, middle.z - centre.z)

	if inward.length() < 0.001:
		return 0.0

	return rad_to_deg(atan2(-inward.x, -inward.z))


## The pads, the ring and the catwalks between them.
##
## Connected: six pads with nothing between would be six people looking at each other across 60 m until the clock ran out. The ring is the thing worth taking and the catwalks the only way to it.
func _build_showdown() -> void:
	_showdown = Node3D.new()
	_showdown.name = "Showdown"
	add_child(_showdown)

	var middle := showdown_centre()
	var ring_radius := ring_half()

	# Where each catwalk leaves the ring, so the ring's kerb can stop there. See
	# [method _build_kerb] for why it has to.
	var outwards: Array[Vector2] = []

	for index in range(config.team_count):
		var corner := corner_point(index, config.team_count)
		var out := Vector2(corner.x - middle.x, corner.z - middle.z)

		if out.length() > 0.001:
			outwards.append(out.normalized())

	_pad(
		"Ring",
		middle,
		Vector2(ring_radius * 2.0, ring_radius * 2.0),
		ScTextures.Role.ARENA,
		true,
		outwards
	)

	for index in range(config.team_count):
		var centre := corner_point(index, config.team_count)
		var inward := Vector2(middle.x - centre.x, middle.z - centre.z)
		var openings: Array[Vector2] = []

		if inward.length() > 0.001:
			openings.append(inward.normalized())

		# And the two flank catwalks, one to the perch on either side of this pad.
		for walk: Dictionary in flank_walks():
			if int(walk["pad"]) == index:
				openings.append(walk["out"] as Vector2)

		_pad(
			"Pad%d" % index,
			centre,
			Vector2(config.corner_size, config.corner_size),
			ScTextures.Role.SAFE,
			true,
			openings
		)

		# The catwalk, from the pad's inner edge to the ring's rim. See [method catwalk].
		if inward.length() > 0.001:
			_build_catwalk(index)

	var cover := ring_cover()

	for index in range(cover.size()):
		_cover_block("RingCover%d" % index, cover[index])

	_block("RingDais", dais(), DAIS_SIZE, ScTextures.Role.CANNON)

	_build_flanks()


## Half the width of the showdown ring, which is a square on the showdown's middle.
func ring_half() -> float:
	return config.corner_size * 0.85


## Team [param index]'s catwalk from its pad to the ring, as a Dictionary.
##
## `out` is the direction from the ring's middle to the pad (XZ), `across` square to it, `yaw`; for each long side (`w` is -half and +half a width) `from` and `to` are where it meets the ring's and the pad's edges along `out`; `corners` is the slab's top in the order (-w, from), (+w, from), (+w, to), (-w, to). The ends are cut along each edge: with three, five or six sides a catwalk meets the ring at an angle, so a square-ended slab overlaps coplanar floor and drags kerb stubs in, and stopping short leaves a wedge of air.
func catwalk(index: int) -> Dictionary:
	var count := config.team_count
	var middle := showdown_centre()
	var corner := corner_point(index, count)
	var out := Vector2(corner.x - middle.x, corner.z - middle.z).normalized()
	var across := Vector2(out.y, -out.x)
	var reach := Vector2(corner.x - middle.x, corner.z - middle.z).length()
	var half_width := CATWALK_WIDTH * 0.5
	var ends: Array[Vector2] = []
	var corners: Array[Vector3] = []

	for w: float in [-half_width, half_width]:
		var side := across * w
		var from := _line_exit(ring_half(), out, side)
		# The pad, from its own middle, the other way along the same line.
		var to := reach - _line_exit(config.corner_size * 0.5, -out, side)
		ends.append(Vector2(from, to))

	for at: Vector2 in [
		Vector2(-half_width, ends[0].x), Vector2(half_width, ends[1].x),
		Vector2(half_width, ends[1].y), Vector2(-half_width, ends[0].y),
	]:
		var xz := out * at.y + across * at.x
		corners.append(Vector3(middle.x + xz.x, middle.y, middle.z + xz.y))

	return {
		"out": out,
		"across": across,
		"yaw": atan2(out.x, out.y),
		"ends": ends,
		"corners": corners,
	}


## How far along [param d] from [param offset] a line leaves an axis-aligned square of
## half-width [param half] on the origin. The line has to start inside it.
static func _line_exit(half: float, d: Vector2, offset: Vector2) -> float:
	var exit := INF

	if absf(d.x) > 0.0001:
		exit = minf(exit, (signf(d.x) * half - offset.x) / d.x)

	if absf(d.y) > 0.0001:
		exit = minf(exit, (signf(d.y) * half - offset.y) / d.y)

	return exit


## Builds team [param index]'s catwalk as described by [method catwalk]: a slab whose two
## short ends lie along the ring's and the pad's edges, and a kerb on each long side that
## stops where the band under it meets either edge.
func _build_catwalk(index: int) -> void:
	var walk := catwalk(index)
	var ends: Array[Vector2] = walk["ends"]
	var out: Vector2 = walk["out"]
	var middle := showdown_centre()
	var thickness := 0.7

	# The body sits on the catwalk's middle line, half-way along, turned to face `out`: its
	# local X is `across` and its local Z is `out`, which is what `yaw` gives a basis.
	var mid := (ends[0].x + ends[1].x + ends[0].y + ends[1].y) * 0.25
	var body := StaticBody3D.new()
	body.name = "Catwalk%d" % index
	body.position = Vector3(middle.x + out.x * mid, middle.y, middle.z + out.y * mid)
	body.rotation = Vector3(0.0, float(walk["yaw"]), 0.0)

	var half_width := CATWALK_WIDTH * 0.5
	var top: Array[Vector3] = [
		Vector3(-half_width, 0.0, ends[0].x - mid), Vector3(half_width, 0.0, ends[1].x - mid),
		Vector3(half_width, 0.0, ends[1].y - mid), Vector3(-half_width, 0.0, ends[0].y - mid),
	]
	var points := PackedVector3Array()

	for p in top:
		points.append(p)

	for p in top:
		points.append(p + Vector3.DOWN * thickness)

	var shape := ConvexPolygonShape3D.new()
	shape.points = points

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	body.add_child(collider)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = _prism_mesh(points)
	mesh.material_override = ScTextures.surface(ScTextures.Role.ARENA)
	body.add_child(mesh)

	# The kerbs, one per long side. The band is PAD_BAND wide, and its outer and inner
	# lines leave an oblique edge at different places, so each end is the later of the two.
	var material := ScTextures.surface(ScTextures.Role.CANNON)
	var inner := half_width - PAD_BAND
	var corner := corner_point(index, config.team_count)
	var reach := Vector2(corner.x - middle.x, corner.z - middle.z).length()

	for side in range(2):
		var toward := -1.0 if side == 0 else 1.0
		var inside := (walk["across"] as Vector2) * (toward * inner)
		var from := maxf(ends[side].x, _line_exit(ring_half(), out, inside))
		var to := minf(ends[side].y, reach - _line_exit(config.corner_size * 0.5, -out, inside))
		var span := Vector3(PAD_BAND, CORNER_LIP, to - from)
		var place := Vector3(toward * (half_width - PAD_BAND * 0.5), 0.0, (from + to) * 0.5 - mid)
		_kerb_piece(body, "%d_0" % (2 + side), span, place, material)

	_classify(body, &"world")
	_showdown.add_child(body)


## A closed prism from its top four [param points] and then its bottom four, flat-shaded
## and wound for Godot's front faces whichever way round the quad was given.
static func _prism_mesh(points: PackedVector3Array) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var centre := Vector3.ZERO

	for p in points:
		centre += p

	centre /= float(points.size())

	var faces: Array[PackedInt32Array] = [
		PackedInt32Array([0, 1, 2, 3]), PackedInt32Array([4, 5, 6, 7]),
	]

	for i in range(4):
		var j := (i + 1) % 4
		faces.append(PackedInt32Array([i, j, j + 4, i + 4]))

	for face in faces:
		var a := points[face[0]]
		var b := points[face[1]]
		var c := points[face[2]]
		var d := points[face[3]]
		var normal := (b - a).cross(c - a).normalized()

		if normal.dot((a + c) * 0.5 - centre) < 0.0:
			normal = -normal

		for tri: Array in [[a, b, c], [a, c, d]]:
			var p: Vector3 = tri[0]
			var q: Vector3 = tri[1]
			var r: Vector3 = tri[2]

			# Godot draws a triangle's front when it is clockwise seen from outside.
			if (q - p).cross(r - p).dot(normal) > 0.0:
				var swap := q
				q = r
				r = swap

			for v in [p, q, r]:
				tool.set_normal(normal)
				tool.add_vertex(v)

	return tool.commit()


## The cover on the showdown ring: one block per team, on the line from the ring's middle to that team's catwalk, [constant RING_COVER_OUT] of the way out and square to it. Each is a transform whose origin is the block's centre.
##
## Without cover the ring is the most exposed floor in the sky, in every pad's line of fire. The blocks face the pads, not sit between catwalks (end-on to both, covering nobody), and half-way in so a survivor has seven metres of floor before it.
func ring_cover() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var middle := showdown_centre()
	var ring_radius := ring_half()

	for index in range(config.team_count):
		var corner := corner_point(index, config.team_count)
		var out_dir := Vector3(corner.x - middle.x, 0.0, corner.z - middle.z)

		if out_dir.length() < 0.001:
			continue

		out_dir = out_dir.normalized()
		var centre := middle + out_dir * ring_radius * RING_COVER_OUT
		centre.y = middle.y + RING_COVER_SIZE.y * 0.5
		# Long side across the line to the pad, so it covers somebody from that pad.
		out.append(Transform3D(Basis(Vector3.UP, atan2(out_dir.x, out_dir.z)), centre))

	return out


## Wide enough for one person to crouch behind, and chest high: a person standing behind
## it is shot at over it, a person crouched is not.
const RING_COVER_SIZE := Vector3(2.4, 1.1, 0.6)



## The block in the ring's middle: 4 m square, 0.9 m high.
##
## Cover that turns: every ring block covers only from the pad it faces, so a survivor crouched on the side away from a threat is out of sight of that pad or perch. Its top is the high ground: 0.9 m is one jump (apex 1.15) and never a step (0.45), and the eye there (2.5 m over the ring) sees every pad and perch.
const DAIS_SIZE := Vector3(4.0, 0.9, 4.0)


## Where the dais stands: on the ring's middle, its base on the ring's surface.
func dais() -> Transform3D:
	return Transform3D(Basis.IDENTITY, showdown_centre() + Vector3.UP * DAIS_SIZE.y * 0.5)

## How far out from the ring's middle the cover stands, as a fraction of its half-width.
const RING_COVER_OUT := 0.5



## How wide a perch is: the small pad on the flank between two teams' pads.
const PERCH_SIZE := 8.0

## How far a flank catwalk's surface sits under the pads it joins, in metres.
##
## It runs half its width into both ends to leave no notch of air, and two coplanar tops z-fight; two centimetres down the pad's surface wins and the step is unnoticed.
const FLANK_DROP := 0.02

## Where perch [param index] of [param count] stands: on the pads' own circle, half-way
## round between pad [param index] and the next one.
func perch_point(index: int, count: int) -> Vector3:
	var teams := maxi(count, 1)
	var angle := TAU * (float(index) + 0.5) / float(teams)
	var centre := showdown_centre()

	return Vector3(
		centre.x + cos(angle) * config.corner_distance,
		centre.y,
		centre.z + sin(angle) * config.corner_distance
	)


## Every flank catwalk, as one Dictionary each: `pad` and `perch` (indices), `out`/`back` (directions it leaves the pad/perch in, Vector2 on XZ), `from` and `to` (where its centre line crosses the pad's and perch's edges, on the surface), and `centre`, `yaw`, `length` (the slab, overlap included).
##
## A perch between every two pads, joined by catwalks that never touch the ring, is a second route to an enemy pad and, with two sides, a line on the ring from 90 degrees off where no block covers anybody. The pads' kerb openings, the perches, the slabs and the suite all read this.
func flank_walks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var teams := config.team_count

	for perch in range(teams):
		var at := perch_point(perch, teams)

		for pad: int in [perch, (perch + 1) % teams]:
			var corner := corner_point(pad, teams)
			var line := Vector2(at.x - corner.x, at.z - corner.z)

			if line.length() < 0.001:
				continue

			var d := line.normalized()
			var leave := _square_exit(config.corner_size * 0.5, d)
			var arrive := _square_exit(PERCH_SIZE * 0.5, d)
			var overlap := CATWALK_WIDTH * 0.5
			var start := leave - overlap
			var length := line.length() - arrive + overlap - start
			var mid := start + length * 0.5
			var surface := corner.y - FLANK_DROP

			out.append({
				"pad": pad,
				"perch": perch,
				"out": d,
				"back": -d,
				"from": Vector3(corner.x + d.x * leave, corner.y, corner.z + d.y * leave),
				"to": Vector3(at.x - d.x * arrive, at.y, at.z - d.y * arrive),
				"centre": Vector3(corner.x + d.x * mid, surface, corner.z + d.y * mid),
				"yaw": atan2(d.x, d.y),
				"length": length,
			})

	return out


## How far from the middle of an axis-aligned square of half-width [param half] a line in
## direction [param d] leaves it.
static func _square_exit(half: float, d: Vector2) -> float:
	return half / maxf(absf(d.x), absf(d.y))


func _build_flanks() -> void:
	var walks := flank_walks()

	for perch in range(config.team_count):
		var openings: Array[Vector2] = []

		for walk: Dictionary in walks:
			if int(walk["perch"]) == perch:
				openings.append(walk["back"] as Vector2)

		_pad(
			"Perch%d" % perch,
			perch_point(perch, config.team_count),
			Vector2(PERCH_SIZE, PERCH_SIZE),
			ScTextures.Role.SAFE,
			true,
			openings
		)

	for index in range(walks.size()):
		var walk := walks[index]
		var slab := _pad(
			"Flank%d" % index,
			walk["centre"] as Vector3,
			Vector2(CATWALK_WIDTH, float(walk["length"])),
			ScTextures.Role.ARENA,
			false
		)
		slab.rotation = Vector3(0.0, float(walk["yaw"]), 0.0)


func _cover_block(node_name: String, at: Transform3D) -> void:
	_block(node_name, at, RING_COVER_SIZE, ScTextures.Role.CANNON)


## One solid box in the showdown, collider and mesh from the same size.
func _block(node_name: String, at: Transform3D, size: Vector3, role: ScTextures.Role) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.transform = at

	var shape := BoxShape3D.new()
	shape.size = size

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	body.add_child(collider)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = ScTextures.surface(role)
	body.add_child(mesh)

	_classify(body, &"world")
	_showdown.add_child(body)


## One flat surface with a kerb around it, open wherever a catwalk joins it.
##
## [param openings] are the directions, from the pad's middle, that a catwalk leaves in.
func _pad(
	node_name: String, at: Vector3, size: Vector2, role: ScTextures.Role,
	ends: bool = true, openings: Array[Vector2] = []
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = at

	var thickness := 0.7

	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, thickness, size.y)

	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.shape = shape
	collider.position = Vector3(0.0, -thickness * 0.5, 0.0)
	body.add_child(collider)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box := BoxMesh.new()
	box.size = shape.size
	mesh.mesh = box
	mesh.position = collider.position
	mesh.material_override = ScTextures.surface(role)
	body.add_child(mesh)

	_build_kerb(body, size, ends, openings)

	_classify(body, &"world")
	_showdown.add_child(body)
	return body


## The kerb a pad, the ring or a catwalk has round its edges.
##
## A BAND (hair proud, no collider) keeps an edge visible edge-on; the KERB is a collider on it, walkable but stopping a slide. [param ends] is false for a catwalk, whose short edges are junctions where a kerb would be a step; and it is open where a catwalk arrives, since the step-up does not take a 0.34 m kerb 0.6 m deep.
func _build_kerb(
	body: StaticBody3D, size: Vector2, ends: bool = true, openings: Array[Vector2] = []
) -> void:
	var material := ScTextures.surface(ScTextures.Role.CANNON)

	var edges: Array[Vector3] = [
		Vector3(0.0, 0.0, size.y * 0.5 - PAD_BAND * 0.5),
		Vector3(0.0, 0.0, -size.y * 0.5 + PAD_BAND * 0.5),
		Vector3(size.x * 0.5 - PAD_BAND * 0.5, 0.0, 0.0),
		Vector3(-size.x * 0.5 + PAD_BAND * 0.5, 0.0, 0.0),
	]

	for i in range(edges.size()):
		if not ends and i < 2:
			continue

		# `along_x` is true for the two edges that run along Z (the ±X sides), which is the
		# naming this loop has always used: their kerb is thin in X.
		var along_x := i >= 2
		var half_run := (size.y if along_x else size.x) * 0.5
		var pieces := _kerb_pieces(edges[i], along_x, half_run, openings)

		for p in range(pieces.size()):
			var piece := pieces[p]
			var run := piece.y - piece.x
			var middle := (piece.x + piece.y) * 0.5
			var span := Vector3(
				PAD_BAND if along_x else run,
				CORNER_LIP,
				run if along_x else PAD_BAND
			)
			var place := edges[i] + (Vector3(0.0, 0.0, middle) if along_x else Vector3(middle, 0.0, 0.0))

			_kerb_piece(body, "%d_%d" % [i, p], span, place, material)


## One piece of kerb on [param body]: a `Kerb<suffix>` mesh and a `KerbHit<suffix>` collider
## of [param span], standing on the surface at [param place].
func _kerb_piece(
	body: StaticBody3D, suffix: String, span: Vector3, place: Vector3, material: Material
) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Kerb%s" % suffix
	var box := BoxMesh.new()
	box.size = span
	mesh.mesh = box
	# The pad's own surface is y = 0 on the body and the slab hangs below it, so the
	# kerb sits on top with its own middle half a lip up. Measuring from the mesh's
	# centre instead is what made the platforms' first rim invisible.
	mesh.position = place + Vector3(0.0, CORNER_LIP * 0.5, 0.0)
	mesh.material_override = material
	body.add_child(mesh)

	var shape := BoxShape3D.new()
	shape.size = span

	var collider := CollisionShape3D.new()
	collider.name = "KerbHit%s" % suffix
	collider.shape = shape
	collider.position = mesh.position
	body.add_child(collider)


## What is left of one edge's kerb once every catwalk crossing it is cut out, as (from, to) along the edge.
##
## Cut where the catwalk's STRIP crosses the edge, not its middle: at three, five or six sides it meets the ring at an angle, and a gap measured along the edge is narrower than the walkway.
static func _kerb_pieces(
	edge: Vector3, along_x: bool, half_run: float, openings: Array[Vector2]
) -> Array[Vector2]:
	var cuts: Array[Vector2] = []
	var half_width := CATWALK_WIDTH * 0.5

	for d in openings:
				# A point on this edge is `fixed` on one axis and `s` along the other; it is inside the catwalk's strip when |d_fixed * s - d_run * fixed| is at most half a width, and on its side when ahead along `d`.
		var fixed := edge.x if along_x else edge.z
		var d_fixed := d.x if along_x else d.y
		var d_run := d.y if along_x else d.x

		if absf(d_fixed) < 0.0001:
			# The catwalk runs parallel to this edge, so none of it crosses it.
			continue

		var a := (d_run * fixed - half_width) / d_fixed
		var b := (d_run * fixed + half_width) / d_fixed
		var lo := minf(a, b)
		var hi := maxf(a, b)
		var ahead := d_fixed * fixed + d_run * (lo + hi) * 0.5

		if ahead > 0.0:
			cuts.append(Vector2(lo, hi))

	var pieces: Array[Vector2] = [Vector2(-half_run, half_run)]

	for cut in cuts:
		var next: Array[Vector2] = []

		for piece in pieces:
			if cut.y <= piece.x or cut.x >= piece.y:
				next.append(piece)
				continue

			if cut.x - piece.x > 0.05:
				next.append(Vector2(piece.x, cut.x))

			if piece.y - cut.y > 0.05:
				next.append(Vector2(cut.y, piece.y))

		pieces = next

	return pieces



## Where chopper [param index] of [param count] is parked at the start of a round.
##
## Above the middle and off to one side, so taking one is a decision made in the open.
func chopper_pad(index: int, count: int) -> Vector3:
	var places := maxi(count, 1)
	var angle := TAU * float(index) / float(places) + PI * 0.25
	var reach := float(config.columns - 1) * config.column_pitch * 0.32

	return Vector3(
		cos(angle) * reach,
		config.deck_height + config.chopper_pad_height,
		sin(angle) * reach
	)



func _classify(body: Node, layer_id: StringName) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, layer_id)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a body could not be put on its collision layer", {
			"body": body.name, "layer": String(layer_id), "why": applied.error.message,
		})


## Whether a point has fallen out of the world.
func is_below_the_map(at: Vector3) -> bool:
	return at.y <= config.kill_height


func describe() -> Dictionary:
	return {
		"reach": "%.0f m" % _map_reach(),
		"muzzle": "%.0f m" % muzzle().y,
		"corners": config.team_count,
		"corner_at": "%.0f m" % config.corner_distance,
		"floor": "%.1f m" % config.kill_height,
	}
