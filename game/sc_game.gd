extends "sc_game_flow.gd"


func _ready() -> void:
	if config == null:
		config = ScConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved in this family for "the process cannot continue", and a
		# configuration that contradicts itself is not that: the right answer is to say so
		# loudly and refuse to run a round, not to take the server down.
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_layout_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_arena()
	_build_platforms()
	_build_props()
	_build_vehicles()
	_build_cannon()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

		# Laid out now, not when a round begins: dot-match runs a warmup before the first round, and a world furnished on `round_started` would show only a floor and a tube, indistinguishable from a failed map load (and what a suite sees when it asserts without starting a round).
	_lay_out_round()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


func _exit_tree() -> void:
	# By instance, never by name. Unregistering the NAME from a world that lost the race to
	# register it takes the other world's entry out with it, and the symptom is a module
	# that cannot find a game sitting in the tree.
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


## The named collision layers everything in this world is put on.
##
## Built and applied, not taken from a preset: five games set a layout and put it on no bodies, so props passed through each other. Every `add_child` here goes through an `apply_to` whose result is checked.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"smash_copter", [
		&"world", &"player", &"prop", &"vehicle", &"pillar", &"toy", &"footprint",
	])

	for layer in physics.layers:
		match layer.id:
			&"player":
								# Not other players: capsules pushing each other on a leaning platform would add a load the model never saw, so `mp_solidplayers` is 0 by default (see `body_rules`) and the camera fade keeps a passer-through out of the lens. And not a pillar; see `pillar` below.
				layer.collides_with = [&"world", &"prop", &"vehicle"]
			&"prop":
				layer.collides_with = [&"world", &"player", &"prop", &"vehicle", &"pillar"]
			&"vehicle":
				layer.collides_with = [&"world", &"player", &"prop", &"pillar"]
			&"pillar":
								# Solid to what is thrown and flown, never to a person: a pillar top is 0.57 m under its deck, and a player dropping onto it when the deck came off stood there alive, out of the cannon's reach (it aims at STANDING platforms), making "stand in the middle" beat the first half. A collapse takes the floor away with whoever is on it; the bare pillar stays as the marker ScConfig.pillar_falls_with_platform keeps, and a prop or chopper still strikes it.
				layer.collides_with = [&"prop", &"vehicle"]
			# A beach ball on a platform (dot-props'): the decks, what the cannon throws, a
			# chopper, the pillars and the other balls; never a person, who walks through it
			# and pushes it (`_advance_toys`). It rides a leaning deck and rolls off it.
			&"toy":
				layer.collides_with = [&"world", &"prop", &"vehicle", &"pillar", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player", &"prop", &"vehicle", &"pillar"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {
			"why": built.error.message,
		})
		physics = null


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
		# Off, as the addon says: a registry name is global to the process so the last manager to register wins, and two worlds in one process (server and client, every suite section) laid out different maps from one seed.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_layout_seed)


func _build_arena() -> void:
	arena = ScArena.new()
	arena.name = "Arena"
	arena.config = config
	arena.physics = physics
	add_child(arena)
	arena.build()


func _build_platforms() -> void:
	platforms = ScPlatforms.new()
	platforms.name = "Platforms"
	platforms.config = config
	platforms.authoritative = authoritative
	platforms.gravity = config.gravity
	add_child(platforms)

	platforms.collapsed.connect(_on_platform_collapsed)
	platforms.struck.connect(_on_platform_struck)


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.catalogue = ScContent.props(config)
	props.limits = DotPropLimits.new()
		# The map's own furniture is put out by the world, not requested by a player, so the per-player budget and cooldown are the wrong shape; the world cap must stay above what a round throws or the last props never appear.
	props.limits.spawn_interval = 0.0
	props.limits.per_player_budget = config.prop_budget + 40
	props.limits.world_budget = config.prop_budget + 40
	props.limits.clean_up_on_leave = false
	props.authoritative = authoritative
	add_child(props)

	prop_damage = DotPropDamage.new()
	prop_damage.name = "PropDamage"
	prop_damage.authoritative = authoritative
	props.add_child(prop_damage)
	prop_damage.exploded.connect(_on_prop_exploded)

	props.spawned.connect(_on_prop_spawned)
	props.removed.connect(_on_prop_removed)


func _build_vehicles() -> void:
	vehicles = DotVehicleSpawner.new()
	vehicles.name = "Vehicles"
	vehicles.catalogue = ScContent.vehicles(config)
	vehicles.authoritative = authoritative
	# Every chopper is placed in the same instant at the top of a round, and at the shipped
	# one-second interval only the first would appear — silently, because a refused spawn is
	# a refusal rather than an error. game-buses-from-hell found the same thing with buses.
	vehicles.spawn_interval = 0.0
	vehicles.per_player_budget = 12
	vehicles.world_budget = 12
	add_child(vehicles)

		# The SPAWNER's ride, not a second one: `DotVehicleSpawner` builds one in `_init` and uses it to evacuate a destroyed vehicle, answer `vehicle_of_rider` and count riders, which a game's own beside it would leave reading an empty index.
	ride = vehicles.ride
	ride.carry_rider_nodes = false
	ride.on_seated = func(rider_id: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat) -> void:
		_set_riding(rider_id, true)
	ride.on_unseated = func(
		rider_id: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat, at: Vector3
	) -> void:
		_set_riding(rider_id, false, at)


func _build_cannon() -> void:
	cannon = ScCannon.new()
	cannon.name = "Cannon"
	cannon.config = config
	cannon.props = props
	cannon.platforms = platforms
	cannon.arena = arena
	add_child(cannon)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := DotDamageRules.new()
	rules.friendly_fire = config.friendly_fire
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

		# Lag compensation is OFF here and turned on by the bridge together with the callables that make it real: dot-combat defaults it on and warns "no rewind function is wired" at boot, false for this server and true for a client playing alone, which has no history to rewind.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

		# A trace, or every shot goes through the arena: dot-combat asks a [DotTrace] where the WORLD is and left unset reports nothing in the way. Before `setup()`, which warns when it finds none, so assigning it a line later logs a false "every shot will pass through world geometry".
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

		# Which side an entity is on, or friendly fire is ON in a game that says it is off: [DotDamageResolver._same_team] returns false without a `team_of` [Callable], silently wrong for every team game that forgets it. By entity id, because that is what a damage carries.
	combat.resolver = DotDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# dot-game's "still loading": the one place every hurt passes (a shot, a blast, a crush, the
	# floor), and a round counts the living from health, so refusing here keeps a covered seat
	# alive in the count too. An admin's slay or slap is the operator's word and passes.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if damage.context.get("admin", false):
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

		# `add_child` IS the setup: [DotCombatManager._ready] calls `setup()` itself, and a second explicit call doubled every boot line in a delivered server's log.
	add_child(combat)


## The effects layer, which in this game is a shake and a flash and nothing else.
##
## It ships no scenes, a supported state since an effect is safe to drop: the shake when the floor you stand on is hit and the flash when the round turns strange are the information worth replicating.
func _build_effects() -> void:
	if authoritative:
		# A server draws nothing. Building one would be a frame budget and a viewer
		# position on a process with no viewer.
		return

	var catalogue := DotFxCatalogue.new()

	var knock := DotFxDef.new()
	knock.id = &"impact"
	knock.kind = DotFxDef.Kind.SHAKE
	knock.shake_trauma = 0.34
	knock.max_distance = 70.0
	catalogue.add(knock)

	var fall := DotFxDef.new()
	fall.id = &"collapse"
	fall.kind = DotFxDef.Kind.SHAKE
	fall.shake_trauma = 0.62
	fall.max_distance = 90.0
	catalogue.add(fall)

	var strange := DotFxDef.new()
	strange.id = &"special"
	strange.kind = DotFxDef.Kind.SCREEN
	strange.flash_peak = 0.28
	strange.flash_colour = Color(0.95, 0.80, 0.35, 1.0)
	strange.flash_decay_ms = 420
	catalogue.add(strange)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	DotLog.result(CHANNEL, "the effects layer", effects.setup())


## The intermission is the pause plus the killcam the clients play inside it, so the server never waits on one.
func apply_intermission(rules: DotMatchRules = null) -> void:
	var target: DotMatchRules = rules if rules != null else (match_node.rules if match_node != null else null)
	if target == null:
		return
	var pause := config.intermission_seconds
	target.intermission_sec = pause + (config.killcam_seconds if pause > 0.0 else 0.0)


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	match_node.config = match_config

	var rules := DotRulesElimination.make(config.round_seconds())
	apply_intermission(rules)
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.rounds_to_win = 999
	rules.team_based = true
		# Two, the number that keeps an empty server from spinning: an elimination round ends the moment a side has nobody alive, and an empty side satisfies that on the first tick. `sides_are_playable` is the other half.
	rules.min_players = 2
		# Nobody comes back: dot-match enqueues a respawn on every kill, which would return a faller three seconds later and make surviving the first half worth nothing. Death is final until the next round.
	rules.respawn_disabled = true
		# The rule asks the game who is alive, the seam dot-match is built around: being alive is a `DotHealth` in dot-combat, which dot-match does not depend on, and unset it falls back to score and clock so the round runs the full clock.
	rules.alive_fn = _is_alive
	match_node.rules = rules

		# Scoped to the match node itself, which finds nothing, deliberately: this game places its own players, and an unset `spawns_ref` makes dot-match walk the WHOLE scene, picking up another world's spawn points or the outgoing map's.
	match_node.spawns_ref = DotNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = []

	for index in range(config.team_count):
		teams.append(DotTeam.make(
			index + 1, TEAM_NAMES[index], TEAM_COLOURS[index]
		))

	match_node.teams.teams = teams
	match_node.teams.force_balance = config.autobalance
	match_node.teams.allow_choice = config.allow_team_choice
		# Off, because `sides` decides a team and dot-match is only told: `max_difference` (default 1) refuses a join more than one ahead, and offline the stand-ins on team 2 left the other two on no team, ending a round early when the one known stand-in fell.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


## Somewhere for a player who is out to look, and the server's rules about where.
##
## Built on both ends and authoritative on one: a client's world runs a mirror told each decision in a `SPECTATE` event ([ScSpectate]). A world whose spectating will not set up still plays, so a refusal is a WARN.
func _build_spectate() -> void:
	spectate = ScSpectate.new()
	spectate.name = "Spectate"
	spectate.death_cam_seconds = config.death_cam_seconds
	spectate.freeze_cam_seconds = config.freeze_cam_seconds
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	spectate.in_showdown_fn = func(p: int) -> bool:
		return p == Phase.HANDOVER or p == Phase.SHOWDOWN
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


## Statistics and achievements, where the world decides things.
##
## Off on a client, which decides nothing and would count what its mirrors say. A tracker that will not start is a WARN and the world plays on.
func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = ScProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	progress.hurt_radius = config.impact_hurt_radius
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One simulated tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1

	if hold_clock.is_valid() and hold_clock.call():
		_step_bodies_only(delta)
		return

	_step(delta)


## A tick under a cover: the bodies move, nothing else happens. A dead body is left alone.
func _step_bodies_only(delta: float) -> void:
	for id: StringName in players:
		var body := players[id] as ScPlayer

		if body.is_alive():
			body.simulate(_tick, delta)


## One simulated tick, numbered by the netcode. What the bridge uses.
##
## The tick number comes from outside, since clients reconcile against it, but the step stays a fixed `1 / tick_rate`: a frame-delta step runs differently on a server having a bad second.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func _step(delta: float) -> void:
	_advance_phase(delta)
	_advance_specials(delta)

	for id: StringName in players:
		(players[id] as ScPlayer).simulate(_tick, delta)

	if authoritative:
		_advance_toys(delta)

	_drive_bots(delta)
	_fly_choppers(delta)
	_apply_wind(delta)
	_load_platforms()

	platforms.step(delta)

	_watch_props(delta)
	_watch_falls()
	_advance_weapons()

	if phase == Phase.SURVIVAL:
		cannon.advance(delta, round_elapsed, active)
	else:
		# Aged even when it is not firing, so the map clears itself during the showdown
		# rather than holding whatever was in the air when the clock ran out.
		cannon.advance(delta, round_elapsed, ScSpecials.Active.new())

	if combat != null:
		combat.tick(_tick, delta)

	# After every death this tick has produced, so a death camera that runs out on this tick
	# hands over to somebody who is actually still up.
	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable():
		return

	match_node.tick(_tick)
