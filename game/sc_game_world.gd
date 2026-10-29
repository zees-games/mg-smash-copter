extends "sc_game_toys.gd"

## Part of [code]sc_game.gd[/code] (split for size): special rounds, wind, quakes, platform loads, props landing and falls. Never used on its own.


func _clear_world() -> void:
	clear_toys()

	for prop in props.all_props():
		cannon.forget(prop.instance_id)
		var _gone := props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

	_prop_velocity.clear()

	for instance_id in _copter_ids:
		var copter := vehicles.get_vehicle(instance_id)

		if copter == null:
			continue

		# Riders out before the machine goes: `DotVehicleRide` holds its own index and does not watch the spawner,
		# so a chopper removed under somebody leaves them "already in a vehicle" for good. `occupants` is keyed by
		# SEAT and valued by RIDER, and `exit` wants the rider, not the seat name.
		for rider_id: StringName in copter.occupants.values():
			var _out := ride.exit(copter, rider_id, true)

		var _removed := vehicles.remove(instance_id)

	_copter_ids.clear()
	_copter_drop.clear()


func _roll_round_special() -> void:
	_special_until.clear()
	_round_special = &""
	_last_special_tick = _tick

	if not config.specials_enabled:
		_refold()
		return

	var stream := random.stream(&"specials")

	if stream.next_range_f(0.0, 100.0) >= config.special_round_chance:
		_refold()
		return

	var special := ScSpecials.pick(config, stream)

	if special == null:
		_refold()
		return

	_round_special = special.id
	_refold()

	special_changed.emit(special.id, true, special.blurb)
	DotLog.info(CHANNEL, "this round is a special", {"special": String(special.id)})


## Mid-round specials: when one starts, and when the running ones stop.
func _advance_specials(delta: float) -> void:
	var changed := false

	for id: StringName in _special_until.keys():
		var left := float(_special_until[id]) - delta

		if left > 0.0:
			_special_until[id] = left
			continue

		_special_until.erase(id)
		changed = true

		var special := ScSpecials.by_id(id)
		special_changed.emit(id, false, special.display_name if special != null else "")

	if _may_roll_mid_round():
		var stream := random.stream(&"specials")
		var special := ScSpecials.pick(config, stream)

		if special != null and not _special_until.has(special.id) and special.id != _round_special:
			_special_until[special.id] = config.special_seconds
			_last_special_tick = _tick
			changed = true
			special_changed.emit(special.id, true, special.blurb)
			DotLog.info(CHANNEL, "something changed mid-round", {
				"special": String(special.id),
			})

	if changed:
		_refold()

	_advance_quake(delta)


func _may_roll_mid_round() -> bool:
	if not config.specials_enabled or not config.specials_mid_round:
		return false

	if phase != Phase.SURVIVAL:
		return false

	# A pure function of the tick, which is why dot-core has a schedule: a server and a replay of it agree when the
	# gravity went off without a message, where a per-tick roll from a stream would differ on a machine that had
	# drawn a different number of times.
	var plan := ScSpecials.schedule(config, tick_rate)
	return plan.fires_at(random.stream(&"special_clock"), _tick, _last_special_tick)


## Recomputes what is in force and puts it on everything that reads it. [b]One place, and everything
## downstream is told rather than asking.[/b] The alternative is every consumer folding the list itself, which
## is five copies of the same loop and five chances for one of them to miss a special that started this tick.
func _refold() -> void:
	active = ScSpecials.Active.new()

	if _round_special != &"":
		var round_one := ScSpecials.by_id(_round_special)

		if round_one != null:
			active.fold(round_one)

	for id: StringName in _special_until:
		var special := ScSpecials.by_id(id)

		if special != null:
			active.fold(special)

	_apply_gravity()

	platforms.stiffness_scale = layout.stiffness_scale * active.stiffness_scale if layout != null \
		else active.stiffness_scale
	platforms.grip = config.platform_grip * active.grip_scale
	platforms.gravity = config.gravity * maxf(active.gravity_scale, 0.05)

	for id: StringName in players:
		(players[id] as ScPlayer).retune(active)

	for instance_id in _copter_ids:
		var copter := vehicles.get_vehicle(instance_id)
		var chassis := copter.chassis as ScCopter if copter != null else null

		if chassis != null:
			chassis.gravity = config.gravity * maxf(active.gravity_scale, 0.05)


func _clear_specials() -> void:
	_special_until.clear()
	_round_special = &""
	_refold()


## Which way the wind blows this round. Drawn once, so it is a fact about the round.
func _draw_wind_heading() -> Vector3:
	var angle := random.stream(&"weather").next_range_f(0.0, TAU)
	return Vector3(cos(angle), 0.0, sin(angle))


## Pushes everything loose the way the wind is going: props and players, not the platforms (bolted to a pillar, they
## feel it as what they push). An acceleration rather than a force, so a crate and a monolith drift at the same
## rate, as wind does.
func _apply_wind(delta: float) -> void:
	if active.wind <= 0.0:
		return

	var push := _wind_heading * active.wind

	for prop in props.all_props():
		var body := prop.body()

		if body != null and not body.freeze:
			body.apply_central_force(push * body.mass)

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		# Only in the air. A person leaning into a gale is still walking; a person who has
		# just jumped between two platforms is a sail, and that is the moment the wind is
		# supposed to be frightening.
		if player.controller.state.mode == DotFpsState.Mode.AIR:
			player.controller.state.velocity += push * delta


func _advance_quake(delta: float) -> void:
	if active.quake <= 0.0:
		_since_quake = 0.0
		return

	_since_quake += delta

	if _since_quake < active.quake_interval:
		return

	_since_quake = 0.0
	platforms.shake_all(random.stream(&"quake"), active.quake)


## Tells every platform what is standing on it this tick, gathered here rather than pushed by each thing, because
## the model needs one consistent set: what tips a platform is the sum, and the sum has to be taken between one step
## and the next, not by whichever arrived last.
func _load_platforms() -> void:
	platforms.begin_loads()

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		var index := player.standing_on

		if index < 0:
			continue

		platforms.add_load(
			index,
			player.controller.state.position,
			player.mass_kg,
			player.ground_speed()
		)

	for prop in props.all_props():
		var body := prop.body()

		if body == null or not prop.is_alive():
			continue

		var at := body.global_position
		var index := platforms.index_at(at.x, at.z)

		if index < 0 or not platforms.is_on(index, at, 1.8):
			continue

		# A prop is a dead weight: it contributes its mass and no motion gain. A crate
		# sliding across a leaning platform is already making the lean worse by moving its
		# own offset, which is the honest amount of feedback and needs no second term.
		platforms.add_load(index, at, prop.def.mass, 0.0)


## Watches everything in the air for the moment it stops being in the air: a velocity drop rather than a contact
## signal, because an impulse is not readable in `linear_velocity` until its step has run. It needs no contact
## monitoring and a headless suite can drive it by hand.
func _watch_props(delta: float) -> void:
	var seen: Dictionary = {}

	for prop in props.all_props():
		var body := prop.body()

		if body == null or not prop.is_alive():
			continue

		var instance_id := prop.instance_id
		seen[instance_id] = true

		var was: Vector3 = _prop_velocity.get(instance_id, Vector3.ZERO)
		var now := body.linear_velocity
		_prop_velocity[instance_id] = now

		if was.y > -config.impact_min_speed:
			continue

		# It lost most of its downward speed in one step, so something stopped it.
		if now.y < was.y * (1.0 - config.impact_loss):
			continue

		_land(prop, body.global_position, -was.y, delta)

	for key: int in _prop_velocity.keys():
		if not seen.has(key):
			_prop_velocity.erase(key)


## Something arrived. What it hit, and what that cost.
func _land(prop: DotPropInstance, at: Vector3, speed: float, _delta: float) -> void:
	var impulse := prop.def.mass * speed

	var index := platforms.index_at(at.x, at.z)

	if index >= 0 and platforms.is_on(index, at, 2.2):
		var outcome := platforms.report_impact(index, prop.def.mass, speed, at)

		if outcome == ScPlatforms.Impact.NONE:
			return

	# And the prop's own health, which is dot-props' half: a barrel that lands hard goes off, a crate splits,
	# a boulder does not notice. `impact` is a SPEED test rather than a damage one for exactly this reason —
	# what breaks a crate is how fast the floor arrived, not how many times it has been leant on.
	if prop_damage != null:
		var _broke := prop_damage.impact(prop.instance_id, speed, ScContent.WORLD_OWNER)

	_crush_nearby(at, impulse)


## Who was standing where that landed, hurt in proportion to the momentum: a crate at terminal velocity is a bruise
## and the tier-four prop is not survivable, the same ordering the platforms are hurt in and the reason the tiers
## can be read off the sky.
func _crush_nearby(at: Vector3, impulse: float) -> void:
	if combat == null or impulse <= 0.0:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.riding or not player.is_alive():
			continue

		var offset := player.controller.state.position + Vector3.UP * 0.9 - at

		if offset.length() > config.impact_hurt_radius:
			continue

		var falloff := 1.0 - clampf(offset.length() / config.impact_hurt_radius, 0.0, 1.0)
		var amount := impulse * config.impact_hurt_per_impulse * falloff

		if amount < 1.0:
			continue

		var damage := DotDamage.make(0, player.entity_id, amount, null)
		damage.point = player.controller.state.position
		damage.direction = Vector3.DOWN
		# [b]Stamped, and a damage event with no tick is refused for ever.[/b] Spawn protection compares
		# against `invulnerable_until_tick`, and a tick of zero is always before it — so every crush in the
		# handover would be silently discarded and the ones after it would not, with nothing to say why.
		damage.tick = _tick
		damage.context = {"why": DIED_CRUSHED}

		var _applied := combat.apply_damage(damage)

		# Knocked sideways as well as hurt, because a landing that leaves somebody standing exactly where they
		# were is the one thing here that would look broken from every angle — and on a platform that is
		# already leaning, being shoved is most of the danger.
		var shove := Vector3(offset.x, 0.0, offset.z)

		if shove.length() > 0.01:
			player.controller.state.velocity += shove.normalized() * minf(
				impulse * 0.004 * falloff, 9.0
			)


## Everybody who has run out of map, by a height comparison rather than a trigger volume: the floor is the only
## thing nobody survives, and at speed a falling body crosses a sixteen-unit trigger between two ticks without ever
## being inside it.
func _watch_falls() -> void:
	if combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_alive() or not can_be_harmed(id):
			continue

		if player.riding:
			_watch_rider_fall(player)
			continue

		# Reaching the floor, not passing through it: see FLOOR_REACH.
		if player.controller.state.position.y > config.kill_height + FLOOR_REACH:
			continue

		_kill_by_fall(player, player.controller.state.position)


## A rider falls with the machine; skipping riders made the floor survivable. A rider's own position is where they
## boarded, so measure the MACHINE: within [constant COPTER_FLOOR_CLEARANCE] of the floor has reached it (its origin
## rests that far up on its skids). Out of the seat first, or [method _clear_world] exits somebody not there.
func _watch_rider_fall(player: ScPlayer) -> void:
	var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player.player_id))
	var body := aboard.body() if aboard != null else null

	if body == null or body.global_position.y > config.kill_height + COPTER_FLOOR_CLEARANCE:
		return

	var at := body.global_position
	var _out := ride.exit(aboard, player.player_id, true)

	_kill_by_fall(player, at)


func _kill_by_fall(player: ScPlayer, at: Vector3) -> void:
	var damage := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
	damage.point = at
	damage.direction = Vector3.DOWN
	damage.tick = _tick
	damage.context = {"why": DIED_FELL}

	var _applied := combat.apply_damage(damage)
