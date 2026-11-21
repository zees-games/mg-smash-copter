extends "sc_prop_net.gd"

## What a chopper replicates, through [GSVehicleNetSync].
##
## [b]It extends the prop behaviour rather than sitting beside it.[/b] A chopper is another
## body the server moves and the client draws, so the bridge keeps ONE table of replicated
## bodies and one `pull` loop over it; a second parallel table is a second thing that can
## disagree about which of them exists.
##
## [b]`extends` a relative path, not a `class_name`.[/b] A mounted gs-cloud pack's globals
## are not registered in the host, so a game that named its own base class would compile
## here, mount there and have every script in it dead with nothing reporting a thing.

const ScCopterBody := preload("../../props/sc_copter_body.gd")

## The instance, on the authority only. Null on a client, where a chopper is a body being
## drawn where the server says it is and nothing more.
var vehicle: GSVehicleInstance = null

# The replicated properties, named by [GSVehicleNetSync]. Declared here because GDScript
# has no dynamic properties: `specs()` says what to send, and these are what it sends.
var net_x: float = 0.0
var net_y: float = 0.0
var net_z: float = 0.0
var net_orientation: Quaternion = Quaternion.IDENTITY
var net_speed: int = 0
var net_steering: int = 0
var net_health: int = 100
var net_occupancy: int = 0


## Declared from the addon's own table.
##
## [b]The type is resolved from a STRING, and that is why the table is written the way it
## is.[/b] [GSVehicleNetSync] never mentions a gs-net `class_name`, because a script
## naming a class the project does not have fails to parse and takes every script that
## references it down with it — so a game without gs-net can still use gs-vehicle.
## Resolving `GSNetVar.Type[spec.type]` is the game's half of that bargain and can only be
## done here.
func _register_net_vars() -> void:
	for spec in GSVehicleNetSync.specs():
		var declaration := replicate(spec["property"], GSNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()


func pull() -> void:
	if vehicle == null or not vehicle.is_alive():
		return

	GSVehicleNetSync.pull(vehicle, self)


## The vehicle layout's three floats, as the one vector everything else reads.
func replicated_position() -> Vector3:
	return Vector3(net_x, net_y, net_z)


func _draw() -> void:
	if not _drawable():
		return

	if identity != null and identity.is_authoritative:
		return

	GSVehicleNetSync.apply(prop, self)

	# Frozen for the same reason a mirrored prop is: an unfrozen [RigidBody3D] fights every
	# transform written into it, and the result is a machine juddering in the air while the
	# packets say it is flying level. The rotor keeps turning either way — see
	# [ScCopterBody], which drives it off the velocity rather than off a command a client
	# does not have.
	var rigid := prop as RigidBody3D

	if rigid != null and not rigid.freeze:
		rigid.freeze = true


## Whether a seat is taken, from the replicated mask. What a "get in" prompt reads.
func seat_occupied(seat_index: int) -> bool:
	return GSVehicleNetSync.is_seat_occupied(net_occupancy, seat_index)
