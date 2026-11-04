extends Node3D

const ScConfig := preload("sc_config.gd")
const ScTextures := preload("sc_textures.gd")

## The blocks, pads and kerbs the arena is made of; [ScArena] decides where they go.

const CHANNEL := "sc.arena"

## Where the showdown happens. Built once and left standing, because it is visible from
## the platforms and a player who can see where the round ends plays the first half
## differently.
var _showdown: Node3D = null

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


func _classify(body: Node, layer_id: StringName) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, layer_id)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a body could not be put on its collision layer", {
			"body": body.name, "layer": String(layer_id), "why": applied.error.message,
		})


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
