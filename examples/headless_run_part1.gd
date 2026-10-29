extends "headless_run_base.gd"

## Sections of [code]headless_run.gd[/code], part 1: shared state and helpers are in the base.


func _test_config() -> void:
	_section("the configuration refuses what it cannot play")

	var config := ScConfig.new()
	_check(config.validate().ok, "the defaults are playable")

	# Armed: each of these is a real contradiction the game cannot run.
	var teams := ScConfig.new()
	teams.team_count = 9
	_check(not teams.validate().ok, "nine sides is refused")

	var overlapping := ScConfig.new()
	overlapping.column_pitch = overlapping.platform_size - 1.0
	_check(not overlapping.validate().ok, "platforms that would overlap are refused")

	var plinth := ScConfig.new()
	plinth.pillar_radius = plinth.platform_size * 0.5
	_check(not plinth.validate().ok, "a pillar as wide as its platform is refused")

	var weightless := ScConfig.new()
	weightless.cannon_tier_weights = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	_check(not weightless.validate().ok, "a cannon that could never choose anything is refused")

	var sinking := ScConfig.new()
	sinking.chopper_lift = 1.0
	_check(not sinking.validate().ok, "a chopper that cannot leave the pad is refused")

	var short := ScConfig.new()
	short.cannon_tier_unlock = PackedFloat32Array([0.0, 1.0])
	_check(not short.validate().ok, "a tier table with the wrong number of entries is refused")

	_check(
		is_equal_approx(
			config.round_seconds(),
			config.survival_seconds + config.showdown_warmup_seconds + config.showdown_seconds
		),
		"a round is both halves and the pause between them"
	)

	_finished()


func _test_layouts() -> void:
	_section("every layout describes a field somebody could play on")

	var config := ScConfig.new()
	var layouts := ScLayouts.all(config)

	_check(layouts.size() >= 6, "there are several layouts", "%d" % layouts.size())

	var ids: Dictionary = {}
	var all_have_platforms := true
	var all_bridges_land := true

	for layout in layouts:
		ids[layout.id] = true
		var cells := layout.cells(config)
		var platforms: Dictionary = {}
		var bridges: Array[Vector3i] = []

		for cell: Vector3i in cells:
			if cell.z == 1:
				bridges.append(cell)
			else:
				platforms["%d,%d" % [cell.x, cell.y]] = true

		if platforms.is_empty():
			all_have_platforms = false

		# [b]A bridge with nothing at either end of it is a diving board.[/b] The layout
		# refuses to place one, and this is what says so — it is the only rule in that file
		# whose absence would be invisible until somebody walked off the end.
		for bridge in bridges:
			if not platforms.has("%d,%d" % [bridge.x, bridge.y]):
				all_bridges_land = false

			if not platforms.has("%d,%d" % [bridge.x, bridge.y + 1]):
				all_bridges_land = false

	_check(all_have_platforms, "no layout is empty")
	_check(all_bridges_land, "every bridge has a platform at both ends")
	_check(ids.size() == layouts.size(), "no two layouts share an id")

	# Seeded, so two servers lay out the same round. The whole reason a seed exists.
	var one := DotRandomStream.new(4242, &"layout")
	var two := DotRandomStream.new(4242, &"layout")
	var picks_agree := true

	for _i in range(24):
		if ScLayouts.pick(config, one).id != ScLayouts.pick(config, two).id:
			picks_agree = false

	_check(picks_agree, "two streams on one seed pick the same layouts")

	_finished()


## dot-props' toys on the field: a beach ball on every platform, standing on its deck two
## seconds on; a walk into one sends it on; a shot pushes it and the combat's trace sees through
## it. In a world of its own: every other world this suite builds stands on the same spot.
func _test_the_toys() -> void:
	_section("a beach ball on every platform")
	var view := SubViewport.new()
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(view)
	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.vary_layout = false
	var game := ScGame.new()
	game.name = "ToyWorld"
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	view.add_child(game)
	game.set_physics_process(false)
	await _physics_frame()
	await _physics_frame()
	_check(is_equal_approx(game.match_node.rules.intermission_sec, 0.0) and config.killcam_seconds > 0.0,
		"the killcam adds nothing to an intermission of 0")
	config.intermission_seconds = 8.0
	game.apply_intermission()
	_check(is_equal_approx(game.match_node.rules.intermission_sec, 8.0 + config.killcam_seconds),
		"and is added to the pause otherwise", str(game.match_node.rules.intermission_sec))
	config.intermission_seconds = 0.0
	game.apply_intermission()
	var platforms := 0
	for i in range(game.platforms.count()):
		platforms += 0 if game.platforms.deck_at(i).is_bridge else 1
	var box := game.toys
	_check(box != null and box.count() == platforms and platforms > 0 and box.missing.is_empty(),
		"one for each of the %d platforms" % platforms, str(box.describe()) if box != null else "none")
	for _i in range(TICK_RATE * 2):
		game.simulate(TICK)
		await _physics_frame()
	var off: Array = []
	for toy in box.toys:
		if toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
			off.append("%d at %s" % [toy.index, toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(off.is_empty(), "two seconds on, every ball is still on its platform", "; ".join(off))
	var ball := box.toy(0)
	var b0 := ball.body.global_position
	var shot := DotShot.make(&"test", 0, 0, 0)
	shot.origin = b0 + Vector3(0.0, 0.0, 5.0)
	shot.direction = Vector3(0.0, 0.0, -1.0)
	shot.damage = 25.0
	shot.max_range = 40.0
	game._shoot_toys(shot)
	for _i in range(10):
		await _physics_frame()
	_check(ball.body.global_position.distance_to(b0) > 0.3, "a shot sends one rolling", "%.2f m" % ball.body.global_position.distance_to(b0))
	remove_child(view)
	view.queue_free()
	_finished()


func _test_a_platform_leans() -> void:
	_section("a platform leans toward whoever is standing on it")

	var game := await _world()
	var platforms := game.platforms
	var deck := platforms.deck_at(0)

	_check(is_zero_approx(deck.tilt()), "it starts level")

	# Eighty kilograms on the +X edge, standing still.
	var at := deck.centre + Vector3(deck.half * 0.8, 0.0, 0.0)

	for _i in range(40):
		platforms.begin_loads()
		platforms.add_load(0, at, 80.0, 0.0)
		platforms.step(TICK)

	_check(deck.lean.x > 0.0, "it leaned toward the load", "%.4f rad" % deck.lean.x)
	_check(is_zero_approx(deck.lean.y) or absf(deck.lean.y) < 0.0001,
		"and not sideways", "%.5f" % deck.lean.y)

	# The surface actually moved under that point, which is the thing a player feels.
	var under := platforms.surface_y(0, at.x, at.z)
	_check(under < deck.centre.y, "the surface under the load is lower than the pivot",
		"%.3f vs %.3f" % [under, deck.centre.y])

	var high := platforms.surface_y(0, deck.centre.x - deck.half * 0.8, deck.centre.z)
	_check(high > under, "and the far side is higher", "%.3f vs %.3f" % [high, under])

	# Let go, and it comes back. A spring that did not would be a ramp.
	var leaned := deck.lean.x

	for _i in range(240):
		platforms.begin_loads()
		platforms.step(TICK)

	_check(absf(deck.lean.x) < leaned * 0.5, "it settles back when the load goes",
		"%.4f from %.4f" % [deck.lean.x, leaned])
	_check(deck.is_standing(), "and it is still standing")

	await _dispose(game)
	_finished()


func _test_walking_is_gentler() -> void:
	_section("walking leans a platform less than running does")

	var game := await _world()
	var platforms := game.platforms
	var config := game.config

	var walking := platforms.deck_at(0)
	var running := platforms.deck_at(1)
	var at_walk := walking.centre + Vector3(walking.half * 0.7, 0.0, 0.0)
	var at_run := running.centre + Vector3(running.half * 0.7, 0.0, 0.0)

	for _i in range(60):
		platforms.begin_loads()
		platforms.add_load(0, at_walk, config.player_mass, config.run_speed * config.walk_speed_scale)
		platforms.add_load(1, at_run, config.player_mass, config.run_speed)
		platforms.step(TICK)

	_check(running.lean.x > walking.lean.x,
		"the running player leaned theirs further",
		"run %.4f vs walk %.4f" % [running.lean.x, walking.lean.x])

	# [b]Armed.[/b] With `platform_motion_gain` at zero the two are identical, which is what
	# this check exists to notice: a gain that was read by nothing would pass every other
	# assertion in this file.
	_check(running.lean.x > walking.lean.x * 1.2,
		"and by a margin a player could feel",
		"%.2fx" % (running.lean.x / maxf(walking.lean.x, 0.00001)))

	await _dispose(game)
	_finished()


func _test_a_platform_collapses() -> void:
	_section("a platform comes off its pillar")

	var game := await _world()
	var platforms := game.platforms
	var config := game.config

	var fell: Array[int] = []
	platforms.collapsed.connect(func(index: int, _why: StringName) -> void: fell.append(index))

	var deck := platforms.deck_at(0)
	var at := deck.centre + Vector3(deck.half, 0.0, 0.0)

	# A crowd on one edge. Enough to go over, given long enough.
	for _i in range(600):
		if not deck.is_standing():
			break

		platforms.begin_loads()
		platforms.add_load(0, at, 800.0, config.run_speed)
		platforms.step(TICK)

	_check(not deck.is_standing(), "enough weight on one edge takes it over",
		"%.3f rad" % deck.tilt())
	# An Array rather than a captured counter: a GDScript lambda captures locals BY VALUE, so
	# an `int` incremented in the handler stays zero outside it and the check reports a
	# failure for a signal that fired perfectly.
	_check(fell.has(0), "and it said so")

	# The collider goes NOW, not when the slab has finished falling. A player left riding it
	# would be carried forty metres by a floor that is gone from every other point of view.
	var collider := deck.body.get_node_or_null(^"Collision") as CollisionShape3D
	_check(collider != null and collider.disabled, "the floor is taken away at once")
	_check(platforms.index_of_body(deck.body.get_instance_id()) == -1,
		"and nothing can be standing on it")

	# A single big enough impact is the other way, and it does not care about health.
	var second := platforms.deck_at(1)
	var outcome := platforms.report_impact(
		1, config.platform_shatter_impulse * 2.0, 1.0, second.centre + Vector3(1.0, 0.0, 0.0)
	)
	_check(outcome == ScPlatforms.Impact.SHATTERED, "one big enough hit shatters a platform")
	_check(not second.is_standing(), "which takes it off its pillar in the same tick")

	# And a small one does not.
	var third := platforms.deck_at(2)
	var gentle := platforms.report_impact(2, 30.0, 6.0, third.centre + Vector3(1.0, 0.0, 0.0))
	_check(gentle == ScPlatforms.Impact.WOBBLE, "a crate landing only wobbles it")
	_check(third.is_standing(), "and leaves it standing")
	_check(third.lean_velocity.length() > 0.0, "though it is moving now",
		"%.4f rad/s" % third.lean_velocity.length())

	await _dispose(game)
	_finished()


func _test_the_carry() -> void:
	_section("a leaning platform carries what is standing on it")

	var game := await _world()
	var platforms := game.platforms
	var deck := platforms.deck_at(0)
	var at := deck.centre + Vector3(deck.half * 0.7, 0.0, 0.0)

	# Lean it, then measure what the surface did under one fixed point in one step.
	for _i in range(30):
		platforms.begin_loads()
		platforms.add_load(0, at, 400.0, 0.0)
		platforms.step(TICK)

	var before := platforms.surface_y(0, at.x, at.z)

	platforms.begin_loads()
	platforms.add_load(0, at, 400.0, 0.0)
	platforms.step(TICK)

	var after := platforms.surface_y(0, at.x, at.z)
	var lift := platforms.lift_at(0, at.x, at.z)

	_check(not is_zero_approx(lift), "the surface moved", "%.5f m" % lift)
	_check(is_equal_approx(lift, after - before),
		"and the lift is exactly how far it moved", "%.6f vs %.6f" % [lift, after - before])

	# [b]The same offset on both sides of the subtraction is the whole trick.[/b] What is
	# wanted is what the PLATFORM did; a lift measured against where the player was last tick
	# would fold their own walking in and carry them twice.
	var far_out := platforms.lift_at(0, deck.centre.x - deck.half * 0.7, deck.centre.z)
	_check(signf(far_out) != signf(lift) or is_zero_approx(far_out),
		"the far side went the other way", "%.5f vs %.5f" % [far_out, lift])

	# A point over nothing is not carried by anything.
	_check(is_zero_approx(platforms.lift_at(-1, 0.0, 0.0)), "nothing carries a point over nothing")

	await _dispose(game)
	_finished()


func _test_the_cannon() -> void:
	_section("the cannon aims")

	var game := await _world()
	var cannon := game.cannon
	var plain := ScSpecials.Active.new()

	var sent := cannon.fire(0.0, plain)
	_check(sent > 0, "it fires", "%d props" % sent)
	_check(game.props.world_count() > 0, "and the props are in the world")

	# Everything in the first seconds is tier one: the unlock table is what makes the opening
	# of a round survivable, and a tier that arrived early would be invisible to any check
	# that only counted props.
	var early_tiers_ok := true

	for prop in game.props.all_props():
		if ScContent.tier_of(prop.def) != 1:
			early_tiers_ok = false

	_check(early_tiers_ok, "and all of them are the small ones at zero seconds")

	# The arc is solved rather than tuned. This is the check that says so: a body launched at
	# a target reaches it, within the scatter it was given.
	var target := Vector3(18.0, game.config.deck_height, 6.0)
	var from := game.arena.muzzle()
	var velocity := ScCannon.solve_arc(from, target, 25.0, game.config.gravity)

	_check(velocity.y > 0.0, "a solved arc goes up first", "%.1f m/s" % velocity.y)

	# Integrate it by hand, which is the only honest way to check a ballistic solution.
	var where := from
	var moving := velocity
	var closest := INF

	for _i in range(600):
		moving.y -= game.config.gravity * TICK
		where += moving * TICK
		closest = minf(closest, Vector2(where.x - target.x, where.z - target.z).length())

		if where.y < target.y and moving.y < 0.0:
			break

	_check(closest < 2.0, "and it lands on what it was aimed at", "%.2f m away" % closest)
	_check(where.y <= target.y + 1.0, "at about the right height", "%.1f m" % where.y)

	# The rate closes as the round goes on, which is what makes the last thirty seconds
	# different from the first thirty.
	var opening := cannon.interval_at(0.0, plain)
	var closing := cannon.interval_at(game.config.survival_seconds, plain)
	_check(closing < opening, "it speeds up over a round", "%.2f s to %.2f s" % [opening, closing])

	var early_volley := cannon.volley_at(0.0, plain)
	var late_volley := cannon.volley_at(game.config.survival_seconds, plain)
	_check(late_volley > early_volley, "and throws more at once",
		"%d to %d" % [early_volley, late_volley])

	# A prop is on a clock from the moment it leaves, or the map is a scrapyard by the end.
	# Named rather than counted: advancing the cannon also fires it, so a world_count() check races.
	var was_up: Array[int] = []

	for prop in game.props.all_props():
		was_up.append(prop.instance_id)

	cannon.advance(game.config.prop_life_seconds + 1.0, 0.0, plain)

	var survivors := 0

	for prop in game.props.all_props():
		if was_up.has(prop.instance_id):
			survivors += 1

	_check(was_up.size() > 0 and survivors == 0, "and takes its props back eventually",
		"%d of %d left" % [survivors, was_up.size()])

	await _dispose(game)
	_finished()


func _test_an_impact() -> void:
	_section("something landing leans the platform it landed on")

	var game := await _world()
	var platforms := game.platforms
	var deck := platforms.deck_at(0)

	var struck: Array[int] = []
	platforms.struck.connect(
		func(index: int, _at: Vector3, _impulse: float, _outcome: int) -> void:
			struck.append(index)
	)

	var at := deck.centre + Vector3(deck.half * 0.6, 0.0, 0.0)
	var outcome := platforms.report_impact(0, 110.0, 14.0, at)

	_check(outcome == ScPlatforms.Impact.WOBBLE, "a boulder wobbles it")
	_check(struck.has(0), "and it said so")
	_check(deck.lean_velocity.x > 0.0, "it was pushed toward where it landed",
		"%.4f rad/s" % deck.lean_velocity.x)
	_check(deck.sink_velocity < 0.0, "and pressed down", "%.4f m/s" % deck.sink_velocity)
	_check(deck.health < 1.0, "and it took damage", "%.3f left" % deck.health)

	# [b]Dead centre is the one case with no lever arm, and it still has to do
	# something.[/b] A monolith dropped exactly on the pillar would otherwise be absorbed by
	# a platform that cannot tell it happened.
	var centred := platforms.deck_at(1)
	var _hit := platforms.report_impact(1, 110.0, 14.0, centred.centre)
	_check(centred.lean_velocity.length() > 0.0, "a hit dead on the pillar still leans it",
		"%.4f rad/s" % centred.lean_velocity.length())

	# Impacts add up. A platform that has been hit twice is one more hit from gone.
	var health_after_one := deck.health
	var _again := platforms.report_impact(0, 110.0, 14.0, at)
	_check(deck.health < health_after_one, "two hits are worse than one",
		"%.3f then %.3f" % [health_after_one, deck.health])

	# And nothing at all happens to a platform that has already gone.
	var _gone := platforms.collapse(2)
	var missed := platforms.report_impact(2, 900.0, 40.0, platforms.deck_at(2).centre)
	_check(missed == ScPlatforms.Impact.NONE, "a platform that has gone cannot be hit again")

	await _dispose(game)
	_finished()


## A stand-in in the showdown turns and fires like a person, through dot-bot's [DotBotAim] and [method ScGame._drive_bots].
## The turn is held to `bot_turn_rate` and the first shot to `bot_reaction`, and it still hits.
func _test_a_stand_in_aims() -> void:
	_section("a stand-in turns, waits and then hits, at bot_difficulty")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 2.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 60.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
	)

	var shooter := game.add_player(&"shooter", "Shooter", 1)
	var target := game.add_player(&"target", "Target", 2)
	game.start()

	await _step(game, int(3.0 * TICK_RATE))

	_check(game.phase == ScGame.Phase.SHOWDOWN and shooter.weapons != null,
		"the showdown is running and the stand-in is armed", ScGame.Phase.keys()[game.phase])

	# The target eight metres off, and the stand-in facing 150 degrees away from it: outside
	# every preset's view cone but nightmare's, so it has to turn before it can see.
	var stand := shooter.controller.state.position
	var toward := game.arena.showdown_centre() - stand
	toward.y = 0.0
	toward = toward.normalized()
	var facing := rad_to_deg(atan2(-toward.x, -toward.z))
	shooter.place_at(stand, facing + 150.0)
	target.place_at(stand + toward * 8.0, rad_to_deg(atan2(toward.x, toward.z)))
	await _step(game, 2)

	shooter.is_bot = true
	var profile := DotBotSettings.of(game).profile
	var before := target.health.health
	var fastest := 0.0
	var hit_after := -1.0

	var aim: DotBotAim = null
	var waited := NAN

	# Stopped at the first hit: a kill ends the round, and the next one is a new aim.
	for i in range(int(4.0 * TICK_RATE)):
		var yaw_before := shooter.controller.state.yaw
		await _step(game, 1)
		fastest = maxf(fastest, absf(wrapf(shooter.controller.state.yaw - yaw_before, -180.0, 180.0)) * TICK_RATE)
		aim = game._bot_aim_of(shooter)
		waited = aim.first_shot_at - aim.engaged_at

		if target.health.health < before:
			hit_after = float(i + 1) / TICK_RATE
			break

	_check(fastest <= profile.turn_rate * 1.02, "it turns no faster than bot_turn_rate",
		"%.0f of %.0f deg/s" % [fastest, profile.turn_rate])
	_check(fastest > 30.0, "and it does turn", "%.0f deg/s" % fastest)
	_check(not is_nan(waited) and waited >= profile.reaction * 0.85,
		"its first shot waits bot_reaction after it first sees the target",
		"%.2f s against %.2f" % [waited, profile.reaction])
	_check(hit_after > 0.0, "and then it hits", "after %.2f s" % hit_after)

	await _dispose(game)
	_finished()


func _test_sides_agree() -> void:
	_section("dot-match puts everybody where the game did")

	var game := await _world()

	# The offline client's own line-up: every stand-in on team 2 before anybody is on 1.
	# dot-match's default refuses a join that puts a side two ahead, and its elimination
	# rule counts survivors off its own teams — so a refused stand-in is one it never sees.
	for i in range(3):
		game.add_player(StringName("bot%d" % i), "Stand-in", 2)
	game.add_player(&"local", "You", 1)

	var disagree: Array[String] = []
	for id: StringName in game.players:
		if game.match_node.teams.team_of(String(id)) != game.team_of(id):
			disagree.append(String(id))

	_check(disagree.is_empty(), "every stand-in is on a side dot-match can count",
		"it disagrees about %s" % ", ".join(disagree))

	await _dispose(game)
	_finished()


func _test_falling_off() -> void:
	_section("running out of map is fatal")

	var game := await _world()

	var player := game.add_player(&"faller", "Faller", 1)
	game.add_player(&"other", "Other", 2)

	var deaths: Array[StringName] = []
	game.player_died.connect(
		func(id: StringName, _by: StringName, why: StringName) -> void:
			deaths.append(why)
	)

	_check(player.is_alive(), "they start up")
	_check(player.entity_id != 0, "with an entity id")
	_check(DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER),
		"and the id says what kind of thing they are")

	# Put them under the floor and step once. A height comparison cannot be stepped over,
	# which is the whole reason this is not a trigger volume: at terminal velocity a falling
	# body crosses a thin trigger between two ticks without ever being inside it.
	player.place_at(Vector3(0.0, game.config.kill_height - 5.0, 0.0), 0.0)
	game.simulate(TICK)

	_check(not player.is_alive(), "below the floor is dead")
	_check(deaths.has(ScGame.DIED_FELL), "and it is recorded as a fall",
		", ".join(Array(deaths).map(func(v: Variant) -> String: return String(v))))

	# How the body falls: the server picked it, it travels on DEATH, and a client builds it from
	# the figure it draws. A death with no figure drawn here is nothing to build, which _fall
	# must survive.
	_check(player.death != null and DotPlayerDeathReactions.stock().has(player.death.reaction),
		"the server picked how the body falls", str(player.death.describe()) if player.death != null else "none")
	var carried: Dictionary = ScEvents.read_death(DotNetReader.new(ScEvents.write_death(5, 0, ScGame.DIED_FELL, player.death)))
	_check(bool(carried["ok"]) and carried.has("death") and (carried["death"] as DotPlayerDeath).reaction == player.death.reaction,
		"DEATH carries it")
	var bare := ScEvents.read_death(DotNetReader.new(ScEvents.write_death(5, 0, ScGame.DIED_FELL)))
	_check(bool(bare["ok"]) and not bare.has("death"), "and a DEATH without it still reads")
	var client := ScClient.new()
	client.game = game
	client._build_ragdolls()
	client.remove_child(client.ragdolls)
	add_child(client.ragdolls)
	client._fall(player)
	_check(client.ragdolls.live().is_empty(), "no figure drawn, no body, and no error")
	var other: ScPlayer = game.players[&"other"]
	var _drawn := other.present_body(false, other.controller.state.position, Color.WHITE)
	other.death = player.death
	client._fall(other)
	_check(client.ragdolls.live().size() == 1 and client.ragdolls.rules == game.ragdoll_rules,
		"a drawn figure falls as a body, under the game's rules")
	client.ragdolls.queue_free()
	client.free()

	# [b]dot-combat keeps a health record per entity and nothing else tells it to let
	# go.[/b] game-buses-from-hell leaked one per player who ever joined, pointing at a node
	# freed with them — invisible, because a stale entity is never asked about.
	var id := player.entity_id
	_check(game.combat.health_of(id) != null, "the combat manager knows them")
	game.remove_player(&"faller")
	_check(game.combat.health_of(id) == null, "and forgets them when they leave")
	_check(game.entities.key_for_id(id) == &"", "the entity table closes them too")

	await _dispose(game)
	_finished()
