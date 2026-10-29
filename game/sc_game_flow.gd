extends "sc_game_world.gd"

## Part of [code]sc_game.gd[/code] (split for size): players joining and leaving, the round and its phases, the handover and the guns dealt. Never used on its own.


## The two overview cameras, from the field this round was actually laid out as, not from the configuration: the
## chequerboard pulls its rows in and shifts the field half a row, so a camera aimed at the configured middle looks
## at the hole the tube stands in.
func _refresh_overviews() -> void:
	if spectate == null or platforms == null or arena == null:
		return

	var centre := Vector3.ZERO
	var counted := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck != null:
			centre += deck.centre
			counted += 1

	if counted > 0:
		centre /= float(counted)
	else:
		centre = Vector3(0.0, config.deck_height, 0.0)

	var reach := 0.0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck != null:
			reach = maxf(reach, Vector2(
				deck.centre.x - centre.x, deck.centre.z - centre.z
			).length() + deck.half)

	# From the side away from the showdown, which is along -Z, so the corners are in the
	# back of the same shot.
	var eye := centre + Vector3(0.0, reach * 0.8 + 12.0, reach * 1.25 + 10.0)
	var field := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)

	var middle := arena.showdown_centre()
	var over := middle + Vector3(0.0, 26.0, config.corner_distance * 0.9 + 18.0)
	var showdown := Transform3D(Basis.IDENTITY, over).looking_at(middle, Vector3.UP)

	spectate.set_overviews(field, showdown)


## Puts somebody in the world. [param wanted_team] is a team id, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_team: int = 0,
	samples_input: bool = false
) -> ScPlayer:
	if players.has(player_id):
		return players[player_id]

	var team := wanted_team if wanted_team != 0 else _side_for_new_player()

	var player := ScPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	# Before `add_child`, because `_ready` is what builds the controller and its tunables.
	player.config = config
	player.active = active
	player.mass_kg = config.player_mass
	player.platforms = platforms
	player.team = team
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which is a separate number and defaults to 1. A
		# controller left on the default sweeps against layer one only — which after a
		# layout has moved the world off bit zero is a player who falls through the map.
		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER,
		player,
		&"",
		player_id,
		float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		# A refusal here means this player id is already an entity, which cannot happen — `add_player` returns
		# early on a duplicate. Logged rather than ignored, because arming them anyway would register a second
		# health record against one body and the symptom of that is a player taking half damage.
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = team

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, team)

		# ERROR, because a refusal here leaves the round rule counting a side short, and the
		# last time one was refused nothing said so.
		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player's side", {
				"id": String(player_id), "team": team, "why": seated.error.message,
			})

	# Placed NOW, not only at the top of a round: `_place_players` runs when a round is laid out, so a mid-round
	# joiner started at the origin, forty metres below the platforms, died on their first tick and on a two-team
	# server ended the round inside the netcode's identity loop.
	place_one(player)

	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "team": team})

	# Last, after the health and the side: the bridge answers this by building the
	# replicated entity and announcing the join, and an entity built over a half-made
	# player replicates the half.
	player_added.emit(player_id)
	return player


## Somewhere on a player that a shot can land: [DotCombatManager] traces against registered [DotHitboxSet]s, so a
## player with a `DotHealth` and no hitboxes is silently bulletproof. Two boxes (a head worth more than a chest, for
## the sniper) with `precedence` set, not left to child order.
func _give_hitboxes(player: ScPlayer) -> void:
	var boxes := DotHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = DotNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := DotHitbox.new()
	body.name = "Chest"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, ScPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can stand without disturbing anybody else: their own side's platform if it is
## still up, any standing one otherwise. When the whole field has gone that is where the field WAS, a fall, which is
## honest: the next round is seconds away.
func place_one(player: ScPlayer) -> void:
	if platforms == null:
		return

	var standing: Array[int] = []

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		# Never a tower: it is a small deck three steps up, the prize and not the start.
		if deck != null and deck.is_standing() and not deck.is_tower:
			standing.append(i)

	if standing.is_empty():
		player.place_at(
			Vector3(0.0, config.deck_height + 2.0, 0.0),
			0.0
		)
		return

	# The same arithmetic `_place_players` uses, so a joiner lands with their own side
	# rather than somewhere a second rule chose.
	var slot := maxi(player.team - 1, 0) * maxi(standing.size() / maxi(config.team_count, 1), 1)
	var index: int = standing[clampi(slot, 0, standing.size() - 1)]
	var deck := platforms.deck_at(index)

	# Off centre by a little and away from the middle, so two people joining in the same
	# second are not put inside each other — which the solver resolves by flinging one of
	# them off the platform.
	var angle := float(players.size()) * 1.7
	var reach := minf(deck.half * 0.5, 2.6)
	var at := deck.centre + Vector3(cos(angle) * reach, 1.2, sin(angle) * reach)
	var inward := deck.centre - at

	player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))

	if spectate != null:
		spectate.on_spawned(player.player_id)


## Which side somebody new goes on: the smallest one, ties to the lower id. [b]Explicitly, rather than left to
## a dictionary's order.[/b] A server and a client that disagree about somebody's side disagree about friendly
## fire, which is a player who cannot damage the enemy and can damage their own.
func _side_for_new_player() -> int:
	var counts: Array[int] = []
	counts.resize(config.team_count)
	counts.fill(0)

	for id: StringName in sides:
		var team := int(sides[id])

		if team >= 1 and team <= config.team_count:
			counts[team - 1] += 1

	var smallest := 0

	for index in range(config.team_count):
		if counts[index] < counts[smallest]:
			smallest = index

	return smallest + 1


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: ScPlayer = players[player_id]

	if ride != null and ride.is_riding(player_id):
		var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player_id))

		if aboard != null:
			var _left := ride.exit(aboard, player_id, true)

	# Before the node goes: dot-combat keyed a `DotHealth` on this entity and nothing else tells it to let go, so
	# every player who ever joined would leave a record pointing at a freed node. A stale entity is never asked
	# about, so the leak shows nothing until memory runs out.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	player.queue_free()

	# After the roster has dropped them: dot-spectate picks a watcher's replacement target
	# from the roster, and one still holding the leaver picks the leaver.
	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func start() -> void:
	if not authoritative:
		return

	# Laid out here and not only on `round_started`: dot-match runs a warmup before the first round, so a world
	# furnished only when a round began would sit through it as a bare floor with a tube, indistinguishable from a
	# map that failed to load.
	_lay_out_round()
	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	round_elapsed = 0.0

	if config.vary_layout:
		# Derived from the configured seed and the round number rather than from a clock, so a server and a
		# replay of it play the same round. `hash` would do; this is one multiply and is stable across engine
		# versions, which `hash` on a built-in is not promised to be.
		_layout_seed = config.seed_value + number * 7919
		random.reseed(_layout_seed)

	_lay_out_round()
	_roll_round_special()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.SURVIVAL)

	round_began.emit(number, layout.id if layout != null else &"")
	DotLog.info(CHANNEL, "round began", {
		"number": number,
		"layout": String(layout.id) if layout != null else "?",
		"special": String(_round_special),
		"seed": _layout_seed,
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_clear_specials()

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": winner})


## Every layout this server plays, as the map menu (M) lists them: `{id, name, detail,
## current}`, the blurb under the name. Solo the client's list, online the server's (the module
## hands it to dot-vote's map menu), so both say the same.
func layout_rows() -> Array:
	var out: Array = []
	for l in ScLayouts.allowed(config):
		var listed := not layout_in_rotation_fn.is_valid() or bool(layout_in_rotation_fn.call(l.id))
		out.append({"id": String(l.id), "name": l.display_name,
			"detail": l.blurb if listed else ("%s (not in rotation)" % l.blurb).strip_edges(),
			"current": layout != null and l.id == layout.id})
	return out


## The map menu's change: [param id] now, not after this round. The next layout is set and a
## fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running the field is simply laid out again. Authority only.
func change_layout_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the layout.")
	if not ScLayouts.allowed(config).any(func(l: ScLayouts.Layout) -> bool: return l.id == id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no layout called '%s' here." % id)
	next_layout_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_round()
	DotLog.info(CHANNEL, "layout changed from the map menu", {"layout": String(id)})
	return DotResult.success(id)


## Everything that happens between one round and the next.
func _lay_out_round() -> void:
	world_clearing.emit()
	_clear_world()

	# A new round is a new aim for every stand-in, seeded with the round, so the next fight
	# between stand-ins is a different one (see [method _bot_aim_of]).
	_bot_aims.clear()
	_bot_triggers.clear()
	_bot_charges.clear()

	var stream := random.stream(&"layout")
	var voted: ScLayouts.Layout = null

	# What the players voted for, once, if this server still plays it (an operator can narrow
	# `layout_ids` between the vote and the round). The draw otherwise.
	if next_layout_id != &"":
		for allowed in ScLayouts.allowed(config):
			if allowed.id == next_layout_id:
				voted = allowed

	next_layout_id = &""
	layout = voted if voted != null else ScLayouts.pick(config, stream, layout_in_rotation_fn)

	platforms.gravity = config.gravity * maxf(active.gravity_scale, 0.05)
	platforms.build(layout, physics)
	_refresh_overviews()
	build_toys()

	cannon.stream = random.stream(&"cannon")
	cannon.begin_round()

	_wind_heading = _draw_wind_heading()

	_place_players()
	_place_choppers()

	# Last, after everything is standing. A bridge answers this by replicating every
	# platform and announcing the layout, and a field announced half way through being built
	# is a client drawing a floor the server has already replaced.
	world_rebuilt.emit()


## Seats [param roster] round the middle of [param deck], facing in, armed with nothing.
func _seat_roster(roster: Array, deck: ScPlatforms.Deck) -> void:
	for seat in range(roster.size()):
		var player: ScPlayer = roster[seat]

		if player.health != null:
			player.health.health = config.player_health
			player.health.alive = true
			player.health.invulnerable = false

		_disarm(player)

		var angle := TAU * float(seat) / float(maxi(roster.size(), 1))
		var reach := minf(deck.half * 0.5, 2.6)
		var at := deck.centre + Vector3(cos(angle) * reach, 1.2, sin(angle) * reach)

		# Facing the middle of their own platform, which is the one direction that is
		# never immediately fatal.
		var inward := deck.centre - at
		player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))
		player.carried_metres = 0.0
		player.retune(active)

		# Everybody is back in the world, so nobody is watching any more.
		if spectate != null:
			spectate.on_spawned(player.player_id)


## Puts everybody on a platform, by side. [b]A side to a column block, so a team starts together.[/b] Six
## people scattered at random across a field of platforms is six separate games; a team that starts on one
## platform has an immediate problem, which is that all of them standing on it is exactly what tips it over.
func _place_players() -> void:
	var stream := random.stream(&"spawns")
	var standing: Array[int] = []

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		# Never a tower: it is a small deck three steps up, the prize and not the start.
		if deck != null and deck.is_standing() and not deck.is_tower:
			standing.append(i)

	if standing.is_empty():
		return

	var island := ScLayouts.islands(platforms.cells(), layout.jumps if layout != null else 0)
	var claimed: Dictionary = {}

	for team in range(1, config.team_count + 1):
		var roster := players_on(team)

		if roster.is_empty():
			continue

		# Teams are spread across the field rather than placed adjacently: which platform a
		# side gets is decided by its id so that two servers on one seed agree, and by the
		# number of sides so that six teams do not all start in the middle.
		var slot := (team - 1) * maxi(standing.size() / maxi(config.team_count, 1), 1)
		var index: int = standing[clampi(slot, 0, standing.size() - 1)]

		# And not onto ground another side can already reach while some ground is unclaimed: the spread above puts
		# two sides at both ends of the first column, a bridge apart on a one-piece field, and on Two Islands both
		# sides landed on one island. An all-one-island layout never takes this branch.
		if claimed.has(island[index]):
			for other: int in standing:
				if not claimed.has(island[other]):
					index = other
					break

		claimed[island[index]] = true
		var deck := platforms.deck_at(index)

		_seat_roster(roster, deck)

	# Anybody on no side at all — a spectator, a test's stand-in — goes somewhere valid
	# rather than at the origin, which in this map is inside the cannon.
	for id: StringName in players:
		var team := int(sides.get(id, 0))

		if team >= 1 and team <= config.team_count:
			continue

		var deck := platforms.deck_at(standing[stream.next_range_i(0, standing.size() - 1)])
		(players[id] as ScPlayer).place_at(deck.centre + Vector3.UP * 1.2, 0.0)


## The clock, and the one handover it decides.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	round_elapsed += delta

	match phase:
		Phase.SURVIVAL:
			if round_elapsed >= config.survival_seconds:
				_begin_handover()
		Phase.HANDOVER:
			if round_elapsed >= config.showdown_starts_at():
				_begin_showdown()
		Phase.SHOWDOWN:
			pass


## The teleport, the weapons, and the few seconds nobody can fire: a player is moved sixty metres, handed a weapon
## and put beside two people who want to shoot them in one tick. The pause is spent invulnerable, not just unarmed,
## because a chopper is still flying and a prop still falling.
func _begin_handover() -> void:
	_set_phase(Phase.HANDOVER)

	if config.clear_platforms_for_showdown:
		for i in range(platforms.count()):
			var _fell := platforms.collapse(i, ScPlatforms.WHY_ROUND)

	for team in range(1, config.team_count + 1):
		var roster: Array[ScPlayer] = []

		for player in players_on(team):
			if player.is_alive():
				roster.append(player)

		for seat in range(roster.size()):
			var player: ScPlayer = roster[seat]

			if player.riding:
				var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player.player_id))

				if aboard != null:
					var _out := ride.exit(aboard, player.player_id, true)

			player.place_at(
				arena.showdown_spawn(team - 1, config.team_count, seat, roster.size()),
				arena.showdown_yaw(team - 1, config.team_count)
			)

			if player.health != null:
				player.health.invulnerable = true

			_arm(player, team, seat)

	if progress != null:
		progress.on_handover()

	DotLog.info(CHANNEL, "the survivors are in the corners", {
		"alive": alive_count(), "teams": teams_alive(),
	})


func _begin_showdown() -> void:
	_set_phase(Phase.SHOWDOWN)

	for id: StringName in players:
		var player: ScPlayer = players[id]

		if player.health != null:
			player.health.invulnerable = false


## Hands a survivor what they will finish the round with. Drawn, not chosen, and the draw is seeded: the first half
## was decided by footing and the second begins with everybody equally surprised, and a seed lets two servers deal
## the same hands and the suite assert a survivor is armed.
func _arm(player: ScPlayer, team: int, seat: int) -> void:
	if player.weapons != null:
		return

	var rig := ZeeWeaponRig.new()
	rig.name = "Weapons"
	# SERVER on a server, and the role only decides what is DRAWN. A rig that thought it
	# was local on a headless process would try to build a view model out of art the server
	# does not have.
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = authoritative
	rig.tick_rate = tick_rate
	rig.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(rig)

	var ready_now := rig.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "a weapon rig would not set up", {
			"player": String(player.player_id), "why": ready_now.error.message,
		})
		player.remove_child(rig)
		rig.queue_free()
		return

	player.weapons = rig

	# [b]One stream per team when the draws are shared, one per player when they are not.[/b] `stream_for`
	# mixes a subject into a named stream, which is exactly the question being asked: two players on one side
	# either get the same hand or they do not, and the answer has to be the same on every machine.
	var subject := team if config.weapons_match_within_team else team * 64 + seat
	var draw := random.stream_for(&"weapons", subject)
	var pool := _weapon_pool()

	if pool.is_empty():
		return

	var given: Array[StringName] = []

	for _i in range(config.weapons_granted):
		var id: StringName = pool[draw.next_range_i(0, pool.size() - 1)]

		if given.has(id):
			continue

		if rig.give(id).ok:
			given.append(id)

	if not given.is_empty():
		var first := rig.arsenal.catalogue.get_def(given[0])

		if first != null:
			var _selected := rig.arsenal.select(first.slot, _tick)

		player_armed.emit(player.player_id, given[0])

	DotLog.debug(CHANNEL, "a survivor was armed", {
		"player": String(player.player_id),
		"weapons": ", ".join(Array(given).map(func(v: Variant) -> String: return String(v))),
	})


func _disarm(player: ScPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


## Which weapons this server deals: a default list rather than the whole pack, and the omissions are the design. A
## random draw from all twenty-seven includes the fists and the derringer, and a survivor should not lose their
## place to a coin toss about ammunition.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))

		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER,
		ZeeWeaponIds.MACHINE_PISTOL,
		ZeeWeaponIds.SMG,
		ZeeWeaponIds.CARBINE,
		ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.BULLPUP,
		ZeeWeaponIds.BATTLE_RIFLE,
		ZeeWeaponIds.BURST_RIFLE,
		ZeeWeaponIds.SHOTGUN,
		ZeeWeaponIds.DRUM_SHOTGUN,
		ZeeWeaponIds.MARKSMAN,
		ZeeWeaponIds.SNIPER,
		ZeeWeaponIds.MINIGUN,
		ZeeWeaponIds.LAUNCHER,
		ZeeWeaponIds.BEAMER,
		ZeeWeaponIds.CHARGE_RIFLE,
		ZeeWeaponIds.HATCHET,
		ZeeWeaponIds.MALLET,
	])

	return out


## Whoever is nearest a chopper and asking to get in, gets in. Public because the bridge answers a client's
## request with it and the suite calls it directly. The reach is generous on purpose: a machine parked on a
## pad that is itself on a platform that is leaning is not going to be where anybody expects it.
func try_board(player_id: StringName) -> DotResult:
	var player: ScPlayer = players.get(player_id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Nobody by that name is here.")

	if player.riding:
		var aboard := vehicles.get_vehicle(ride.vehicle_id_of(player_id))

		if aboard != null:
			return ride.exit(aboard, player_id, false)

		return DotResult.fail(DotError.CODE_STATE, "You are aboard something that has gone.")

	var nearest := vehicles.nearest_free(player.controller.state.position, 6.0)

	if nearest == null:
		return DotResult.fail(DotError.CODE_STATE, "There is nothing here to get into.")

	var seat := nearest.first_free_seat()

	if seat == null:
		return DotResult.fail(DotError.CODE_STATE, "It is full.")

	return ride.enter(nearest, player_id, player, seat.id)
