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

	# [b]Laid out now, not when a round begins.[/b] dot-match runs a warmup before the first
	# round, so a world that only furnished itself on `round_started` would sit through the
	# whole warmup as a floor, a tube and nothing else — which is what somebody joining an
	# empty server sees, and is indistinguishable from the map having failed to load. It is
	# also what a suite gets when it builds a world and asserts about it without starting a
	# round, which is how this was found.
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
## [b]Built rather than taken from a preset, and applied rather than merely assigned.[/b]
## Five games in this family set a layout and put it on no bodies at all — everything
## stayed on layer one masking layer one — so two props dropped in the same place passed
## through each other. The four names here are the four kinds of thing in this map, and
## every `add_child` in this file goes through an `apply_to` whose result is checked.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"smash_copter", [
		&"world", &"player", &"prop", &"vehicle", &"pillar", &"toy", &"footprint",
	])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. Two capsules that push each other on a platform that
				# leans toward the heavier side is a game decided by who walked into whom,
				# and the shove would be a load the model never saw. So `mp_solidplayers` is 0
				# by default here (see `body_rules`); the camera fade keeps a player who walks
				# through you out of the lens.
				#
				# [b]And not a pillar.[/b] See `pillar` below.
				layer.collides_with = [&"world", &"prop", &"vehicle"]
			&"prop":
				layer.collides_with = [&"world", &"player", &"prop", &"vehicle", &"pillar"]
			&"vehicle":
				layer.collides_with = [&"world", &"player", &"prop", &"pillar"]
			&"pillar":
				# [b]Solid to what is thrown and flown, and never to a person.[/b] A pillar's
				# top is 2.7 m across and 0.57 m under its deck, and the only way a person
				# ever reaches it is the deck going: until 2026-09-25 everybody standing
				# within about a metre and a half of a platform's middle when it came off its
				# pillar dropped half a metre onto the top and stood there for the rest of the
				# round, alive, out of the cannon's reach (it aims at STANDING platforms) —
				# and was handed a weapon at the showdown. So the middle of every platform was
				# collapse-proof, and "stand in the middle" beat the whole first half of the
				# game. A collapse takes the floor away with whoever is on it; the bare pillar
				# stays, as the marker ScConfig.pillar_falls_with_platform keeps it for, and a
				# prop or a chopper still strikes it.
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
	# [b]Off, and the addon's own comment says why.[/b] A registry name is global to the
	# process, so the last manager to register wins — and two worlds in one process is not
	# exotic here: it is a server and a client in one editor session, and it is what every
	# section of the suite does. With it on, two worlds built from the same seed laid out
	# different maps, which is the one thing a seed exists to prevent.
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
	# The map's own furniture is put out by the world rather than requested by a player, so
	# the per-player budget and the cooldown are the wrong shape: the world cap is what is
	# being defended and it has to be above what a round throws, or the last few props
	# silently never appear.
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

	# [b]The SPAWNER's ride, not a second one.[/b] `DotVehicleSpawner` builds one in its own
	# `_init` and uses it for three things: evacuating a vehicle that is destroyed with
	# people in it, answering `vehicle_of_rider`, and reporting how many riders there are. A
	# game that constructed its own beside it leaves those three reading an index that is
	# always empty.
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

	# [b]Lag compensation is OFF here and turned on by the bridge, in the same breath as the
	# callables that make it real.[/b] dot-combat defaults it on, checks for a rewind
	# function as it comes up, and says "lag compensation is enabled but no rewind function
	# is wired; shots resolve against the present" when it finds none — which is exactly true
	# of a world with no netcode, and exactly false of this one thirty lines later, when
	# [ScNetBridge] hands over dot-net's history. Leaving the default meant a delivered server
	# logged that line at every boot about a server where lag compensation works.
	#
	# It is also the honest answer for the world a client builds when it is playing alone:
	# there is no history to rewind, so there is no compensation, and the log should say so.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# [b]A trace, or every shot in the showdown goes through the arena.[/b] dot-combat
	# resolves hitboxes analytically and asks a [DotTrace] where the WORLD is — and left
	# unset it quietly reports that nothing was in the way, so two players on opposite sides
	# of a catwalk shoot each other through it.
	#
	# [b]Before `setup()`, not after.[/b] The manager checks for one as it comes up and warns
	# when it finds none, so assigning it on the next line leaves a server log saying "no
	# trace backend; every shot will pass through world geometry" about a server where every
	# shot does not. A warning that is answered a line later is a warning an operator learns
	# to skim.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# [b]Which side an entity is on, or friendly fire is ON in a game whose rules say it is
	# off.[/b] [DotDamageResolver._same_team] takes a `team_of` [Callable] and returns false
	# when it has none — which is the right default for a free-for-all and is silently wrong
	# for every team game that forgets it. Nothing reports the gap: the rule is evaluated,
	# the answer is "not team mates", and the shot lands. What a player sees is a team mate
	# they can kill in a game that says friendly fire is off, and there is no number anywhere
	# that is wrong.
	#
	# By entity id rather than by key, because that is what a damage carries; dot-entity's
	# reverse index is what makes it one line.
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

	# [b]`add_child` IS the setup.[/b] [DotCombatManager._ready] calls `setup()` itself, so the
	# explicit call this used to make ran the whole of it a second time — and the tell was in
	# the delivered server's log, where every message `setup()` emits appeared twice in a row.
	# `setup()` is documented safe to call twice and it is; what it is not is free, and a
	# doubled boot line is how a reader finds out there are two of something.
	add_child(combat)


## The effects layer, which in this game is a shake and a flash and nothing else.
##
## [b]It ships no scenes, and that is a supported state rather than a gap.[/b] dot-fx's own
## invariant is that an effect is safe to drop, so a catalogue of two entries that need no
## art is the honest amount of presentation this game has: the screen shakes when the floor
## you are standing on is hit, and flashes when the round turns strange. Both of those are
## information, which is the only kind of effect worth replicating.
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
	# [b]Two, and it is the one number that keeps an empty server from spinning.[/b] An
	# elimination round ends the moment a side has nobody alive, and a side with nobody AT
	# ALL satisfies that on the first tick — so a server holding one team would start a
	# round, end it and start another several times a second for as long as nobody joined.
	# game-buses-from-hell shipped exactly that. `sides_are_playable` is the other half.
	rules.min_players = 2
	# [b]Nobody comes back, and it is the whole shape of the round.[/b] dot-match enqueues a
	# respawn on every kill it is told about, so a game that left this on would put a player
	# who fell off a platform back in the world three seconds later — which makes surviving
	# the first half worth nothing and the second half unwinnable. Death is final until the
	# next round, in both halves.
	rules.respawn_disabled = true
	# [b]The rule asks the game who is alive, and that is the seam dot-match is built
	# around.[/b] Being alive is a `DotHealth`, which lives in dot-combat, which dot-match
	# deliberately does not depend on. Left unset it falls back to a score and a clock, and
	# the tell is visible in the first round played: the round runs to the full clock
	# instead of ending on the last person standing.
	rules.alive_fn = _is_alive
	match_node.rules = rules

	# [b]Scoped to the match node itself, which finds nothing, and that is the point.[/b]
	# This game places its own players: a spawn point is a fixed place in the world and every
	# place in this world is on something that tips, collapses or is not there this round. So
	# there are no [DotSpawnPoint]s to find — but an unset `spawns_ref` makes dot-match walk
	# the WHOLE current scene looking for them, which in a process holding a server and a
	# client picks up the other world's, and after a round change picks up the outgoing map's
	# for the frame before it is freed. Both are in this family's own bug list.
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
	# [b]Off, because `sides` is what decides a team and dot-match is only told.[/b]
	# `max_difference` defaults to 1 and REFUSES a join that puts a side more than one
	# ahead, which `force_balance` does not reach. Offline, every stand-in is put on team 2
	# before the local player joins team 1, so dot-match took the first and left the other
	# two on no team at all — and the elimination rule counts survivors off dot-match's
	# teams, so a round ended when the one stand-in it knew about fell, with two still
	# standing. The same line was wrong in mg-buses-from-hell.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


## Somewhere for a player who is out to look, and the server's rules about where.
##
## [b]Built on both ends and authoritative on one.[/b] A connected client's world runs a
## mirror that is told each decision in a `SPECTATE` event; see [ScSpectate]. A world whose
## spectating would not set up still plays — being out simply leaves the camera where the
## body is, which is how this game shipped — so a refusal is a WARN rather than the world
## failing to open.
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
## [b]Off on a client, because a client decides nothing[/b] — a connected client's world
## would count what its mirrors happen to say. A tracker that will not start is a WARN and
## a world that plays on without it, the same bargain as spectating.
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
## [b]The tick number comes from outside and the step does not.[/b] A snapshot is stamped
## with the netcode's tick and a client reconciles against that number, so a world counting
## its own would be replying about a different tick than the one it was asked about. The
## STEP stays a fixed `1 / tick_rate` either way: a simulation stepped by a frame's delta
## runs differently on a server having a bad second, and this family has paid for that
## twice.
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
