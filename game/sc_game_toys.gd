extends "sc_game_bots.gd"

## Part of [code]sc_game.gd[/code] (split for size): toys, held weapons, choppers and the reactions to props, platforms and deaths. Never used on its own.


## One tick of everybody's weapons and what they produced. Shots are resolved HERE rather than by the rig:
## zee-dot-weapons returns an outcome and applies nothing (a behaviour reaching into a `DotHealth` would be a client
## deciding who dies), and this game hands outcomes to dot-combat.
func _advance_weapons() -> void:
	if phase != Phase.SHOWDOWN or combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.weapons == null or not player.is_alive():
			continue

		var command := weapon_command_for(player)
		var outcome := player.weapons.simulate_tick(command, _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)


## The field's toys from its decks: a beach ball a little off the middle of every platform (not a bridge), on
## both ends in deck order, which is how a client pairs each with the server's entity. Called after the
## platforms are built: by the round on the server, by LAYOUT on a client.
func build_toys() -> void:
	clear_toys()
	var placements: Array = []
	for index in range(platforms.count()):
		var deck := platforms.deck_at(index)
		if deck == null or deck.is_bridge:
			continue
		# Toward the outer corner the platform leans to under nobody, never the middle: the
		# ball is the first thing to roll when somebody walks out to the edge.
		var off := Vector3(deck.half * 0.45, 0.0, -deck.half * 0.45).rotated(Vector3.UP, float(index) * PI * 0.5)
		var at := deck.centre + off
		placements.append({"toy": "beach_ball", "at": [at.x, at.y, at.z]})
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.rules = toy_rules
	toys.gravity = config.gravity
	toys.kill_y = -20.0
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"prop")
		toys.solid_mask = physics.collision_mask(&"prop")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"toy")
	add_child(toys)
	var built := toys.build(placements)
	if not built.ok:
		DotLog.warn(CHANNEL, "the field's toys would not build", {"why": built.error.message})
	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))


func clear_toys() -> void:
	if toys == null:
		return
	toys_clearing.emit()
	remove_child(toys)
	toys.queue_free()
	toys = null


## A toy made a sound, on whichever end draws it.
signal toy_sound(id: StringName, at: Vector3, strength: float)


## Everybody against the toys, after they moved: a walk into a ball sends it on. Server side.
func _advance_toys(delta: float) -> void:
	if toys == null or toys.count() == 0:
		return
	for id: StringName in players:
		var player: ScPlayer = players[id]
		if not player.is_alive():
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := toys.push_from(state.position, state.velocity, radius, height)
	toys.advance(delta)


## A shot against the toys: the first one on its ray is pushed and the shot goes on to the
## combat, whose trace never sees a toy, so a ball is never cover in the showdown. Server side.
func _shoot_toys(shot: DotShot) -> void:
	if not authoritative or toys == null or toys.count() == 0:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world"))


## Turns a player's movement command into a weapon command. The buttons are the game's to assign:
## dot-player-controller reserves three bits and this game spends all three (fire, alt-fire bash, reload); the slot
## wanted rides in this game's own input message, as the movement command has no room.
func weapon_command_for(player: ScPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(
		DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0)
	)
	command.set_button(
		DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1)
	)
	command.set_button(
		DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2)
	)
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot

	return command


## Turns each pilot's keys into a chopper's controls, and drops what they asked to drop.
func _fly_choppers(delta: float) -> void:
	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.riding:
			continue

		var instance_id := ride.vehicle_id_of(player.player_id)

		if instance_id == 0:
			continue

		var copter := vehicles.get_vehicle(instance_id)

		if copter == null or not copter.is_alive():
			continue

		# Only the pilot flies it. A passenger in the other seat is holding a rifle.
		if copter.seat_of(player.player_id) != &"pilot":
			continue

		var pending := player.controller.current_command
		var command := DotVehicleCommand.new()

		if pending != null:
			# The collective, which is the one control that is not where a player expects
			# it: jump climbs and crouch descends, so the two keys that already mean up and
			# down keep meaning up and down.
			var up := 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_JUMP) else 0.0
			var down := 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_CROUCH) else 0.0
			command.throttle = up - down
			command.steer = clampf(pending.move.x, -1.0, 1.0)
			command.brake = 1.0 if pending.is_pressed(DotFpsCommand.BUTTON_WALK) else 0.0
			command.aim_yaw = pending.yaw
			command.aim_pitch = pending.pitch

			copter.meta[ScCopter.META_CYCLIC] = Vector2(0.0, clampf(pending.move.y, -1.0, 1.0))

		copter.command = command

		var chassis := copter.chassis as DotVehicleChassis

		if chassis != null:
			chassis.drive(command, delta)

		_advance_drop(copter, player, pending, delta)


## The pilot's trigger, which drops a prop rather than firing anything: a chopper that only flies is a sightseeing
## tour, and one that can put a crate on somebody's platform is a second cannon with a person aiming it, which has
## to be overhead and so can be seen coming.
func _advance_drop(
	copter: DotVehicleInstance, player: ScPlayer, pending: DotFpsCommand, delta: float
) -> void:
	if not config.chopper_may_drop or pending == null or cannon == null:
		return

	var since := float(_copter_drop.get(copter.instance_id, 0.0)) + delta
	_copter_drop[copter.instance_id] = since

	if since < config.chopper_drop_interval:
		return

	if not pending.is_pressed(DotFpsCommand.BUTTON_USER_0):
		return

	var body := copter.body()

	if body == null:
		return

	var bay := body.get_node_or_null(^"DropBay") as Node3D
	var from := bay.global_position if bay != null else body.global_position - Vector3.UP * 2.2

	# It leaves with the machine's own velocity, which is what makes aiming one a skill
	# rather than a button: a crate dropped from a chopper doing fifteen metres a second
	# lands a long way in front of where it was let go.
	var tier := clampi(config.chopper_drop_tier, 1, ScContent.TIERS)
	var dropped := cannon.drop(from, body.linear_velocity, tier)

	if dropped != null:
		_copter_drop[copter.instance_id] = 0.0
		DotLog.debug(CHANNEL, "a chopper dropped something", {
			"pilot": String(player.player_id),
		})


func _on_platform_collapsed(index: int, why: StringName) -> void:
	if progress != null:
		progress.on_platform_collapsed(index, why)

	platform_collapsed.emit(index, why)


func _on_platform_struck(index: int, at: Vector3, impulse: float, outcome: int) -> void:
	if progress != null:
		progress.on_platform_struck(index, at, outcome)

	platform_struck.emit(index, at, impulse, outcome)


func _on_prop_spawned(_prop: DotPropInstance) -> void:
	pass


func _on_prop_removed(prop: DotPropInstance, _reason: StringName) -> void:
	_prop_velocity.erase(prop.instance_id)

	if cannon != null:
		cannon.forget(prop.instance_id)


## A barrel went off. dot-props described the blast; this is what it does to people. The split is the addon
## boundary: dot-props knows props and nothing else (a player needs another id space and authority), so it shoves
## the other props itself and hands the rest over here.
func _on_prop_exploded(
	at: Vector3, radius: float, damage_amount: float, force: float, by: StringName
) -> void:
	blast.emit(at, radius)

	var attacker := 0

	if players.has(by):
		attacker = (players[by] as ScPlayer).entity_id

	# A blast under a platform lifts it, which is the one way a barrel can save somebody:
	# it throws the thing that was about to crush them off its own line.
	var index := platforms.index_at(at.x, at.z)

	if index >= 0:
		var _hit := platforms.report_impact(
			index, damage_amount, radius * 0.5, at + Vector3(0.0, 0.5, 0.0)
		)

	if combat == null:
		return

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if not player.is_alive() or player.riding:
			continue

		var offset := player.controller.state.position - at
		var distance := offset.length()

		if distance > radius:
			continue

		var falloff := 1.0 - (distance / radius)
		var damage := DotDamage.make(
			attacker, player.entity_id, damage_amount * falloff, null
		)
		damage.point = player.controller.state.position
		damage.direction = offset.normalized() if distance > 0.01 else Vector3.UP
		damage.tick = _tick
		damage.context = {"why": DIED_BLAST}

		var _applied := combat.apply_damage(damage)

		# Thrown, and a barrel is the only thing in the survival phase that throws a player
		# UPWARD. It is the one way back onto a platform you have already fallen off the
		# edge of, and it is why standing near one is worth doing as well as worth avoiding.
		var push := damage.direction * force * falloff * 0.0035
		player.controller.state.velocity += push + Vector3.UP * falloff * 4.5


func _on_player_died(player: ScPlayer, damage: DotDamage) -> void:
	# One dictionary read of the reverse index [DotEntityTable] keeps, instead of walking every player comparing
	# ints, on every death. An attacker of 0 is dot-combat's "the world" (a fall, a crate, a barrel nobody set off),
	# for which the table returns an empty key.
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	# Before dot-match hears of it, and the order is the reason: `report_kill` can END the round synchronously (the
	# last of a side going is an elimination), dropping the phase to IDLE and filing the numbers, so a kill counted
	# after that is in no phase and no round. The winning shot of every showdown was missing.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			config.deck_height, _tick
		)

	if progress != null:
		progress.on_died(
			player.player_id, by, why == DIED_FELL,
			phase == Phase.HANDOVER or phase == Phase.SHOWDOWN
		)

	# [b]Only a player is reported to dot-match.[/b] Anything registered with dot-combat arrives at this
	# handler looking the same, and a scoreboard row filed against a falling crate is a row nobody can
	# explain. The kind is in the id, which is what dot-entity's whole layout is for.
	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(
			String(by), String(player.player_id), why, _tick
		)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	if authoritative:
		player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why, damage.weapon_id)
	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: ScPlayer, shot: DotShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == DotHitGroup.HEAD)


## Where chopper [param index] is parked on [param on_layout]: the middle of the platform the layout names for the
## first ([member ScLayouts.Layout.chopper_cell], a bridge's middle when [member
## ScLayouts.Layout.chopper_on_bridge]), the arena's ordinary pads for the rest.
func chopper_pad_on(on_layout: ScLayouts.Layout, index: int) -> Vector3:
	if on_layout != null and index == 0 and on_layout.chopper_cell.x >= 0:
		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if deck.is_bridge == on_layout.chopper_on_bridge \
					and deck.column == on_layout.chopper_cell.x \
					and deck.row == on_layout.chopper_cell.y:
				return Vector3(deck.centre.x, config.deck_height + config.chopper_pad_height,
					deck.centre.z)

	return arena.chopper_pad(index, config.chopper_count)


func _place_choppers() -> void:
	if not config.chopper_enabled or layout == null or not layout.with_chopper:
		return

	for index in range(config.chopper_count):
		var at := chopper_pad_on(layout, index)
		var copter := vehicles.spawn(ScContent.COPTER, at, ScContent.WORLD_OWNER)

		if copter == null:
			DotLog.warn(CHANNEL, "a chopper could not be spawned", {"index": index})
			continue

		_copter_ids.append(copter.instance_id)
		_copter_drop[copter.instance_id] = 0.0

		copter.meta[ScCopter.META_CEILING] = config.deck_height + config.chopper_ceiling
		copter.meta[ScCopter.META_CYCLIC] = Vector2.ZERO

		var chassis := copter.chassis as ScCopter

		if chassis != null:
			chassis.lift_ratio = config.chopper_lift
			chassis.gravity = config.gravity * maxf(active.gravity_scale, 0.05)

		var body := copter.body()

		if body != null:
			body.set_meta(ScPlayer.META_CARRIER, true)

		if body != null and physics != null:
			var applied := physics.apply_to(body, &"vehicle")

			if not applied.ok:
				DotLog.warn(CHANNEL, "a chopper could not be put on its layer", {
					"why": applied.error.message,
				})


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})
