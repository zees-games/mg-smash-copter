extends RigidBody3D

const ScTextures := preload("../game/sc_textures.gd")
const ScPaths := preload("../game/sc_paths.gd")

## The chopper: a modelled fuselage (Kenney's pod, modified) with code-spun rotors.
##
## [b]Kenney's kits have no aircraft, so the base is a space-kit pod[/b] that
## `art-src/build_copter.py` stretches to the hull, then fits with a canopy, boom, fin and
## skids. The collider is still one box and the tail is deliberately outside it.
##
## [b]The rotor is the only thing that moves and it is the only thing that matters.[/b] A
## helicopter with a still rotor reads as a wreck; one with a turning rotor reads as a
## machine somebody is flying, from any distance and at any angle, which on a map where it
## is usually a silhouette forty metres up is the whole of its presentation.

# No `const CHANNEL`: this spins a rotor and draws a machine whose state [ScCopter] owns and
# logs, so there is nothing here an operator would act on.

## Metres. The hull a player and the world collide with.
const HULL := Vector3(2.2, 1.8, 5.0)

## The modelled fuselage, named in the scene because a pack rewrites paths there and not here.
@export var model_path: String = ""

## The rotor disc's radius, which is most of what anybody sees.
const ROTOR_RADIUS := 4.1

## Radians a second at rest, and at full tilt. It never stops: a parked chopper is idling.
const ROTOR_IDLE := 7.0
const ROTOR_FLYING := 46.0

var _rotor: Node3D = null
var _tail_rotor: Node3D = null

## How fast the disc is turning right now, so it spins up and down rather than snapping.
var _rotor_speed: float = ROTOR_IDLE


func _ready() -> void:
	_build_collision()
	_build_hull()
	_build_rotors()
	_build_seats()


func _build_collision() -> void:
	# [b]One box, and the tail is deliberately outside it.[/b] A collider that followed
	# the silhouette would put a two-metre boom behind the machine that catches on every
	# platform edge it backs over — and a pilot cannot see it. dot-props documents the same
	# choice from the other end: the art is a shape and the physics is a primitive.
	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	var box := BoxShape3D.new()
	box.size = HULL
	collider.shape = box
	add_child(collider)


## The fuselage, canopy, tail boom, fin, mast and skids are one modelled mesh, a modified
## Kenney Space Kit pod built by `art-src/build_copter.py` (CC0, credited in the README). It
## sits at the body's origin and fills the same box as the collider, so nothing the physics
## or the seats expect has moved. The rotors stay code nodes below because they are what spins.
func _build_hull() -> void:
	var model: PackedScene = load(ScPaths.rebase(model_path))
	var mesh := model.instantiate()
	mesh.name = "Model"
	add_child(mesh)


func _build_rotors() -> void:
	_rotor = Node3D.new()
	_rotor.name = "Rotor"
	_rotor.position = Vector3(0.0, 1.25, 0.0)
	add_child(_rotor)

	# Four blades rather than two, because at speed a two-blade disc strobes badly against
	# a frame rate and reads as a rotor that has stopped — which is the one impression this
	# machine must never give.
	for i in range(4):
		var blade := MeshInstance3D.new()
		blade.name = "Blade%d" % i
		var box := BoxMesh.new()
		box.size = Vector3(0.3, 0.06, ROTOR_RADIUS)
		blade.mesh = box
		blade.position = Vector3(0.0, 0.0, 0.0)
		blade.rotation = Vector3(0.0, TAU * float(i) / 4.0, 0.0)
		# Offset along its own length, which is what `transform` after `rotation` gives:
		# the blade runs from the mast outward rather than through it.
		blade.transform.origin = blade.transform.basis * Vector3(0.0, 0.0, ROTOR_RADIUS * 0.5)
		blade.material_override = ScTextures.surface(ScTextures.Role.HAZARD)
		_rotor.add_child(blade)

	_tail_rotor = Node3D.new()
	_tail_rotor.name = "TailRotor"
	_tail_rotor.position = Vector3(0.22, 1.05, 4.9)
	add_child(_tail_rotor)

	for i in range(2):
		var blade := MeshInstance3D.new()
		blade.name = "TailBlade%d" % i
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 1.5, 0.16)
		blade.mesh = box
		blade.rotation = Vector3(TAU * float(i) / 4.0, 0.0, 0.0)
		blade.material_override = ScTextures.surface(ScTextures.Role.HAZARD)
		_tail_rotor.add_child(blade)


## Where a rider is put. [DotVehicleSeat.attach_path] names these by node path.
func _build_seats() -> void:
	var pilot := Marker3D.new()
	pilot.name = "PilotSeat"
	pilot.position = Vector3(-0.55, 0.25, -1.4)
	add_child(pilot)

	var rider := Marker3D.new()
	rider.name = "RiderSeat"
	rider.position = Vector3(0.55, 0.25, -1.4)
	add_child(rider)

	# Where a dropped prop leaves from: under the belly, clear of the skids, so it does
	# not land on the machine that dropped it.
	var bay := Marker3D.new()
	bay.name = "DropBay"
	bay.position = Vector3(0.0, -2.2, 0.0)
	add_child(bay)


## Turns the rotors. Presentation only, on render frames, and it writes nothing.
##
## [b]A render frame and not a tick, which is the line every game in this family draws in
## the same place.[/b] A rotor spun on the simulation tick turns in visible steps at 64 Hz
## on a 144 Hz screen; one spun on the frame is smooth and is identical on a machine that
## has switched it off. Nothing the simulation reads is touched here, so a player with the
## effect disabled simulates the same round as everybody else.
func _process(delta: float) -> void:
	var wanted := ROTOR_IDLE

	if not freeze:
		# Spun up in proportion to how hard the machine is working, measured off what it
		# is doing rather than off a control this node does not see: a mirrored chopper on
		# a client has no command at all and still has to look like it is flying.
		var effort := clampf(linear_velocity.length() / 12.0, 0.0, 1.0)
		wanted = lerpf(ROTOR_IDLE * 2.2, ROTOR_FLYING, effort)

	_rotor_speed = move_toward(_rotor_speed, wanted, 30.0 * delta)

	if _rotor != null:
		_rotor.rotate_y(_rotor_speed * delta)

	if _tail_rotor != null:
		_tail_rotor.rotate_x(_rotor_speed * 1.6 * delta)
