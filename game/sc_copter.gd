extends DotVehicleChassis

## The chopper: a fourth kind of vehicle, because neither of dot-vehicle's two is one.
##
## [b]This file exists because [DotVehicleHover] returns early when nothing is under
## it.[/b] That is the hovercraft being right — a craft held up by ground effect has
## nothing to push against over a canyon — and it is exactly the state a helicopter spends
## its whole life in. [DotVehicleWheeled] needs wheels on a surface. So the addon's own
## extension point is the answer: `DotVehicleDef.chassis_script_path` names a script by
## PATH, dot-vehicle loads it, checks it extends this base and drives it like any other.
## Nothing in dot-vehicle is forked and nothing in it knows what a helicopter is.
##
## [b]Four controls, and only three of them fit in a [DotVehicleCommand].[/b]
##
## [codeblock]
## command.throttle  collective — jump climbs, crouch descends
## command.steer     the pedals — A and D yaw
## command.brake     the rotor brake, which is how you drop out of the sky
## vehicle.meta.cyclic  W and S, as a Vector2 the game writes each tick
## [/codeblock]
##
## The cyclic goes in the instance's `meta` rather than in the command because the command
## is dot-vehicle's wire shape and widening it would be a breaking change across every
## game that has one, for a field only an aircraft has. `meta` is the free-form dictionary
## the addon ships for exactly this.
##
## [b]It is not predicted.[/b] A helicopter is a rigid body under six forces and Godot's
## solver is not reproducible across machines, so the pilot's keys go round trip like a
## bus driver's in game-buses-from-hell — and for the same reason that is bearable: 1.4
## tonnes hanging under a rotor take about a round trip to respond to anything.

const CHANNEL := "sc.copter"

## Where the game writes the pilot's forward and back. See the class documentation.
const META_CYCLIC := &"cyclic"

## And the height it may not climb past, in metres. Written by the game because the
## ceiling is a property of the map rather than of the machine.
const META_CEILING := &"ceiling"

## How hard it holds itself level, in radians per second squared per radian of tip.
##
## [b]High, and a helicopter that did not would be unflyable.[/b] The real machine is
## balanced by a person making hundreds of corrections a minute; a player has a keyboard.
## What this stands in for is the pilot, and without it the first gust puts the rotor disc
## on its side and the whole thing into the floor.
const LEVEL_GAIN := 26.0

## And how much of its own tipping speed it takes back out per second.
const LEVEL_DAMPING := 7.5

## Radians the nose drops at full forward cyclic.
##
## [b]Cosmetic and load-bearing at once.[/b] A helicopter that translated without tipping
## reads as a lift moving sideways; the tip is how anybody watching from a platform knows
## which way it has committed — which, since it is about to drop something on them, is the
## most useful thing on the screen.
const CYCLIC_TIP := 0.34

## How much sideways drift is removed per second, as a fraction.
##
## Zero is a machine that never stops going the way it last went and cannot be parked;
## one is a machine on rails. This is the number that makes it feel like it has mass.
const LATERAL_DAMPING := 1.15

## The lift multiplier at full collective. Written by the game from the configuration.
var lift_ratio: float = 1.9

## Metres per second squared the world is pulling down with. Written by the game, because
## a chopper in a low-gravity round has to hover with less.
var gravity: float = 20.0

## How fast it may fly over the ground. Taken from the tunables at bind time.
var _top_speed: float = 19.0

## Whether it was being held at the ceiling last tick, and whether it was on its back, so
## both are logged on the edge rather than every tick they last.
var _at_ceiling: bool = false
var _inverted: bool = false


func _setup() -> DotResult:
	var body := vehicle.body()

	if body == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A chopper needs a RigidBody3D at the root of its scene.",
			String(vehicle.def.id) if vehicle.def != null else "?"
		)

	_top_speed = maxf(tunables.top_speed, 1.0)

	# [b]Off, and a sleeping helicopter is a helicopter that has landed permanently.[/b]
	# Godot puts a body to sleep when it has been nearly still for a moment, and a parked
	# chopper on a pad is exactly that — so the first collective input would reach a body
	# the solver had stopped integrating, and the machine would sit there.
	body.can_sleep = false

	# Angular damping of its own, on top of the levelling torque. The torque is a spring
	# and a spring alone rings; this is what stops a chopper that was bumped rocking for
	# the rest of the round.
	# The linear damping is the tunables' (`linear_damp`), written by dot-vehicle before this.
	body.angular_damp = 2.4

	return DotResult.success(self)


func _drive(command: DotVehicleCommand, delta: float) -> void:
	var body := vehicle.body()

	if body == null or delta <= 0.0:
		return

	var transform := body.global_transform
	var mass := maxf(body.mass, 1.0)
	var weight := mass * gravity

	_apply_lift(body, command, weight)
	_apply_cyclic(body, transform, mass)
	_apply_yaw(body, delta)
	_apply_levelling(body, transform)
	_apply_lateral_damping(body, transform, mass, delta)


## The rotor. Collective up climbs, collective down drops it out of the sky.
##
## [b]At zero collective it hovers exactly, and that is what makes the control
## readable.[/b] A machine whose neutral is a slow sink is one a player is fighting the
## whole time they are trying to aim at something.
func _apply_lift(body: RigidBody3D, command: DotVehicleCommand, weight: float) -> void:
	var collective := clampf(command.throttle, -1.0, 1.0)
	var factor := 1.0 + collective * (maxf(lift_ratio, 1.01) - 1.0)

	# The rotor brake, which is the only way down in a hurry. It cuts lift rather than
	# pushing down, because a helicopter cannot push down.
	if command.brake > 0.0:
		factor *= clampf(1.0 - command.brake, 0.0, 1.0)

	factor = maxf(factor, 0.0)

	var ceiling := float(vehicle.meta.get(META_CEILING, 0.0))

	var over := ceiling > 0.0 and body.global_position.y > ceiling

	if over != _at_ceiling:
		_at_ceiling = over
		DotLog.debug(CHANNEL, "a chopper reached the ceiling" if over else "a chopper came down from the ceiling", {
			"vehicle": _name(), "ceiling": "%.1f m" % ceiling,
		})

	if over:
		# [b]Held rather than pushed back down.[/b] A ceiling that shoved would throw a
		# pilot who touched it back through the map; one that simply stops holding them up
		# lets them settle onto it, which reads as the air getting thin.
		factor = minf(factor, 1.0)

		if body.linear_velocity.y > 0.0:
			factor = minf(factor, 0.55)

	body.apply_central_force(Vector3.UP * weight * factor)


## The cyclic: the nose goes down and the machine goes that way.
func _apply_cyclic(body: RigidBody3D, transform: Transform3D, mass: float) -> void:
	var cyclic: Vector2 = vehicle.meta.get(META_CYCLIC, Vector2.ZERO)

	if cyclic.length() < 0.01:
		return

	var forward := -transform.basis.z
	forward.y = 0.0

	if forward.length() < 0.001:
		return

	forward = forward.normalized()

	var over_ground := Vector3(body.linear_velocity.x, 0.0, body.linear_velocity.z)

	# Measured on the way it is actually going, not on the way it is pointing: a chopper
	# sliding sideways at its top speed is not travelling forward at all, and one that
	# judged this on `speed()` would refuse to accelerate out of a slide.
	if over_ground.dot(forward) < _top_speed or cyclic.y < 0.0:
		body.apply_central_force(forward * cyclic.y * tunables.engine_force)

	# And the disc tips, which is what everybody underneath reads it by.
	var pitch_axis := transform.basis.x

	body.apply_torque(pitch_axis * cyclic.y * CYCLIC_TIP * mass * 3.2)


## The pedals. [member DotVehicleChassis.steering] is already smoothed by the base.
func _apply_yaw(body: RigidBody3D, delta: float) -> void:
	if absf(steering) < 0.0001:
		return

	var wanted := -steering / maxf(delta, 0.0001)
	var change := wanted - body.angular_velocity.y

	# A torque toward the rate that was asked for rather than a flat one, so the machine
	# turns at the rate the tunables name instead of accelerating for as long as the key
	# is held. `steering_rate_deg` therefore means degrees per second of yaw, which is
	# what an operator reading the cvar would expect it to mean.
	body.apply_torque(Vector3.UP * clampf(change, -6.0, 6.0) * body.mass * 0.45)


## The autopilot that keeps the disc flat. See [constant LEVEL_GAIN].
func _apply_levelling(body: RigidBody3D, transform: Transform3D) -> void:
	var up := transform.basis.y
	var axis := up.cross(Vector3.UP)

	# The reversed case cannot be handled by the general formula: two opposite vectors
	# have a zero cross product, so the axis is undefined and the torque comes out NaN —
	# which in Godot is a body that stops being simulated with nothing reported anywhere.
	# An inverted chopper is pushed off its back onto a fixed axis instead.
	var inverted := up.dot(Vector3.UP) < 0.0

	# DEBUG, on the edge: an inverted machine rights itself, and a pilot who asks why theirs
	# rolled is the reason anybody reads this.
	if inverted != _inverted:
		_inverted = inverted
		DotLog.debug(CHANNEL, "a chopper went over on its back" if inverted else "a chopper righted itself", {
			"vehicle": _name(),
		})

	if axis.length() < 0.0001:
		if inverted:
			body.apply_torque(transform.basis.x * LEVEL_GAIN * body.mass * 0.4)
		return

	var angle := up.angle_to(Vector3.UP)

	body.apply_torque(axis.normalized() * angle * LEVEL_GAIN * body.mass * 0.4)

	# The damper, applied on the two axes the levelling owns and NOT on yaw — which is
	# the pilot's. A damper on all three would fight the pedals.
	var spin := body.angular_velocity
	spin.y = 0.0
	body.apply_torque(-spin * LEVEL_DAMPING * body.mass * 0.4)


## Removes the sideways drift a helicopter has no way to stop by itself.
func _apply_lateral_damping(
	body: RigidBody3D, transform: Transform3D, mass: float, delta: float
) -> void:
	var right := transform.basis.x
	right.y = 0.0

	if right.length() < 0.001:
		return

	var sideways := body.linear_velocity.dot(right.normalized())

	body.apply_central_force(
		-right.normalized() * sideways * LATERAL_DAMPING * mass * delta * 60.0
	)


func describe() -> Dictionary:
	var out := super.describe()
	var body := vehicle.body() if vehicle != null else null

	out["lift"] = "%.2fx" % lift_ratio
	out["gravity"] = "%.1f m/s2" % gravity
	out["ceiling"] = "%.0f m" % float(vehicle.meta.get(META_CEILING, 0.0)) if vehicle != null else "?"

	if body != null:
		out["altitude"] = "%.1f m" % body.global_position.y
		out["climb"] = "%.1f m/s" % body.linear_velocity.y

	return out


func _name() -> String:
	return String(vehicle.def.id) if vehicle != null and vehicle.def != null else "?"
