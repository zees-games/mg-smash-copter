extends "sc_platforms_base.gd"

## The torsion-spring model and impacts: the half of the field that moves. [ScPlatforms] adds the building and the queries.


## Clears the loads gathered for the previous tick. Call before the first [method add_load].
func begin_loads() -> void:
	for deck in decks:
		deck.load_torque = Vector2.ZERO
		deck.load_mass = 0.0


## Puts a weight on a platform at a world position.
##
## [param motion] is how fast the load moves over the deck, in m/s (the walk key; see [member ScConfig.platform_motion_gain]). A prop passes zero.
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
## Semi-implicit: advance the velocity first and the angle from the NEW velocity. Explicit Euler adds energy every step, so a settling spring grows until it throws the platform off its pillar.
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

		# The sink is the same spring on one axis, felt as the platform taking weight. Cosmetic, but a platform that never moves vertically reads as scenery.
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
	deck.lean += axis * config.fall_tip_rate * delta
	deck.sink_velocity -= gravity * config.fall_gravity_scale * delta
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
## The basis is built from the normal, not two Euler angles: composing X and Z rotations depends on order, and the order that is right at five degrees is visibly wrong at fifteen.
func _draw(deck: Deck) -> void:
		# In the tree as well as valid: a field cleared between ticks leaves bodies out of the tree awaiting free, and writing a transform on one is an engine error. See [method ScPropNet._drawable].
	if deck.body == null or not is_instance_valid(deck.body) or not deck.body.is_inside_tree():
		return

	var normal := deck.normal()
	var axis := Vector3.UP.cross(normal)
	var basis := Basis.IDENTITY

		# The near-parallel case first: a zero cross product has no rotation axis, so the axis-angle form divides by zero and fills the basis with NaN, which draws and collides with nothing.
	if axis.length() > 0.0001:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(normal))

	deck.body.global_transform = Transform3D(
		basis, deck.centre + Vector3(0.0, deck.sink, 0.0)
	)


## Metres the surface moved under a point since the last [method step].
##
## The same offset on both sides of the subtraction: what is wanted is what the PLATFORM did, and measuring at the old position would fold the player's own walking in and carry them twice.
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



## Something landed on a platform. Returns what it did.
##
## [param kilos] and [param speed] are the body's mass and arrival speed; everything is decided from their product, the momentum the platform absorbs.
func report_impact(index: int, kilos: float, speed: float, at: Vector3) -> Impact:
	var deck := deck_at(index)

	if deck == null or not deck.is_standing():
		return Impact.NONE

	var impulse := absf(kilos) * absf(speed)

	if impulse <= 0.0:
		return Impact.NONE

	var offset := Vector2(at.x - deck.centre.x, at.z - deck.centre.z)

		# Dead centre has no lever arm, so a minimum arm of a quarter of the platform keeps a monolith on the pillar from being absorbed unnoticed.
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
## [param strength] is in radians per second of lean velocity, in a direction drawn from [param stream] so peers on one seed shake the same way.
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

		# The collider goes now, not when the slab has finished falling: a rider would be carried forty metres by a floor already gone for everyone else and land alive on the kill plane.
	var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D if deck.body != null else null

	if collider != null:
		collider.disabled = true

	if deck.body != null and is_instance_valid(deck.body):
		_by_body.erase(deck.body.get_instance_id())

	collapsed.emit(index, why)
	DotLog.debug(CHANNEL, "a platform came off its pillar", {
		"index": index, "cell": "%d,%d" % [deck.column, deck.row], "why": String(why),
	})



## Adopts a platform's state from the wire. Client side; see [ScPlatformNet].
##
## The collider follows the state, so the floor goes at the moment the server took it away.
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

				# Out of the reverse index the moment it stops STANDING: that index resolves a motor's `ground_id`, and the server drops it as soon as the platform leaves its pillar, so the two ends must agree about what is underfoot.
		if state != State.STANDING and deck.body != null and is_instance_valid(deck.body):
			_by_body.erase(deck.body.get_instance_id())

		if state == State.GONE and deck.body != null and is_instance_valid(deck.body):
			deck.body.queue_free()
			deck.body = null

	_draw(deck)



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


func deck_at(index: int) -> Deck:
	return decks[index] if index >= 0 and index < decks.size() else null


func _surface_y_of(deck: Deck, x: float, z: float) -> float:
	var normal := deck.normal()

	if absf(normal.y) < 0.001:
		return deck.centre.y + deck.sink

	var offset := Vector2(x - deck.centre.x, z - deck.centre.z)
	return deck.centre.y + deck.sink - (normal.x * offset.x + normal.z * offset.y) / normal.y


## Half the platform's footprint on each axis, in metres.
func _footprint(deck: Deck) -> Vector2:
	var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D

	if collider == null:
		return Vector2(deck.half, deck.half)

	var box := collider.shape as BoxShape3D
	return Vector2(box.size.x, box.size.z) * 0.5 if box != null else Vector2(deck.half, deck.half)
