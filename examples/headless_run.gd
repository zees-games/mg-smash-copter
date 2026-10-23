extends Node

const ScArena := preload("../game/sc_arena.gd")
const ScAudio := preload("../game/sc_audio.gd")
const ScCannon := preload("../game/sc_cannon.gd")
const ScBindings := preload("../game/sc_bindings.gd")
const ScConfig := preload("../game/sc_config.gd")
const ScContent := preload("../game/sc_content.gd")
const ScCopter := preload("../game/sc_copter.gd")
const ScFigure := preload("../game/sc_figure.gd")
const ScGame := preload("../game/sc_game.gd")
const ScHud := preload("../game/sc_hud.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScMapSession := preload("../game/sc_map_session.gd")
const ScPlatforms := preload("../game/sc_platforms.gd")
const ScPaths := preload("../game/sc_paths.gd")
const ScClient := preload("../game/sc_client.gd")
const ScEvents := preload("../game/net/sc_events.gd")
const ScPlayer := preload("../game/sc_player.gd")
const ScProgress := preload("../game/sc_progress.gd")
const ScSpecials := preload("../game/sc_specials.gd")
const ScSpectate := preload("../game/sc_spectate.gd")
const ScSettings := preload("../game/sc_settings.gd")

## Proves the platforms, the cannon, the round and the chopper all actually work.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## [/codeblock]
##
## [b]The checks that matter are the ones that cross an addon boundary, and the ones that
## measure the model this game invented.[/b] dot-props, dot-combat, dot-match and dot-vehicle
## are each tested in their own repository and each of them passes there; what has never run
## before this game is the joins — and [ScPlatforms] has never run anywhere, because nothing
## in the family models a floor that tips. So the sections are named after behaviours a
## player would describe rather than after classes.
##
## [b]It steps the world by hand.[/b] `ScGame._physics_process` drives itself on a server; a
## suite that let it would be asserting against a tick count it does not control, so
## `set_physics_process(false)` goes on first and every section advances the world itself.

## Sections entered, against sections that ran to their last line.
const SECTIONS := 49

## And the total this counter cannot be.
##
## [b]A runtime error inside a section aborts that FUNCTION and nothing says so.[/b] The
## checks that already ran still print ok, the ones after it never happen, and the section
## counter is satisfied because the section announced itself on the way in. dot-settings
## reported "8 sections, 63 passed, 0 failed" and exited 0 with eight checks missing.
const CHECKS := 381

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

## Every world this run has built and not yet taken down.
var _worlds: Array[ScGame] = []

## A player whose run is being measured, frame by frame, whichever helper is driving them:
## the horizontal metres they covered and the fastest they went. See [method _physics_frame].
var _tracked: ScPlayer = null
var _tracked_at := Vector3.ZERO
var _covered := 0.0
var _top_speed := 0.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("smash-copter headless run")
	print("")

	_test_config()
	_test_delivery()
	_test_the_weapon_art_is_vendored()
	await _test_zee_art_root()
	_test_layouts()
	await _test_world_builds()
	await _test_the_toys()
	await _test_a_platform_leans()
	await _test_walking_is_gentler()
	await _test_a_platform_collapses()
	await _test_the_carry()
	await _test_the_cannon()
	await _test_an_impact()
	await _test_falling_off()
	await _test_a_collapse_takes_everybody()
	await _test_the_round()
	await _test_sides_agree()
	await _test_specials()
	await _test_a_shot_lands()
	await _test_a_stand_in_aims()
	await _test_the_chopper()
	await _test_riding_the_chopper()
	await _test_the_pieces()
	await _test_collision_audit()
	await _test_the_map_catalogue()
	await _test_reach()
	await _test_the_throat()
	await _test_the_showdown_walk()
	await _test_catwalks_meet_their_edges()
	await _test_the_ring_cover()
	await _test_the_flanks()
	await _test_the_dais()
	await _test_the_zigzag()
	await _test_the_spine()
	await _test_two_islands()
	await _test_hollow_centre()
	await _test_broadside()
	await _test_the_airfield()
	await _test_a_slope_holds()
	await _test_blind_and_beacon_drawn()
	await _test_somebody_out_watches()
	await _test_free_roam()
	await _test_the_game_makes_a_noise()
	await _test_what_a_player_keeps()
	await _test_a_swing_is_drawn()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_offline_trigger()
	await _test_the_drawn_gun()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Sections ---------------------------------------------------------------

func _test_config() -> void:
	_section("the configuration refuses what it cannot play")

	var config := ScConfig.new()
	_check(config.validate().ok, "the defaults are playable")

	# Armed: each of these is a real contradiction the game cannot run, and every one of
	# them used to be checked nowhere.
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


func _test_world_builds() -> void:
	_section("the world comes up")

	var game := await _world()

	_check(game.platforms != null and game.platforms.count() > 0,
		"there are platforms", "%d" % game.platforms.count())
	_check(game.arena != null, "there is an arena")
	_check(game.cannon != null, "there is a cannon")
	_check(game.physics != null, "the collision layout built")

	# [b]Applied, not merely assigned.[/b] Five games in this family set a layout and put it
	# on no bodies at all; everything stayed on layer one masking layer one. A platform whose
	# layer is still the default is exactly that bug.
	var deck := game.platforms.deck_at(0)
	var world_layer := game.physics.layer_mask(&"world")
	_check(deck.body.collision_layer == world_layer,
		"a platform is on the world layer", "%d vs %d" % [deck.body.collision_layer, world_layer])

	# Every platform except a bridge stands on its own pillar, which is the entire premise.
	var pillars := 0
	var bridges := 0

	for i in range(game.platforms.count()):
		var each := game.platforms.deck_at(i)

		if each.is_bridge:
			bridges += 1
		elif each.pillar != null:
			pillars += 1

	_check(pillars + bridges == game.platforms.count(),
		"every platform is on a pillar or is a bridge", "%d + %d" % [pillars, bridges])

	# The muzzle clears the tube it comes out of. A body spawned inside a collider is two
	# shapes sharing a volume, which the solver resolves by throwing one of them sideways.
	_check(game.arena.muzzle().y > game.config.deck_height * 0.8,
		"the muzzle is above the tube", "%.1f m" % game.arena.muzzle().y)

	_check(game.platforms.index_at(deck.centre.x, deck.centre.z) == 0,
		"a point over a platform finds it")
	_check(game.platforms.index_at(9000.0, 9000.0) == -1,
		"a point over nothing finds nothing")

	# [b]The showdown's edges, which were designed, documented twice and built nowhere.[/b]
	# `_pad` was described as "one flat surface with a kerb around it", `CORNER_LIP` had a
	# doc comment explaining why the lip is not cover, and no line put one in the world. A
	# render found it; nothing here could have, so this is the check that keeps it.
	#
	# Counted rather than measured: a pad is four kerbs and a catwalk is two, because a kerb
	# across a catwalk's short end is a step in the middle of the walkway rather than a rail
	# beside it.
	#
	# Counted by SIDE rather than by piece, because a side a catwalk joins is two pieces
	# with the catwalk between them. Whether that gap is really there is not something a
	# count can say — the showdown walk below is what says it.
	var pads := 0
	var walks := 0
	var thin := PackedStringArray()

	for child: Node in game.arena.find_children("*", "StaticBody3D", true, false):
		var sides: Dictionary = {}

		for piece: Node in child.get_children():
			var piece_name := String(piece.name)

			if piece_name.begins_with("KerbHit"):
				sides[piece_name.trim_prefix("KerbHit").get_slice("_", 0)] = true

		var kerbs := sides.size()

		if String(child.name).begins_with("Catwalk"):
			walks += 1

			if kerbs != 2:
				thin.append("%s has %d" % [child.name, kerbs])
		elif String(child.name).begins_with("Pad") or child.name == "Ring":
			pads += 1

			if kerbs != 4:
				thin.append("%s has %d" % [child.name, kerbs])

	_check(pads == game.config.team_count + 1,
		"every corner and the ring is a pad", "%d pads" % pads)
	_check(walks == game.config.team_count,
		"and every corner has a catwalk to the ring", "%d walks" % walks)
	_check(thin.is_empty(),
		"a pad is edged on four sides and a catwalk on two",
		", ".join(thin))

	await _dispose(game)
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
	#
	# [b]Named rather than counted, because advancing the cannon also FIRES it.[/b] A check
	# on `world_count()` measures the old props leaving and the new ones arriving at once,
	# and passes or fails on which of the two happened to win.
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


## [b]A stand-in in the showdown turns and fires like a person[/b]: through dot-bot's
## [DotBotAim] on the game's `bot_difficulty`, driven by the game's own [method ScGame._drive_bots].
##
## Until fpt-bots-mg-smash-copter-1 a stand-in's view was set straight onto the nearest enemy
## every tick, off by a fixed offset per round, with the trigger held from the first tick. So
## the turn is held to `bot_turn_rate` (the old snap turned a 150 degree corner in one tick),
## the first shot to `bot_reaction` after it first saw the enemy, and it still hits.
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


## [b]A platform that comes off its pillar takes everybody on it, wherever they stood.[/b]
##
## Until 2026-09-25 it took nobody. Measured on all eight layouts, a player on a platform
## collapsed by lean, 400 ticks later: within about 1.5 m of the middle they had dropped
## 0.57 m onto the PILLAR's top and were standing on it, and everywhere else they had fallen
## forty metres onto the FLOOR and were standing on that — because the floor's top is the
## kill height and the check was `y <= kill_height`, with the motor resting a capsule a skin
## width above whatever it stands on. Every fall check in this file put a player five metres
## under the floor with `place_at`, which a real fall never does. Alive at the end of the
## clock is a seat in the showdown, so either was a free pass; the pillar one was a strategy.
##
## So nothing here is placed below anything: four people really fall, from a real collapse
## and off a real edge, and the section waits for the drop.
func _test_a_collapse_takes_everybody() -> void:
	_section("a platform off its pillar takes everybody on it, and the floor is fatal")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 120.0
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = false
	)

	var middle := game.add_player(&"middle", "Middle", 1)
	var near := game.add_player(&"near", "Near", 1)
	var out := game.add_player(&"out", "Out", 1)
	var edge := game.add_player(&"edge", "Edge", 1)
	# One per side kept standing elsewhere, so no side is eliminated and the round does not
	# end and re-lay the field under the four who are falling.
	var keeper := game.add_player(&"keeper", "Keeper", 1)
	var other := game.add_player(&"other", "Other", 2)

	var fell: Dictionary = {}
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName) -> void:
		fell[id] = why)

	game.start()
	await _step(game, 20)

	var platforms := game.platforms
	var index := -1
	var spare := -1

	for i in range(platforms.count()):
		var each := platforms.deck_at(i)
		if each.is_bridge or not each.is_standing():
			continue
		if index < 0:
			index = i
		else:
			spare = i

	var deck := platforms.deck_at(index)
	var safe := platforms.deck_at(spare)

	# On the axis, inside the pillar's radius, just outside it, and — on a different, standing
	# platform — a step past its edge into the air.
	middle.place_at(deck.centre + Vector3(0.0, 1.2, 0.0), 0.0)
	near.place_at(deck.centre + Vector3(0.8, 1.2, 0.3), 0.0)
	out.place_at(deck.centre + Vector3(0.0, 1.2, -3.0), 0.0)
	# Over air on whichever side of it has none beneath for a few metres: a neighbour along
	# a row is under a metre away, and a step off that side would be a step onto it.
	var off := Vector3.INF
	for d: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
		var clear := true
		for reach in [safe.half + 1.0, safe.half + 2.5, safe.half + 4.0]:
			var at: Vector3 = safe.centre + d * float(reach)
			if platforms.index_at(at.x, at.z) != -1:
				clear = false
		if clear:
			off = safe.centre + d * (safe.half + 1.0)
			break
	edge.place_at(off + Vector3(0.0, 1.2, 0.0), 0.0)
	keeper.place_at(safe.centre + Vector3(-1.0, 1.2, 1.0), 0.0)
	other.place_at(safe.centre + Vector3(-1.0, 1.2, -1.0), 0.0)
	await _step(game, 30)

	_check(
		middle.is_alive() and near.is_alive() and out.is_alive()
			and middle.standing_on == index and near.standing_on == index and out.standing_on == index,
		"three people are standing on one platform",
		"on %d, %d, %d of %d" % [middle.standing_on, near.standing_on, out.standing_on, index]
	)

	var went := platforms.collapse(index, ScPlatforms.WHY_LEAN)
	_check(went, "which comes off its pillar by lean")

	# Six seconds and a quarter: a forty-metre drop is under three, and the rest is anybody
	# who landed on something standing there.
	await _step(game, 400)

	var how := func(who: ScPlayer) -> String:
		return "%s: alive %s at y %.2f, cause %s" % [
			String(who.player_id), who.is_alive(), who.controller.state.position.y,
			String(fell.get(who.player_id, &"-")),
		]

	_check(
		fell.get(&"middle", &"") == ScGame.DIED_FELL,
		"somebody standing over the pillar falls with the platform",
		how.call(middle)
	)
	_check(
		fell.get(&"near", &"") == ScGame.DIED_FELL,
		"and so does somebody inside its radius",
		how.call(near)
	)
	_check(
		fell.get(&"out", &"") == ScGame.DIED_FELL,
		"and somebody outside it, who reaches the floor",
		how.call(out)
	)
	_check(
		fell.get(&"edge", &"") == ScGame.DIED_FELL,
		"and a step off a standing platform's edge is a fall to the floor too",
		how.call(edge)
	)
	_check(
		keeper.is_alive() and other.is_alive() and not fell.has(&"keeper"),
		"while the people on a standing platform are untouched",
		"%s, %s" % [how.call(keeper), how.call(other)]
	)

	# [b]The pillar is still there, and still stops what is thrown at it.[/b] The marker is the
	# point of leaving it (`pillar_falls_with_platform`), and a prop or a chopper passing
	# through one would read as a broken map. It is a person it does not hold.
	_check(
		deck.pillar != null and is_instance_valid(deck.pillar) and deck.pillar.is_inside_tree(),
		"the bare pillar is left standing, as the marker it is"
	)
	_check(
		game.physics.collides(&"prop", &"pillar") and game.physics.collides(&"vehicle", &"pillar")
			and not game.physics.collides(&"player", &"pillar")
			and deck.pillar.collision_layer == game.physics.layer_mask(&"pillar"),
		"solid to a prop and a chopper, and never to a person"
	)

	await _dispose(game)
	_finished()


func _test_the_round() -> void:
	_section("a round is two games with a teleport in the middle")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 4.0
		c.showdown_warmup_seconds = 1.0
		c.showdown_seconds = 20.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
		c.clear_platforms_for_showdown = false
	)

	game.add_player(&"a", "A", 1)
	game.add_player(&"b", "B", 2)
	game.start()

	await _step(game, 4)
	_check(game.phase == ScGame.Phase.SURVIVAL, "it starts on the platforms",
		ScGame.Phase.keys()[game.phase])

	var somewhere: Vector3 = (game.players[&"a"] as ScPlayer).controller.state.position
	_check(somewhere.y > game.config.deck_height * 0.5, "with everybody up in the air",
		"%.1f m" % somewhere.y)

	# Past the survival clock.
	await _step(game, int(4.2 * TICK_RATE))
	_check(game.phase == ScGame.Phase.HANDOVER, "the clock sends them to the corners",
		ScGame.Phase.keys()[game.phase])

	var corner: ScPlayer = game.players[&"a"]
	var expected := game.arena.corner_point(0, game.config.team_count)
	var moved := Vector2(
		corner.controller.state.position.x - expected.x,
		corner.controller.state.position.z - expected.z
	).length()

	_check(moved < game.config.corner_size, "they are actually in their corner",
		"%.1f m from the middle of it" % moved)
	_check(corner.weapons != null, "and they are holding something")
	_check(corner.health.invulnerable, "and cannot be shot yet")

	# [b]Facing inward, and a teleport that gets the position right and the yaw wrong is
	# invisible to every count and obvious to every player.[/b] The corner is on +X for team
	# one, so facing the middle is facing -X, which in this motor's frame is a yaw of -90.
	var facing := Basis.from_euler(Vector3(0.0, deg_to_rad(corner.controller.state.yaw), 0.0))
	var middle := game.arena.showdown_centre()
	var toward_middle := Vector3(
		middle.x - expected.x, 0.0, middle.z - expected.z
	).normalized()
	_check((-facing.z).dot(toward_middle) > 0.7, "looking at the middle",
		"%.2f" % (-facing.z).dot(toward_middle))

	await _step(game, int(1.2 * TICK_RATE))
	_check(game.phase == ScGame.Phase.SHOWDOWN, "and then the weapons go hot",
		ScGame.Phase.keys()[game.phase])
	_check(not corner.health.invulnerable, "with nobody protected any more")

	# The round ends when a side has nobody left, which is dot-match's elimination rule
	# reading this game's own `alive_fn`. Unwired it falls back to a clock, and the tell is
	# visible in the first round played.
	var ended: Array[int] = []
	game.round_over.connect(func(_number: int, winner: int) -> void: ended.append(winner))

	game.players[&"b"].health.health = 0.0
	game.players[&"b"].health.alive = false

	await _step(game, 8)

	_check(not ended.is_empty(), "the round ends when a side is wiped out")
	_check(ended.is_empty() or ended[0] == 1, "and the other side won",
		"winner=%d" % (ended[0] if not ended.is_empty() else -1))

	await _dispose(game)
	_finished()


func _test_specials() -> void:
	_section("specials multiply and stack")

	var plain := ScSpecials.Active.new()
	_check(plain.is_plain(), "nothing in force is nothing in force")
	_check(is_equal_approx(plain.gravity_scale, 1.0), "and multiplies nothing")

	var feather := ScSpecials.by_id(&"feather")
	var barrage := ScSpecials.by_id(&"barrage")
	_check(feather != null and barrage != null, "the catalogue has the ones it says it has")

	var both := ScSpecials.Active.new()
	both.fold(feather)
	both.fold(barrage)

	_check(both.ids.size() == 2, "two at once is two at once")
	_check(both.gravity_scale < 1.0, "low gravity is still low gravity",
		"%.2f" % both.gravity_scale)
	_check(both.cannon_interval_scale < 0.5, "and the barrage is still a barrage",
		"%.2f" % both.cannon_interval_scale)

	# An allow-list of ids that names nothing is an operator's typo, and a server whose
	# specials silently never happen is worse than one that ignores the setting.
	var mistyped := ScConfig.new()
	mistyped.special_ids = PackedStringArray(["not_a_special"])
	_check(ScSpecials.available(mistyped).size() == ScSpecials.all().size(),
		"a special list naming nothing falls back to everything")

	var narrowed := ScConfig.new()
	narrowed.special_ids = PackedStringArray(["feather", "slick"])
	_check(ScSpecials.available(narrowed).size() == 2, "and a real list narrows it")

	# It reaches the world: low gravity is one call on the physics space and one on every
	# player's tunables, and a special that changed neither would be a document nothing reads.
	var game := await _world(func(c: ScConfig) -> void:
		c.specials_enabled = false
	)
	var player := game.add_player(&"light", "Light", 1)
	var before := player.controller.tunables.gravity

	player.retune(both)
	_check(player.controller.tunables.gravity < before, "a player's own gravity comes down",
		"%.1f from %.1f" % [player.controller.tunables.gravity, before])
	_check(player.controller.tunables.max_speed > 0.0, "and they can still move")

	await _dispose(game)
	_finished()


## [b]The half of this game that is a gunfight, asserted for the first time.[/b]
##
## Everything else here checks that a weapon EXISTS: that a survivor is holding one, that
## the fire counter goes up, that hitboxes are registered, that a health record is kept. The
## round test kills its loser by assigning `health = 0.0`. So every check in this repository
## passed on a showdown in which no shot had ever reduced anybody's health, and there was no
## way to tell from the inside.
##
## What made it visible was running bots against each other for twenty rounds: every round
## ended with exactly two alive and a draw, which is one survivor per side, every time. A
## number that is the same every round is a number nothing is deciding.
##
## So this is the whole chain in one check — a command's button, the arsenal's tick, the
## shot it emits, the trace against the world, the hitbox it finds, the damage rules, and
## the health record — and it is the only check here that fails if any link in it breaks.
func _test_a_shot_lands() -> void:
	_section("a shot finds a player")

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

	var hot := game.phase == ScGame.Phase.SHOWDOWN
	_check(hot, "the showdown is running", ScGame.Phase.keys()[game.phase])

	if not hot:
		# Deliberately NOT returning early: a section that stops adding checks is a section
		# the CHECKS total reports as a hole rather than as a failure, and a hole reads like
		# somebody edited the file. Everything below fails honestly instead.
		pass

	_check(shooter.weapons != null and target.weapons != null, "both are armed")
	_check(not target.health.invulnerable, "and the target can be hurt")

	# Face to face at eight metres, on the shooter's own pad, so the trace has the pad under
	# it and nothing else between them. Placed rather than walked: this check is about the
	# shot, and a bot that fell off on the way would fail it for the wrong reason.
	var stand := shooter.controller.state.position
	var toward := game.arena.showdown_centre() - stand
	toward.y = 0.0
	toward = toward.normalized()

	shooter.place_at(stand, rad_to_deg(atan2(-toward.x, -toward.z)))
	target.place_at(stand + toward * 8.0, rad_to_deg(atan2(toward.x, toward.z)))

	await _step(game, 4)

	var before := target.health.health
	_check(before > 0.0, "the target starts alive", "%.0f hp" % before)

	# Aimed at the chest rather than along the floor: a trace from an eye to a point eight
	# metres away at the same height passes through a standing capsule, and one aimed at the
	# feet does not.
	var eye := shooter.eye_position()
	var at := target.eye_position()
	var line := (at - eye).normalized()

	var fired := 0

	for _i in range(int(1.5 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.pitch = clampf(rad_to_deg(asin(clampf(line.y, -1.0, 1.0))), -89.0, 89.0)
		command.set_button(DotFpsCommand.BUTTON_USER_0, true)
		shooter.controller.apply_command(command)

		fired = maxi(fired, shooter.weapons.fire_seq)
		game.simulate(TICK)
		await _physics_frame()

		if target.health.health < before:
			break

	_check(shooter.weapons.fire_seq > 0, "the weapon fires",
		"%d uses" % shooter.weapons.fire_seq)
	_check(
		target.health.health < before,
		"and the target takes damage",
		"%.0f -> %.0f hp after %d uses"
			% [before, target.health.health, shooter.weapons.fire_seq]
	)

	# [b]The other half of the rule, and the one a game gets wrong quietly.[/b] Friendly fire
	# is off, so a shot down the same line at a team mate has to find nothing to do. A game
	# that resolved it anyway would play correctly right up until two people on one side
	# stood in front of each other.
	var mate := game.add_player(&"mate", "Mate", 1)
	mate.place_at(stand + toward * 8.0, rad_to_deg(atan2(toward.x, toward.z)))
	target.place_at(stand + toward * 40.0, rad_to_deg(atan2(toward.x, toward.z)))

	await _step(game, 4)

	var mate_before := mate.health.health

	for _i in range(int(1.0 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-line.x, -line.z))
		command.pitch = 0.0
		command.set_button(DotFpsCommand.BUTTON_USER_0, true)
		shooter.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	_check(
		is_equal_approx(mate.health.health, mate_before),
		"a team mate in the way takes none",
		"%.0f -> %.0f hp" % [mate_before, mate.health.health]
	)

	await _dispose(game)
	_finished()


func _test_the_chopper() -> void:
	_section("the chopper flies")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.chopper_enabled = true
	)

	var copter := game.vehicles.spawn(
		ScContent.COPTER,
		Vector3(0.0, game.config.deck_height + 8.0, 0.0),
		ScContent.WORLD_OWNER
	)

	_check(copter != null, "it spawns")

	if copter == null:
		# Three checks that cannot run without one. Counted anyway, because a section that
		# quietly runs fewer checks than it says is the thing the CHECKS total exists for.
		_check(false, "it has a chassis")
		_check(false, "and the drag it always flew with")
		_check(false, "it climbs on full collective")
		_check(false, "and holds height at neutral")
		_check(false, "and will not climb past its ceiling")
		_check(false, "a pilot who puts it down on the floor has fallen")
		_check(false, "and it is recorded as a fall")
		await _dispose(game)
		_finished()
		return

	var chassis := copter.chassis as ScCopter
	_check(chassis != null, "it has a chassis")

	chassis.lift_ratio = game.config.chopper_lift
	chassis.gravity = game.config.gravity
	copter.meta[ScCopter.META_CEILING] = game.config.deck_height + game.config.chopper_ceiling

	var body := copter.body()
	var started_at := body.global_position.y

	# dot-vehicle writes the tunables' damping onto the body in REPLACE mode (4f4afaf); before,
	# the chopper's 0.12 COMBINED with the project's 0.1. The same 0.22 either way.
	var drag := body.linear_damp + (ProjectSettings.get_setting("physics/3d/default_linear_damp", 0.1) as float if body.linear_damp_mode == RigidBody3D.DAMP_MODE_COMBINE else 0.0)
	_check(is_equal_approx(drag, 0.22), "and the drag it always flew with", "%.2f" % drag)

	# Full collective for two seconds. A helicopter that cannot climb is one nobody can tell
	# from a broken one.
	var climb := DotVehicleCommand.new()
	climb.throttle = 1.0

	for _i in range(int(2.0 * TICK_RATE)):
		chassis.drive(climb, TICK)
		await _physics_frame()

	_check(body.global_position.y > started_at + 1.0, "it climbs on full collective",
		"%.1f m from %.1f m" % [body.global_position.y, started_at])

	# And it holds itself up at neutral, which is what makes the control readable: a machine
	# whose neutral is a slow sink is one a player is fighting the whole time.
	#
	# [b]From rest, because neutral does not arrest a climb and should not.[/b] A helicopter
	# at neutral collective is holding its weight, not braking — so a pilot who lets go at
	# eighteen metres a second keeps going up, which is what the ceiling is for. Measuring
	# that as "drift" would be asserting that the machine has air brakes.
	body.linear_velocity = Vector3.ZERO
	var hovering := body.global_position.y
	var hover := DotVehicleCommand.new()

	for _i in range(int(1.0 * TICK_RATE)):
		chassis.drive(hover, TICK)
		await _physics_frame()

	_check(absf(body.global_position.y - hovering) < 2.5, "and holds height at neutral",
		"%.2f m of drift" % (body.global_position.y - hovering))

	# The ceiling holds rather than shoves. One that pushed back would throw a pilot who
	# touched it through the map.
	body.global_position = Vector3(0.0, float(copter.meta[ScCopter.META_CEILING]) + 3.0, 0.0)
	body.linear_velocity = Vector3.ZERO

	for _i in range(int(1.5 * TICK_RATE)):
		chassis.drive(climb, TICK)
		await _physics_frame()

	_check(body.linear_velocity.y <= 0.5, "and will not climb past its ceiling",
		"%.2f m/s" % body.linear_velocity.y)

	# [b]The floor is the one thing nobody survives, and a seat used to be the exception.[/b]
	# A rider was skipped by the fall check because their own position stops moving while
	# they are carried — so a pilot could park on the floor out of the cannon's reach, or fly
	# off the edge of the map and fall for the rest of the round, and be handed a weapon in
	# the corners either way. Measured by the machine now, parked where it would really rest.
	var pilot := game.add_player(&"pilot", "Pilot", 1)
	game.add_player(&"other", "Other", 2)

	var deaths: Array[StringName] = []
	game.player_died.connect(
		func(id: StringName, _by: StringName, why: StringName) -> void:
			if id == &"pilot":
				deaths.append(why)
	)

	body.global_position = Vector3(0.0, game.config.deck_height, game.arena._field_reach() + 10.0)
	body.linear_velocity = Vector3.ZERO
	pilot.place_at(body.global_position + Vector3(1.0, 0.0, 0.0), 0.0)
	var boarded := game.try_board(&"pilot")

	body.global_position.y = game.config.kill_height + 0.9

	for _i in range(4):
		game.simulate(TICK)
		await _physics_frame()

	_check(boarded.ok and not pilot.is_alive() and not pilot.riding,
		"a pilot who puts it down on the floor has fallen",
		"boarded %s, alive %s, riding %s" % [boarded.ok, pilot.is_alive(), pilot.riding])
	_check(deaths.has(ScGame.DIED_FELL), "and it is recorded as a fall",
		", ".join(Array(deaths).map(func(v: Variant) -> String: return String(v))))

	await _dispose(game)
	_finished()


## A player standing on a chopper goes where it goes.
func _test_riding_the_chopper() -> void:
	_section("a player standing on a chopper is carried by it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.layout_ids = PackedStringArray(["airfield"])
	)

	_check(game.layout != null and game.layout.with_chopper and not game._copter_ids.is_empty(),
		"the airfield parks a chopper")

	var copter := game.vehicles.get_vehicle(game._copter_ids[0]) if not game._copter_ids.is_empty() else null

	if copter == null:
		_check(false, "and it can be stood on")
		_check(false, "and it takes its rider with it")
		_check(false, "and the rider is still on it")
		_check(false, "and getting off leaves them where they stepped")
		await _dispose(game)
		_finished()
		return

	var body := copter.body()
	_check(body.has_meta(ScPlayer.META_CARRIER), "it is marked as something that carries")

	# Held where it is and moved by hand, so the check is the carry and not the flying.
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.global_position = Vector3(0.0, game.config.deck_height + 30.0, 0.0)
	body.global_rotation = Vector3.ZERO

	var rider := game.add_player(&"rider", "Rider", 1)
	game.add_player(&"other", "Other", 2)
	rider.place_at(body.global_position + Vector3(0.0, 2.2, 0.0), 0.0)
	await _step(game, 30)

	var on_it := rider.controller.state.ground_id == body.get_instance_id()
	_check(on_it, "and it can be stood on",
		"standing on %s" % str(rider.controller.state.ground_id))

	var start_x := rider.controller.state.position.x
	var start_y := rider.controller.state.position.y

	for _i in range(40):
		body.global_position += Vector3(0.3, 0.05, 0.0)
		game.simulate(TICK)
		await _physics_frame()

	var carried_x := rider.controller.state.position.x - start_x
	var carried_y := rider.controller.state.position.y - start_y
	_check(carried_x > 10.0 and carried_y > 1.0, "and it takes its rider with it",
		"%.1f m along, %.1f m up of 12 and 2" % [carried_x, carried_y])
	_check(rider.controller.state.ground_id == body.get_instance_id(),
		"and the rider is still on it")

	# Off it: sideways, onto nothing, and then it is no longer theirs to move.
	rider.place_at(body.global_position + Vector3(30.0, 2.2, 0.0), 0.0)
	var left_at := rider.controller.state.position.x
	body.global_position += Vector3(5.0, 0.0, 0.0)
	await _step(game, 5)
	_check(absf(rider.controller.state.position.x - left_at) < 1.0,
		"and getting off leaves them where they stepped",
		"%.2f m" % (rider.controller.state.position.x - left_at))

	await _dispose(game)
	_finished()


## dot-core's audit over every layout's field: drawn geometry nothing collides with is walked
## through. Strict, so a new mesh must have a shape or say (`dot_no_collision`) why not.
func _test_collision_audit() -> void:
	_section("nothing drawn in a layout is walked through")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var unshaped := PackedStringArray()

	for layout in ScLayouts.all(game.config):
		game.platforms.build(layout, game.physics)
		await _physics_frame()
		var res := DotCollisionAudit.audit(game, true)

		if res.ok:
			var report: DotCollisionAudit = res.value
			print("  ..    %s collision audit: %d of %d" % [String(layout.id), report.count(), report.examined])

			if report.count() > 0:
				unshaped.append("%s (%d)" % [layout.id, report.count()])

				for line in report.describe_lines().slice(1, 12):
					print("    %s" % line)
		else:
			unshaped.append("%s (audit failed: %s)" % [layout.id, res.error.message])

	_check(unshaped.is_empty(), "every layout's drawn geometry is solid or opted out", ", ".join(unshaped))
	# Gone before the next section: its decks sit in the shared physics space, and a later
	# section's runners would stand on them.
	await _dispose(game)
	_finished()


## Every piece the new layouts are made of stands, and comes off its pillar like any other.
func _test_the_pieces() -> void:
	_section("ramps, towers and stepped islands stand at their heights and fall like platforms")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms

	for id: StringName in [&"terraces", &"ring", &"watchtowers"]:
		var layout: ScLayouts.Layout = null

		for candidate in ScLayouts.all(config):
			if candidate.id == id:
				layout = candidate

		_check(layout != null, "%s is a layout" % id)

		if layout == null:
			continue

		platforms.build(layout, game.physics)
		await _physics_frame()
		var label := String(id)

		# Bigger than the ordinary field, and not one flat height.
		var heights: Dictionary = {}
		var towers := 0
		var ramps := 0

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)
			heights["%.2f" % deck.centre.y] = true
			towers += 1 if deck.is_tower else 0

			if deck.is_bridge:
				var near := platforms.deck_at(deck.supports.x)
				var far := platforms.deck_at(deck.supports.y)

				if absf(near.centre.y - far.centre.y) > 0.1:
					ramps += 1
					# A ramp is walkable: its slope is under what the motor climbs.
					var run := deck.lips.y - deck.lips.x
					var slope := rad_to_deg(atan2(absf(near.centre.y - far.centre.y), run))
					_check(slope < ScPlayer.tunables_for(config, null).max_slope_angle,
						"%s ramp (%d,%d) is walkable" % [label, deck.column, deck.row],
						"%.1f degrees" % slope)

		_check(platforms.count() >= 10 and heights.size() >= 3,
			"%s is a bigger field at several heights" % label,
			"%d pieces at %d heights" % [platforms.count(), heights.size()])
		_check(towers > 0 or id == &"terraces", "%s has its towers" % label)
		_check(ramps > 0 or id == &"terraces", "%s has ramps" % label)

		# Every piece has a pillar that reaches the floor from its own height, and each is
		# standing at first.
		var pillars_ok := true

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if not deck.is_standing():
				pillars_ok = false

			if deck.pillar != null:
				var top := deck.pillar.position.y + 0.5 * (
					deck.pillar.get_node(^"Collision").shape as CylinderShape3D).height

				if absf(top - (deck.centre.y - config.platform_thickness)) > 0.01:
					pillars_ok = false

		_check(pillars_ok, "%s: every piece is standing on a pillar of its own height" % label)

		# The cells survive the wire, kinds and levels both.
		var cells := platforms.cells()
		var back := ScEvents.read_layout(DotNetReader.new(ScEvents.write_layout(
			layout.id, platforms.field_columns(), platforms.field_rows(), config.column_pitch,
			config.row_pitch, config.platform_size, config.deck_height, layout.pitch_scale,
			layout.stiffness_scale, cells, layout.row_pitch_scale, layout.row_shift
		)))
		var came: Array[Vector3i] = back["cells"]
		_check(bool(back["ok"]) and came == cells,
			"%s: every piece's kind and level crosses the wire" % label)

		# Each kind of piece comes off its pillar when it is leant on, and takes the bridges
		# resting on it along. Tried on a fresh build for each, on the highest piece.
		var highest := 0

		for i in range(platforms.count()):
			if not platforms.deck_at(i).is_bridge \
					and platforms.deck_at(i).centre.y > platforms.deck_at(highest).centre.y:
				highest = i

		if platforms.deck_at(highest).is_bridge:
			highest = 0

		var piece := platforms.deck_at(highest)
		var edge := piece.centre + Vector3(piece.half, 0.0, 0.0)

		for _i in range(900):
			if not piece.is_standing():
				break

			platforms.begin_loads()
			platforms.add_load(highest, edge, 800.0, config.run_speed)
			platforms.step(TICK)

		_check(not piece.is_standing(), "%s: its highest piece comes off its pillar" % label,
			"%.3f rad" % piece.tilt())

		for _i in range(4):
			platforms.begin_loads()
			platforms.step(TICK)

		var orphans := 0

		for i in range(platforms.count()):
			var deck := platforms.deck_at(i)

			if deck.is_bridge and (deck.supports.x == highest or deck.supports.y == highest) \
					and deck.is_standing():
				orphans += 1

		_check(orphans == 0, "%s: and a bridge resting on it goes too" % label,
			"%d left standing" % orphans)

		# And a shattering hit takes a bridge as it takes a platform.
		platforms.build(layout, game.physics)
		await _physics_frame()

		for i in range(platforms.count()):
			if platforms.deck_at(i).is_bridge:
				var outcome := platforms.report_impact(
					i, config.platform_shatter_impulse * 2.0, 1.0,
					platforms.deck_at(i).centre + Vector3(0.5, 0.0, 0.0))
				_check(outcome == ScPlatforms.Impact.SHATTERED and not platforms.deck_at(i).is_standing(),
					"%s: a bridge shatters from one big hit" % label)
				break

		# [b]Every piece can fall, not only the highest.[/b] The core mechanic is that the floor
		# goes, so a piece that held its pillar whatever stood on it would be a place to hide.
		# Each non-bridge piece gets its own fresh build and a runner on its edge.
		var stuck: Array[int] = []

		for i in range(platforms.count()):
			if platforms.deck_at(i).is_bridge:
				continue

			platforms.build(layout, game.physics)
			await _physics_frame()
			var each := platforms.deck_at(i)
			var rim := each.centre + Vector3(each.half, 0.0, 0.0)

			for _j in range(900):
				if not each.is_standing():
					break

				platforms.begin_loads()
				platforms.add_load(i, rim, 800.0, config.run_speed)
				platforms.step(TICK)

			if each.is_standing():
				stuck.append(i)

		_check(stuck.is_empty(), "%s: every piece comes off its pillar" % label,
			"stuck: %s" % str(stuck))

	await _dispose(game)
	_finished()


## The layouts are dot-map's maps: listed, changeable by command, voted from the catalogue.
func _test_the_map_catalogue() -> void:
	_section("the layouts are listed, changed and voted as dot-map maps")

	var config := ScConfig.new()
	var catalogue := ScLayouts.catalogue(config)
	var layouts := ScLayouts.allowed(config)

	_check(catalogue.size() == layouts.size() and catalogue.problems().is_empty(),
		"every layout is a valid map def", "%d of %d; %s" % [
			catalogue.size(), layouts.size(), ", ".join(catalogue.problems())])
	_check(catalogue.has(&"ring") and catalogue.has(&"terraces") and catalogue.has(&"watchtowers"),
		"and the bigger maps are in it")

	var session := ScMapSession.new()
	session.catalogue = catalogue
	var asked: Array[StringName] = []
	session.apply_fn = func(id: StringName) -> DotResult:
		asked.append(id)
		return DotResult.success(id)
	add_child(session)

	var changed := await session.change_to(&"ring")
	_check(changed.ok and asked == [&"ring"] and session.current != null and session.current.id == &"ring",
		"a change through the session reaches the game and becomes current")

	var refused := await session.change_to(&"nowhere")
	_check(not refused.ok and asked.size() == 1, "and an unknown map is refused")

	session.apply_fn = func(_id: StringName) -> DotResult:
		return DotResult.fail(DotError.CODE_STATE, "no")
	var failed := await session.change_to(&"terraces")
	_check(not failed.ok and session.current.id == &"ring", "and a refusal leaves the map as it was")

	remove_child(session)
	session.free()

	# And a server that has the module has the commands.
	var game := await _world()
	var ids := ScLayouts.catalogue(game.config)
	_check(ids.size() >= 9, "the catalogue lists the whole set", "%d maps" % ids.size())
	await _dispose(game)
	_finished()


## [b]The one thing neither the suite nor the editor can see: what happens once this is a
## pack.[/b] Every finding in this section came from a delivered server rather than from
## here, and each is a check written afterwards so the next one is caught before the boot.
func _test_reach() -> void:
	_section("every jump a layout means is inside a running jump, and no other is")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms

	# [b]The arithmetic first, so a wrong answer below is a wrong map and not wrong sums.[/b]
	# Read off the controller's own tunables: flat, a running jump is the run speed times
	# the whole airtime; above the apex it is no jump at all.
	var t := ScPlayer.tunables_for(config, null)
	var flat := ScPlayer.jump_reach(config, 0.0)
	var airtime := 2.0 * sqrt(2.0 * t.gravity * t.jump_height) / t.gravity
	_check(
		absf(flat - t.max_speed * airtime) < 0.001
			and ScPlayer.jump_reach(config, 0.5) < flat
			and is_zero_approx(ScPlayer.jump_reach(config, t.jump_height + 0.01)),
		"the reach is the movement's own, and shrinks as the landing rises",
		"%.2f m flat, %.2f m onto 0.5 m" % [flat, ScPlayer.jump_reach(config, 0.5)]
	)

	var too_far := PackedStringArray()
	var too_near := PackedStringArray()
	var unmet := PackedStringArray()
	var closest := PackedStringArray()
	var parked := PackedStringArray()

	for layout in ScLayouts.all(config):
		platforms.build(layout, game.physics)
		var cells := platforms.cells()
		var meant := 0
		var tightest := ""
		var tightest_margin := INF

		for pair: Vector3i in ScLayouts.pairs(cells):
			var declared := (layout.jumps & pair.z) != 0

			# Both ways, because the dip is the LAUNCH platform's and two platforms need
			# not lean alike.
			for way: Vector2i in [Vector2i(pair.x, pair.y), Vector2i(pair.y, pair.x)]:
				var air := platforms.clear_air(way.x, way.y)
				var gap := air.y
				var label := "%s %s->%s" % [layout.id, _cell_name(platforms, way.x),
					_cell_name(platforms, way.y)]

				if declared:
					meant += 1
					var dip := _run_up_dip(platforms, config, way.x, way.y, air.x)
					# A landing that is a level higher is that much more to rise: the stepped
					# layouts put their platforms at different heights on purpose.
					dip += maxf(
						platforms.deck_at(way.y).centre.y - platforms.deck_at(way.x).centre.y, 0.0)
					var reach := ScPlayer.jump_reach(config, dip)

					if gap > reach:
						too_far.append("%s %.2f m of air, %.2f m reach off a %.2f m dip" % [
							label, gap, reach, dip])
					elif reach - gap < tightest_margin:
						tightest_margin = reach - gap
						tightest = "%s %.2f m of %.2f" % [label, gap, reach]
				elif gap <= flat:
					# The most generous jump there is: flat, at a run. Anything inside it is
					# a crossing the layout never meant and a player will find.
					too_near.append("%s %.2f m of air, inside %.2f m" % [label, gap, flat])

		if layout.jumps != 0 and meant == 0:
			unmet.append(String(layout.id))

		if tightest != "":
			closest.append(tightest)

		if layout.with_chopper:
			for i in range(config.chopper_count):
				var pad := game.chopper_pad_on(layout, i)

				if platforms.index_at(pad.x, pad.z) < 0:
					parked.append("%s chopper %d" % [layout.id, i])

	_check(too_far.is_empty(), "every jump a layout means can be made from a run",
		"; ".join(too_far) if not too_far.is_empty() else ", ".join(closest))
	_check(too_near.is_empty(), "and every jump it does not mean cannot",
		"; ".join(too_near))
	_check(unmet.is_empty(), "and no layout means a kind of jump it has none of",
		", ".join(unmet))
	# The chopper is parked in the air and comes to rest on whatever is under it; over a
	# gap it comes to rest forty metres down, where nobody can get into it.
	_check(parked.is_empty(), "every parked chopper settles onto a platform",
		", ".join(parked))

	await _dispose(game)
	_finished()


func _test_the_throat() -> void:
	_section("nothing is built over the cannon's mouth, and every shot gets out")

	var game := await _world(func(c: ScConfig) -> void:
		c.specials_enabled = false
	)
	var config := game.config
	var platforms := game.platforms
	var muzzle := game.arena.muzzle()
	var active := ScSpecials.Active.new()

	var crowded := PackedStringArray()
	var margins := PackedStringArray()
	var stuck := PackedStringArray()
	var fired := 0

	for layout in ScLayouts.all(config):
		platforms.build(layout, game.physics)
		await _physics_frame()
		await _physics_frame()

		var clear := platforms.clearance_from(muzzle.x, muzzle.z)
		margins.append("%s %.1f" % [layout.id, clear])

		if clear < ScArena.THROAT_CLEARANCE:
			crowded.append("%s %.2f m" % [layout.id, clear])

		# [b]Fired, not only measured[/b], and with every tier unlocked: at the start of a
		# round the cannon throws crates, and a crate gets through a slot a monolith does
		# not. Eight shots a layout, each watched for half a second.
		var blocked := 0

		for _shot in range(8):
			var prop: DotPropInstance = game.cannon.call("_launch_one", 1000.0, active)

			if prop == null:
				continue

			fired += 1
			var top := -INF

			for _t in range(32):
				game.simulate(TICK)
				await _physics_frame()
				var body := prop.body()

				if body == null or not is_instance_valid(body):
					break

				top = maxf(top, body.global_position.y)

			if top < config.deck_height + 2.0:
				blocked += 1

			var _gone := game.props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

		if blocked > 0:
			stuck.append("%s %d of 8" % [layout.id, blocked])

	_check(crowded.is_empty(), "no layout builds anything over the cannon's mouth",
		"; ".join(crowded) if not crowded.is_empty() else ", ".join(margins))
	_check(fired == 8 * ScLayouts.all(config).size() and stuck.is_empty(),
		"and every shot on every layout climbs past the decks",
		"%d fired; %s" % [fired, ", ".join(stuck) if not stuck.is_empty() else "none held"])

	await _dispose(game)
	_finished()


## How far below the deck the lip a runner leaves from has gone by the time they reach it.
##
## [b]The platform's own model, stepped the way a run steps it.[/b] A lone runner from the
## middle to the edge at full speed, loading the deck the way [ScGame] loads it, and the
## surface under the edge read at the moment they arrive. That is the rise the jump has to
## make up — at the ordinary numbers about 0.3 m mid-edge and 0.7 m at a corner, which on
## a 1.15 m apex is most of the difference between a jump and a wall.
func _run_up_dip(
	platforms: ScPlatforms, config: ScConfig, from: int, to: int, leave: float
) -> float:
	var deck := platforms.deck_at(from)
	var target := platforms.deck_at(to)
	deck.lean = Vector2.ZERO
	deck.lean_velocity = Vector2.ZERO
	deck.sink = 0.0
	deck.sink_velocity = 0.0

	var heading := Vector3(target.centre.x - deck.centre.x, 0.0, target.centre.z - deck.centre.z)
	heading = heading.normalized()
	var at := deck.centre
	var run := config.run_speed * TICK
	var travelled := 0.0

	while travelled < leave:
		travelled = minf(travelled + run, leave)
		at = deck.centre + heading * travelled
		platforms.begin_loads()
		platforms.add_load(from, at, config.player_mass, config.run_speed)
		platforms.step(TICK)

	var dip := config.deck_height - platforms.surface_y(from, at.x, at.z)

	deck.lean = Vector2.ZERO
	deck.lean_velocity = Vector2.ZERO
	deck.sink = 0.0
	deck.sink_velocity = 0.0

	return maxf(dip, 0.0)


func _cell_name(platforms: ScPlatforms, index: int) -> String:
	var deck := platforms.deck_at(index)
	return "(%d,%d)" % [deck.column, deck.row]


## The ring's cover: one block per team, facing that team's pad, and it covers.
func _test_the_ring_cover() -> void:
	_section("the ring has cover, and it faces the pads")

	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()

		var middle := game.arena.showdown_centre()
		var ring := game.config.corner_size * 0.85
		var cover := game.arena.ring_cover()
		var built := 0

		for index in range(cover.size()):
			if game.arena.has_node(NodePath("Showdown/RingCover%d" % index)):
				built += 1

		var on_ring := true

		for block in cover:
			var d := block.origin - middle
			if absf(d.x) > ring - 1.5 or absf(d.z) > ring - 1.5:
				on_ring = false

		_check(cover.size() == sides and built == sides and on_ring,
			"with %d sides, one block per side stands on the ring" % sides,
			"%d described, %d built, on the ring %s" % [cover.size(), built, on_ring])

		# From every pad: a person crouched right behind that pad's block is out of sight,
		# and a person standing there is not, which is what chest high means.
		var space := game.arena.get_world_3d().direct_space_state
		var hidden := 0
		var seen := 0

		for index in range(sides):
			var eye := game.arena.corner_point(index, sides) + Vector3.UP * 1.6
			var block := cover[index]
			var inward := (middle - block.origin)
			inward.y = 0.0
			inward = inward.normalized()
			var behind := block.origin + inward * (ScArena.RING_COVER_SIZE.z * 0.5 + 0.4)
			var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
			var standing := Vector3(behind.x, middle.y + 1.6, behind.z)

			var low := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched))
			var high := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, standing))

			if not low.is_empty() and String((low["collider"] as Node).name).begins_with("RingCover"):
				hidden += 1
			if high.is_empty():
				seen += 1

		_check(hidden == sides and seen == sides,
			"and from each pad it hides somebody crouched behind it, not somebody standing",
			"%d of %d hidden, %d of %d seen over it" % [hidden, sides, seen, sides])

		await _dispose(game)

	_finished()


## The flanks (2026-09-29): a perch between every two pads, joined to both by a catwalk
## that never touches the ring. Built from [method ScArena.flank_walks], walked end to end
## at a run by a bot from its own pad to the next side's, and — with two sides — the line
## on the ring the blocks do not cover. `tools/shot.sh --view=flank` is the render.
func _test_the_flanks() -> void:
	_section("the flanks: a perch between every two pads, the long way round at a run")

	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()

		var config := game.config
		var middle := game.arena.showdown_centre()
		var walks := game.arena.flank_walks()
		var perches := 0
		var slabs := 0
		var thin := PackedStringArray()

		for child: Node in game.arena.find_children("*", "StaticBody3D", true, false):
			var kerb_sides: Dictionary = {}

			for piece: Node in child.get_children():
				if String(piece.name).begins_with("KerbHit"):
					kerb_sides[String(piece.name).trim_prefix("KerbHit").get_slice("_", 0)] = true

			if String(child.name).begins_with("Perch"):
				perches += 1
				if kerb_sides.size() != 4:
					thin.append("%s has %d" % [child.name, kerb_sides.size()])
			elif String(child.name).begins_with("Flank"):
				slabs += 1
				if kerb_sides.size() != 2:
					thin.append("%s has %d" % [child.name, kerb_sides.size()])

		_check(perches == sides and slabs == sides * 2 and walks.size() == sides * 2
				and thin.is_empty(),
			"with %d sides, a perch between every two pads and a catwalk to each" % sides,
			"%d perches, %d slabs of %d described%s" % [perches, slabs, walks.size(),
				"" if thin.is_empty() else ", " + ", ".join(thin)])

		# And open where each one arrives: a ray at shin height from the middle of the pad,
		# and of the perch, out along the flank to a metre past the edge meets no kerb. A
		# runner is thrown over a closed kerb since dot-player-controller 2e6d930 and the
		# drive below cannot see one (armed: it passed with the openings uncut), so this is
		# what holds them — a walker, or a body sliding, is still stopped by one.
		var space_here := game.arena.get_world_3d().direct_space_state
		var blocked := PackedStringArray()

		for index in range(walks.size()):
			var walk := walks[index]
			var d := walk["out"] as Vector2
			var pad_mid := game.arena.corner_point(int(walk["pad"]), sides)
			var perch_mid := game.arena.perch_point(int(walk["perch"]), sides)
			var shin := Vector3.UP * 0.15
			var past := Vector3(d.x, 0.0, d.y)
			var legs := [
				[pad_mid + shin, (walk["from"] as Vector3) + past + shin],
				[perch_mid + shin, (walk["to"] as Vector3) - past + shin],
			]

			for leg: Array in legs:
				var hit := space_here.intersect_ray(
					PhysicsRayQueryParameters3D.create(leg[0] as Vector3, leg[1] as Vector3))

				if not hit.is_empty():
					blocked.append("Flank%d at %s" % [index, (hit["collider"] as Node).name])

		_check(blocked.is_empty(),
			"and the kerb is open wherever a flank arrives, at both ends",
			"%d ends clear%s" % [walks.size() * 2 - blocked.size(),
				"" if blocked.is_empty() else ": " + ", ".join(blocked)])

		# The long way round never touches the ring: every flank's centre line stays further
		# from the ring's middle than the ring's own corners plus half a catwalk.
		var ring_corner := config.corner_size * 0.85 * sqrt(2.0)
		var nearest := INF

		for walk: Dictionary in walks:
			var a := walk["from"] as Vector3
			var b := walk["to"] as Vector3
			var closest := Geometry3D.get_closest_point_to_segment(middle, a, b)
			nearest = minf(nearest, Vector2(closest.x - middle.x, closest.z - middle.z).length())

		_check(nearest > ring_corner + ScArena.CATWALK_WIDTH * 0.5 + 2.0,
			"and no flank comes near the ring",
			"nearest %.1f m from its middle, its corners at %.1f" % [nearest, ring_corner])

		# Driven: from pad 0, at a run, through perch 0 and onto pad 1's middle. Steered at
		# each waypoint's centre, running the whole way, which is what the kerb openings and
		# the dropped slab have to let through without a stall.
		var start := game.arena.corner_point(0, sides)
		var perch := game.arena.perch_point(0, sides)
		var goal := game.arena.corner_point(1, sides)
		var route: Array[Vector3] = [perch, goal]
		var length := Vector2(perch.x - start.x, perch.z - start.z).length() \
			+ Vector2(goal.x - perch.x, goal.z - perch.z).length()
		var runner := game.add_player(&"flanker", "Flanker", 1)
		runner.place_at(start + Vector3.UP * 0.2, game.arena.showdown_yaw(0, sides))
		await _step(game, 20)
		_track(runner)

		var next := 0
		var ticks := 0
		var lowest := INF

		for _i in range(int(45.0 * TICK_RATE)):
			var at := runner.controller.state.position
			var toward := Vector3(route[next].x - at.x, 0.0, route[next].z - at.z)

			if toward.length() < 1.0:
				next += 1
				if next >= route.size():
					break
				toward = Vector3(route[next].x - at.x, 0.0, route[next].z - at.z)

			var command := DotFpsCommand.new()
			command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
			command.move = Vector2(0.0, 1.0)
			runner.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()
			ticks += 1
			lowest = minf(lowest, runner.controller.state.position.y)

		var covered := _covered
		var top := _top_speed
		_track(null)
		var max_speed := ScPlayer.tunables_for(config, null).max_speed
		var seconds := float(ticks) / float(TICK_RATE)
		var ended := runner.controller.state.position

		_check(next >= route.size() and runner.is_alive() and lowest > middle.y - 0.5,
			"a runner goes pad 0, perch 0, pad 1 without a fall",
			"reached %d of %d waypoints, lowest %.2f m against %.2f, ended %.1f m from pad 1" % [
				next, route.size(), lowest, middle.y,
				Vector2(ended.x - goal.x, ended.z - goal.z).length()])
		# At a run the whole way: the route over the time is the pace, and a stall on a kerb
		# or a seam at either end of a slab is a second or more lost.
		_check(covered >= length * 0.97 and top >= max_speed * 0.95
				and seconds <= length / max_speed + 1.5,
			"and at a run: the route in its running time",
			"%.1f m of %.1f in %.2f s (%.2f s at %.2f m/s), top %.2f" % [
				covered, length, seconds, length / max_speed, max_speed, top])

		# With two sides a perch is ninety degrees off both blocks, which is the point of it:
		# somebody crouched behind a ring block, hidden from the pad it faces, is in plain
		# sight from either perch. With three the angle is 60 and the block still covers.
		if sides == 2:
			var space := game.arena.get_world_3d().direct_space_state
			var cover := game.arena.ring_cover()
			var seen := 0
			var asked := 0

			for p in range(sides):
				var eye := game.arena.perch_point(p, sides) + Vector3.UP * 1.6

				for block in cover:
					var inward := middle - block.origin
					inward.y = 0.0
					inward = inward.normalized()
					var behind := block.origin + inward * (ScArena.RING_COVER_SIZE.z * 0.5 + 0.4)
					var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
					asked += 1

					if space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched)).is_empty():
						seen += 1

			_check(seen == asked,
				"and from either perch, somebody crouched behind either ring block is in sight",
				"%d of %d lines clear" % [seen, asked])

		await _dispose(game)

	_finished()


## The dais (2026-10-01): a 4 m block 0.9 m high on the ring's middle. Run to from a pad
## and jumped onto, at a run; somebody crouched against its far side is hidden from any pad
## or perch; and from its top every pad and every perch is in sight.
## `tools/shot.sh --view=dais` is the render.
func _test_the_dais() -> void:
	_section("the ring's dais: one jump up, cover that turns, and the high ground")

	var sides := 2
	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = sides
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	await _physics_frame()

	var config := game.config
	var middle := game.arena.showdown_centre()
	var half := ScArena.DAIS_SIZE.x * 0.5
	var top := middle.y + ScArena.DAIS_SIZE.y

	_check(game.arena.has_node(^"Showdown/RingDais")
			and absf(game.arena.dais().origin.y + ScArena.DAIS_SIZE.y * 0.5 - top) < 0.001
			and ScArena.DAIS_SIZE.y > ScPlayer.tunables_for(config, null).step_height
			and ScArena.DAIS_SIZE.y < config.jump_height,
		"the dais stands on the ring's middle, over a step and under a jump",
		"built %s, %.2f m against step %.2f and jump %.2f" % [
			game.arena.has_node(^"Showdown/RingDais"), ScArena.DAIS_SIZE.y,
			ScPlayer.tunables_for(config, null).step_height, config.jump_height])

	# --- Driven: from pad 0 down its catwalk, across the ring, one jump onto the top. ---
	var start := game.arena.corner_point(0, sides)
	var yaw := game.arena.showdown_yaw(0, sides)
	var runner := game.add_player(&"dais_runner", "Dais Runner", 1)
	runner.place_at(start + Vector3.UP * 0.2, yaw)
	await _step(game, 8)

	# On the catwalk's line to 12 m out, round the pad's own block (it stands on that line
	# 7.2 m out), then at the middle: the way a survivor runs it.
	var out := Vector3(start.x - middle.x, 0.0, start.z - middle.z).normalized()
	var across := Vector3(-out.z, 0.0, out.x)
	var route_points: Array[Vector3] = [
		middle + out * 12.0, middle + out * 4.5 + across * 3.0, middle,
	]
	var from := runner.controller.state.position
	var route := 0.0
	var last := from

	for point in route_points:
		route += Vector2(point.x - last.x, point.z - last.z).length()
		last = point

	route -= half

	_track(runner)
	var ticks := 0
	var next := 0
	var jumped := false
	var on_top := false
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for _i in range(int(14.0 * TICK_RATE)):
		var at := runner.controller.state.position
		var target := route_points[next]
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if next < route_points.size() - 1 and toward.length() < 1.0:
			next += 1
			target = route_points[next]
			toward = Vector3(target.x - at.x, 0.0, target.z - at.z)

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)

		# Off the ring 1.2 m short of the dais' edge, the lead a running jump wants.
		if next == route_points.size() - 1 and not jumped and toward.length() < half + 1.2:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			jumped = true

		runner.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()
		ticks += 1

		var now := runner.controller.state.position

		if jumped and runner.controller.state.mode == DotFpsState.Mode.GROUND \
				and now.y > top - 0.1 and absf(now.x - middle.x) < half \
				and absf(now.z - middle.z) < half:
			on_top = true
			break

	var covered := _covered
	var fastest := _top_speed
	_track(null)
	var seconds := float(ticks) / float(TICK_RATE)
	var ended := runner.controller.state.position
	var pace := covered / seconds if seconds > 0.0 else 0.0

	print("  ..    dais: pad 0 to the dais' top %.1f m (route %.1f) in %.2f s, %.2f m/s, top %.2f against run %.2f" % [
		covered, route, seconds, pace, fastest, max_speed])

	_check(on_top and runner.is_alive(),
		"a runner goes from pad 0 down the catwalk and jumps onto the dais",
		"ended at %.2f m over the ring, %.1f m from its middle" % [
			ended.y - middle.y, Vector2(ended.x - middle.x, ended.z - middle.z).length()])
	_check(on_top and fastest >= max_speed * 0.95 and seconds <= route / max_speed + 1.0,
		"and at a run: the route in its running time",
		"%.1f m in %.2f s (%.2f s at %.2f m/s), top %.2f" % [
			route, seconds, route / max_speed, max_speed, fastest])

	# --- Cover that turns, and the high ground. -----------------------------------------
	#
	# From every pad and every perch: somebody crouched against the dais' far side is out
	# of sight, and somebody standing there is not. A ring block covers from one pad; the
	# dais covers from whichever one a survivor puts it between.
	var space := game.arena.get_world_3d().direct_space_state
	var hidden := 0
	var under := 0
	var over := 0
	var lookers: Array[Vector3] = []

	for index in range(sides):
		lookers.append(game.arena.corner_point(index, sides))
		lookers.append(game.arena.perch_point(index, sides))

	for looker in lookers:
		var eye := looker + Vector3.UP * 1.6
		var away := Vector3(middle.x - looker.x, 0.0, middle.z - looker.z).normalized()
		var behind := middle + away * (half + 0.4)
		var crouched := Vector3(behind.x, middle.y + 0.7, behind.z)
		var standing := Vector3(behind.x, middle.y + 1.6, behind.z)
		var low := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, crouched))
		var high := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, standing))

		if not low.is_empty():
			hidden += 1

			if String((low["collider"] as Node).name) == "RingDais":
				under += 1
		if high.is_empty():
			over += 1

	print("  ..    dais: crouched against the far side, %d of %d lines blocked, %d by the dais itself (the perches'; a pad's own block is on its line first)" % [
		hidden, lookers.size(), under])

	_check(hidden == lookers.size() and under >= sides and over == lookers.size(),
		"and crouched against its far side a survivor is hidden from every pad and perch, standing is not",
		"%d of %d hidden (%d by the dais), %d of %d seen standing" % [
			hidden, lookers.size(), under, over, lookers.size()])

	var dais_eye := Vector3(middle.x, top + 1.6, middle.z)
	var seen := 0
	var asked := 0

	for index in range(sides):
		for target: Vector3 in [game.arena.corner_point(index, sides), game.arena.perch_point(index, sides)]:
			asked += 1

			if space.intersect_ray(PhysicsRayQueryParameters3D.create(dais_eye, target + Vector3.UP * 1.6)).is_empty():
				seen += 1

	_check(seen == asked,
		"and from its top every pad and every perch is in sight, over the blocks",
		"%d of %d lines clear" % [seen, asked])

	await _dispose(game)
	_finished()


func _test_the_showdown_walk() -> void:
	_section("a survivor can walk from their corner onto the ring")

	# Two sides, where every catwalk meets its edges square on, and three, where two of
	# them meet the ring at an angle and a gap cut along the edge has to be wider.
	for sides: int in [2, 3]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)

		var corner := sides - 1
		var start := game.arena.corner_point(corner, sides)
		var middle := game.arena.showdown_centre()
		var ring := game.config.corner_size * 0.85
		var walker := game.add_player(&"walker", "Walker", 1)
		var yaw := game.arena.showdown_yaw(corner, sides)
		walker.place_at(start + Vector3.UP * 0.2, yaw)

		var arrived := false
		var lowest := INF

		# Running, which is the case the kerb was stopping. Walking is stopped the same way.
		for _i in range(int(8.0 * TICK_RATE)):
			var command := DotFpsCommand.new()
			command.yaw = yaw
			command.move = Vector2(0.0, 1.0)
			walker.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()

			var at := walker.controller.state.position
			lowest = minf(lowest, at.y)

			if Vector2(at.x - middle.x, at.z - middle.z).length() < ring - 2.0:
				arrived = true
				break

		var ended := walker.controller.state.position
		_check(arrived and lowest > middle.y - 0.5,
			"with %d sides, from corner %d onto the ring" % [sides, corner],
			"%.1f m from the middle, lowest %.2f m against %.2f" % [
				Vector2(ended.x - middle.x, ended.z - middle.z).length(), lowest, middle.y])

		await _dispose(game)

	# [b]And over a kerb, at walking pace.[/b] The openings above were cut on 2026-09-23
	# because step-up refused this game's 0.34 m kerb 0.6 m deep at any speed, whatever
	# `step_height` (0.45) said. dot-player-controller 2e6d930 fixed the step; this closes
	# the pad's kerb across its catwalk again and walks over it with the brake held, so a
	# regression in the step shows up here rather than as a survivor stuck on their pad.
	# The height reached is in the detail, for the addon's [kerb-pop-1] (a fast body is
	# thrown well over the kerb).
	var closed := await _world(func(c: ScConfig) -> void:
		c.team_count = 2
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var pad := closed.arena.get_node(^"Showdown/Pad0") as StaticBody3D
	var none: Array[Vector2] = []
	closed.arena._build_kerb(pad, Vector2(closed.config.corner_size, closed.config.corner_size),
		true, none)
	await _physics_frame()

	var home := closed.arena.corner_point(0, 2)
	var facing := closed.arena.showdown_yaw(0, 2)
	var stepper := closed.add_player(&"stepper", "Stepper", 1)
	stepper.place_at(home + Vector3.UP * 0.2, facing)
	var highest := -INF
	var over := false

	for _i in range(int(8.0 * TICK_RATE)):
		var command := DotFpsCommand.new()
		command.yaw = facing
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_WALK, true)
		stepper.controller.apply_command(command)
		closed.simulate(TICK)
		await _physics_frame()

		var now := stepper.controller.state.position
		highest = maxf(highest, now.y - home.y)

		# Two metres past the pad's edge is on the catwalk.
		if Vector2(now.x - home.x, now.z - home.z).length() > closed.config.corner_size * 0.5 + 2.0:
			over = true
			break

	_check(over and stepper.is_alive() and highest < ScArena.CORNER_LIP + 0.3,
		"a survivor walks over their pad's kerb onto the catwalk",
		"over %s, highest %.2f m over the pad against a %.2f m kerb" % [
			over, highest, ScArena.CORNER_LIP])

	await _dispose(closed)
	_finished()


## [b]A catwalk stops at the ring's edge and at its pad's, and at neither short of it.[/b]
##
## Until 2026-09-29 a catwalk was a rectangle measured along its middle as if it met both
## edges square on, which with three sides ran it up to 3.2 m on into the ring, coplanar
## with it, carrying its kerbs in as stubs on the ring's floor (`tools/shot.sh
## --view=junction --sc-team-count=3`). Read off the BUILT colliders rather than off
## `ScArena.catwalk()`, and the edges found by marching rather than by its arithmetic, so a
## description that agreed with itself and not with the world would fail here. Two and four
## sides meet every edge square on; three meets two of them at an angle.
func _test_catwalks_meet_their_edges() -> void:
	_section("a catwalk meets the ring and its pad, and runs into neither")

	for sides: int in [2, 3, 4]:
		var game := await _world(func(c: ScConfig) -> void:
			c.team_count = sides
			c.cannon_enabled = false
			c.specials_enabled = false
		)
		await _physics_frame()

		var middle := game.arena.showdown_centre()
		var ring := game.arena.ring_half()
		var pad_half := game.config.corner_size * 0.5
		var space := game.arena.get_world_3d().direct_space_state
		var in_ring := PackedStringArray()
		var in_pad := PackedStringArray()
		var air := PackedStringArray()

		for index in range(sides):
			var body := game.arena.get_node(NodePath("Showdown/Catwalk%d" % index)) as StaticBody3D
			var corner := game.arena.corner_point(index, sides)
			var inside := func(p: Vector3, centre: Vector3, half: float) -> bool:
				return absf(p.x - centre.x) < half - 0.01 and absf(p.z - centre.z) < half - 0.01

			# Every point of the slab's top, sampled, and every corner of every kerb.
			var points: Array[Vector3] = []

			for piece: Node in body.get_children():
				var collider := piece as CollisionShape3D

				if collider == null:
					continue

				var to_world := body.global_transform * collider.transform
				var convex := collider.shape as ConvexPolygonShape3D
				var box := collider.shape as BoxShape3D

				if convex != null:
					var top: Array[Vector3] = []

					for i in range(4):
						top.append(to_world * convex.points[i])

					for u in range(11):
						for v in range(41):
							var a := top[0].lerp(top[1], u / 10.0)
							var b := top[3].lerp(top[2], u / 10.0)
							points.append(a.lerp(b, v / 40.0))
				elif box != null:
					var h := box.size * 0.5

					for x: float in [-h.x, h.x]:
						for z: float in [-h.z, h.z]:
							points.append(to_world * Vector3(x, -h.y, z))

			for p in points:
				if inside.call(p, middle, ring):
					in_ring.append("Catwalk%d at %.2f, %.2f" % [index, p.x - middle.x, p.z - middle.z])
					break

			for p in points:
				if inside.call(p, corner, pad_half):
					in_pad.append("Catwalk%d at %.2f, %.2f" % [index, p.x - corner.x, p.z - corner.z])
					break

			# Across the whole width, 5 cm past each edge the ground is this catwalk. The
			# edges are found by walking out along the line in centimetres.
			var out := Vector2(corner.x - middle.x, corner.z - middle.z).normalized()
			var across := Vector2(out.y, -out.x)
			var reach := Vector2(corner.x - middle.x, corner.z - middle.z).length()

			for step in range(9):
				var w := lerpf(-ScArena.CATWALK_WIDTH * 0.5 + 0.05, ScArena.CATWALK_WIDTH * 0.5 - 0.05, step / 8.0)
				var s := 0.0

				while inside.call(_on_line(middle, out, across, s, w), middle, ring + 0.01):
					s += 0.01

				var e := reach

				while inside.call(_on_line(middle, out, across, e, w), corner, pad_half + 0.01):
					e -= 0.01

				for at: float in [s + 0.05, e - 0.05]:
					var p := _on_line(middle, out, across, at, w)
					var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
						p + Vector3.UP * 1.0, p + Vector3.DOWN * 1.0))

					if hit.is_empty() or hit["collider"] != body:
						air.append("Catwalk%d at %.1f m across, %.2f m out" % [index, w, at])
						break

		_check(in_ring.is_empty(),
			"with %d sides, no catwalk or its kerb runs into the ring" % sides, ", ".join(in_ring))
		_check(in_pad.is_empty(),
			"with %d sides, nor into its own pad" % sides, ", ".join(in_pad))
		_check(air.is_empty(),
			"with %d sides, and every catwalk meets both edges with no air at the join" % sides,
			", ".join(air))

		await _dispose(game)

	_finished()


## The point [param s] metres along [param out] and [param w] across it from [param middle].
func _on_line(middle: Vector3, out: Vector2, across: Vector2, s: float, w: float) -> Vector3:
	var xz := out * s + across * w
	return Vector3(middle.x + xz.x, middle.y, middle.z + xz.y)


func _test_the_zigzag() -> void:
	_section("the chequerboard is crossed on the diagonals and only on them")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.layout_ids = PackedStringArray(["checker"])
	)
	var platforms := game.platforms

	# Through the operator's own knob, so the render and a server running it are the same
	# field this drives.
	_check(game.layout != null and game.layout.id == &"checker",
		"the round is laid out as the chequerboard",
		String(game.layout.id) if game.layout != null else "none")

	var runner := game.add_player(&"runner", "Runner", 1)
	game.add_player(&"other", "Other", 2)

	# Along the whole field: (0,0) (1,1) (2,0) (3,1) (4,0). Four jumps, each one a
	# diagonal, each from the middle of a platform that is leaning under the person on it.
	var route: Array[int] = []

	for column in range(game.config.columns):
		route.append(_deck_at_cell(platforms, column, column % 2))

	_check(not route.has(-1), "the zigzag is all there", str(route))

	var start := platforms.deck_at(route[0])
	runner.place_at(start.centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)

	var made := PackedStringArray()

	for leg in range(route.size() - 1):
		var from := route[leg]
		var to := route[leg + 1]
		await _walk_to(game, runner, platforms.deck_at(from).centre)
		var landed := await _jump_across(game, runner, from, to)
		made.append("%s%s" % [_cell_name(platforms, to), "" if landed else " MISSED"])

		if not landed:
			break

	_check(made.size() == route.size() - 1 and not ", ".join(made).contains("MISSED"),
		"a runner crosses the field on four diagonals", ", ".join(made))
	_check(runner.is_alive() and runner.standing_on == route[route.size() - 1],
		"and is standing on the far corner platform at the end",
		"on %d, alive %s" % [runner.standing_on, runner.is_alive()])
	_check(platforms.standing_count() == platforms.count(),
		"with every platform they crossed still up",
		"%d of %d" % [platforms.standing_count(), platforms.count()])

	# [b]And the straight line is a fall, which is the other half of "every jump is a
	# diagonal".[/b] From the far corner back along the row toward (2,0), jumping at the lip.
	var along := _deck_at_cell(platforms, game.config.columns - 3, 0)
	await _walk_to(game, runner, platforms.deck_at(route[route.size() - 1]).centre)
	var crossed := await _jump_across(game, runner, route[route.size() - 1], along)
	_check(not crossed and runner.controller.state.position.y < game.config.deck_height - 3.0,
		"and running straight along a row is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## The Spine's blurb: "the walkways are the steady ground". Until 2026-09-24 a bridge was a
## spring of its own pivoting on a pillar it does not have, and one runner at its end leaned
## it 9.7 degrees against 7.9 for the same runner at a platform's edge; two took it down.
## See [method ScPlatforms._rest_bridges].
func _test_the_spine() -> void:
	_section("The Spine's walkways are the steady ground")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.layout_ids = PackedStringArray(["spine"])
	)
	var platforms := game.platforms

	var bridges := 0
	var rested := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge:
			bridges += 1
			rested += 1 if deck.is_rested() else 0

	_check(bridges >= 4 and rested == bridges,
		"every bridge on The Spine rests on the two platforms it joins",
		"%d of %d" % [rested, bridges])

	# The model alone, on a field of its own: one runner's weight at a bridge's end against
	# the same at a platform's edge, each held until the spring has found its angle.
	var bridge_end := _spine_lean(true)
	var platform_edge := _spine_lean(false)
	_check(bridge_end < platform_edge * 0.5,
		"a runner at a bridge's end tilts it less than half what a platform's edge does",
		"%.1f deg against %.1f" % [rad_to_deg(bridge_end), rad_to_deg(platform_edge)])

	# Driven: running, not walking, from the middle of (0,0) over the bridge to (0,1).
	var from := _deck_at_cell(platforms, 0, 0)
	var to := _deck_at_cell(platforms, 0, 1)
	var bridge := -1

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge and deck.column == 0 and deck.row == 0:
			bridge = i

	var runner := game.add_player(&"runner", "Runner", 1)
	game.add_player(&"other", "Other", 2)
	runner.place_at(platforms.deck_at(from).centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)

	var target := platforms.deck_at(to).centre
	var span := platforms.deck_at(bridge)
	var worst_bridge := 0.0
	var worst_step := 0.0
	var lowest := INF
	var crossed_on := false
	var arrived := false

	for _i in range(int(6.0 * TICK_RATE)):
		var at := runner.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if toward.length() < 1.0:
			arrived = true
			break

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		runner.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

		lowest = minf(lowest, runner.controller.state.position.y)
		worst_bridge = maxf(worst_bridge, span.tilt())
		crossed_on = crossed_on or runner.standing_on == bridge

		# Where the bridge meets each lip there is no step, whatever the platforms are doing.
		var x := span.centre.x
		worst_step = maxf(worst_step, absf(
			platforms.surface_y(bridge, x, span.lips.x) - platforms.surface_y(from, x, span.lips.x)))
		worst_step = maxf(worst_step, absf(
			platforms.surface_y(bridge, x, span.lips.y) - platforms.surface_y(to, x, span.lips.y)))

	await _step(game, 10)

	_check(crossed_on and arrived and runner.standing_on == to and runner.is_alive(),
		"a runner crosses a bridge from one row to the other",
		"on %d, alive %s, lowest %.2f m against a deck at %.2f" % [
			runner.standing_on, runner.is_alive(), lowest, game.config.deck_height])
	# Not the runner's height: the lip they leave from dips most of a metre under a runner,
	# which is the platform doing its job. The bridge is what is being asked about.
	_check(worst_bridge < deg_to_rad(4.0),
		"and the bridge under them never tilts past four degrees",
		"%.1f deg" % rad_to_deg(worst_bridge))
	_check(worst_step < 0.02, "and meets both lips with no step",
		"%.3f m at worst" % worst_step)

	# And it goes with either platform it rests on.
	var why: Array[StringName] = []
	platforms.collapsed.connect(func(index: int, reason: StringName) -> void:
		if index == bridge:
			why.append(reason))
	var _fell := platforms.collapse(from, ScPlatforms.WHY_SHATTERED)
	await _step(game, 2)
	_check(not span.is_standing() and why.has(ScPlatforms.WHY_UNSUPPORTED),
		"and falls when a platform it rests on does", str(why))

	await _dispose(game)
	_finished()


## Two Islands' blurb: "Two islands and a lot of air between them. Nobody is crossing." Until
## 2026-09-27 it was four: the rows were 13.5 m apart with no bridge, so each end of each row
## was two platforms nobody could leave, and the two sides started on two of them.
func _test_two_islands() -> void:
	_section("Two Islands is two islands, crossed every way, and nobody crosses between them")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["islands"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"islands",
		"the round is laid out as Two Islands",
		String(game.layout.id) if game.layout != null else "none")

	# What a player can get to, off the built field: bridges, and the jumps the layout means
	# (which the reach section holds to a running jump, both ways).
	var island := ScLayouts.islands(platforms.cells(), game.layout.jumps)
	var sizes: Dictionary = {}

	for i in range(platforms.count()):
		sizes[island[i]] = int(sizes.get(island[i], 0)) + 1

	_check(sizes.size() == 2 and sizes.values().all(func(n: int) -> bool: return n == 4),
		"the field is two islands of four platforms",
		"%d islands: %s" % [sizes.size(), str(sizes.values())])

	# Two sides, one to an island. The field is in row order, and the old spread put both
	# at the two ends of the first column.
	var runner := game.add_player(&"runner", "Runner", 1)
	var other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, 20)
	var mine := platforms.index_at(runner.controller.state.position.x, runner.controller.state.position.z)
	var theirs := platforms.index_at(other.controller.state.position.x, other.controller.state.position.z)
	_check(mine >= 0 and theirs >= 0 and island[mine] != island[theirs],
		"two sides start on the two islands, one each",
		"%s and %s" % [
			_cell_name(platforms, mine) if mine >= 0 else "nowhere",
			_cell_name(platforms, theirs) if theirs >= 0 else "nowhere"])

	# Round the left island on every kind of jump it means: along a row, across the rows,
	# back along, and a diagonal. Each from the middle of a platform leaning under the
	# runner, at the lip, as a person would.
	var cells := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(1, 0)]
	var route: Array[int] = []

	for cell: Vector2i in cells:
		route.append(_deck_at_cell(platforms, cell.x, cell.y))

	var length := 0.0

	for leg in range(route.size() - 1):
		var a := platforms.deck_at(route[leg]).centre
		var b := platforms.deck_at(route[leg + 1]).centre
		length += Vector2(b.x - a.x, b.z - a.z).length()

	runner.place_at(platforms.deck_at(route[0]).centre + Vector3.UP * 0.2, 0.0)
	await _step(game, 20)
	_track(runner)

	var made := PackedStringArray()

	for leg in range(route.size() - 1):
		await _walk_to(game, runner, platforms.deck_at(route[leg]).centre)
		var landed := await _jump_across(game, runner, route[leg], route[leg + 1])
		made.append("%s%s" % [_cell_name(platforms, route[leg + 1]), "" if landed else " MISSED"])

		if not landed:
			break

	await _walk_to(game, runner, platforms.deck_at(route[route.size() - 1]).centre)
	var covered := _covered
	var top := _top_speed
	_track(null)
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	_check(made.size() == route.size() - 1 and not ", ".join(made).contains("MISSED"),
		"a runner goes round an island along, across, along and on a diagonal",
		", ".join(made))
	# [b]At a run, over the whole route[/b] ([bot-drive-1]): a bot that crawled, or that was
	# placed rather than driven, passes the landing checks and fails this one.
	_check(covered >= length * 0.95 and top >= max_speed * 0.95,
		"and covers the route at a run",
		"%.1f m covered of a %.1f m route, top speed %.2f of %.2f m/s" % [
			covered, length, top, max_speed])
	_check(runner.is_alive() and runner.standing_on == route[route.size() - 1]
			and platforms.standing_count() == platforms.count(),
		"and ends on the island, with all of it still up",
		"on %d, alive %s, %d of %d up" % [runner.standing_on, runner.is_alive(),
			platforms.standing_count(), platforms.count()])

	# And the other island is not reached: straight at it from the inner edge of this one,
	# running, is a fall. That is "nobody is crossing".
	var across := _deck_at_cell(platforms, 3, 0)
	var crossed := await _jump_across(game, runner, route[route.size() - 1], across)
	_check(not crossed and runner.controller.state.position.y < config.deck_height - 3.0,
		"and running at the other island is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## Hollow Centre's blurb: "Nothing in the middle. The cannon has to reach for you and it
## will." Until 2026-10-03 `Gaps.HOLLOW` took the middle three columns of five, so the field
## was two strips of a platform, a bridge and a platform; with only the middle column gone
## each half is a U round the hole. This runs a side round its U — a jump along a row, the
## outer bridge, a jump along the other row — and then at the other U, which is a fall.
func _test_hollow_centre() -> void:
	_section("Hollow Centre is two U's round the hole, and the hole is not crossed")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["hollow"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"hollow",
		"the round is laid out as Hollow Centre",
		String(game.layout.id) if game.layout != null else "none")

	var decks := 0
	var spans := 0
	var middle := 0

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge:
			spans += 1
		else:
			decks += 1

		if deck.column == config.columns / 2:
			middle += 1

	var island := ScLayouts.islands(platforms.cells(), game.layout.jumps)
	var sizes: Dictionary = {}

	for i in range(platforms.count()):
		sizes[island[i]] = int(sizes.get(island[i], 0)) + 1

	_check(decks == 8 and spans == 2 and middle == 0
			and sizes.size() == 2 and sizes.values().all(func(n: int) -> bool: return n == 5),
		"only the middle column is gone: two halves of four platforms and a bridge",
		"%d platforms, %d bridges, %d in the middle column, %d islands: %s" % [
			decks, spans, middle, sizes.size(), str(sizes.values())])

	var runner := game.add_player(&"runner", "Runner", 1)
	var other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, 20)
	var mine := platforms.index_at(runner.controller.state.position.x, runner.controller.state.position.z)
	var theirs := platforms.index_at(other.controller.state.position.x, other.controller.state.position.z)
	_check(mine >= 0 and theirs >= 0 and island[mine] != island[theirs],
		"two sides start on the two halves, one each",
		"%s and %s" % [
			_cell_name(platforms, mine) if mine >= 0 else "nowhere",
			_cell_name(platforms, theirs) if theirs >= 0 else "nowhere"])

	# Round the left U: off the inner platform onto the outer one, across the outer bridge
	# at a run, and out to the other row's inner platform. Every jump from the middle of a
	# platform leaning under the runner, at the lip.
	var inner_near := _deck_at_cell(platforms, 1, 0)
	var outer_near := _deck_at_cell(platforms, 0, 0)
	var outer_far := _deck_at_cell(platforms, 0, 1)
	var inner_far := _deck_at_cell(platforms, 1, 1)
	var made := PackedStringArray()
	var length := 0.0

	if inner_near < 0 or outer_near < 0 or outer_far < 0 or inner_far < 0:
		made.append("no U: (1,0) %d, (0,0) %d, (0,1) %d, (1,1) %d MISSED" % [
			inner_near, outer_near, outer_far, inner_far])
	else:
		var stops := [inner_near, outer_near, outer_far, inner_far]

		for leg in range(stops.size() - 1):
			var a := platforms.deck_at(stops[leg]).centre
			var b := platforms.deck_at(stops[leg + 1]).centre
			length += Vector2(b.x - a.x, b.z - a.z).length()

		runner.place_at(platforms.deck_at(inner_near).centre + Vector3.UP * 0.2, 0.0)
		await _step(game, 20)
		_track(runner)

		await _walk_to(game, runner, platforms.deck_at(inner_near).centre)
		var landed := await _jump_across(game, runner, inner_near, outer_near)
		made.append("%s%s" % [_cell_name(platforms, outer_near), "" if landed else " MISSED"])

		if landed:
			# Over the bridge on foot, at a run: it is walked, not jumped.
			await _run_to(game, runner, platforms.deck_at(outer_far).centre, 0.3)
			await _walk_to(game, runner, platforms.deck_at(outer_far).centre)
			var crossed := runner.is_alive() and runner.standing_on == outer_far
			made.append("%s over the bridge%s" % [_cell_name(platforms, outer_far),
				"" if crossed else " MISSED"])

			if crossed:
				await _walk_to(game, runner, platforms.deck_at(outer_far).centre)
				landed = await _jump_across(game, runner, outer_far, inner_far)
				made.append("%s%s" % [_cell_name(platforms, inner_far), "" if landed else " MISSED"])

				if landed:
					await _walk_to(game, runner, platforms.deck_at(inner_far).centre)

	var covered := _covered
	var top := _top_speed
	_track(null)
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	_check(made.size() == 3 and not ", ".join(made).contains("MISSED"),
		"a runner goes round a U: a jump along a row, the outer bridge, a jump back in",
		", ".join(made))
	_check(length > 0.0 and covered >= length * 0.95 and top >= max_speed * 0.95,
		"and covers the route at a run",
		"%.1f m covered of a %.1f m route, top speed %.2f of %.2f m/s" % [
			covered, length, top, max_speed])
	_check(inner_far >= 0 and runner.is_alive() and runner.standing_on == inner_far
			and platforms.standing_count() == platforms.count(),
		"and ends on the far inner platform, with all of it still up",
		"on %d, alive %s, %d of %d up" % [runner.standing_on, runner.is_alive(),
			platforms.standing_count(), platforms.count()])

	# And the other U is not reached: straight across the hole from the inner platform,
	# running, is a fall.
	var across := _deck_at_cell(platforms, config.columns - 2, 1)
	var fell := false

	if inner_far >= 0 and across >= 0 and runner.standing_on == inner_far:
		var reached := await _jump_across(game, runner, inner_far, across)
		fell = not reached and runner.controller.state.position.y < config.deck_height - 3.0

	_check(fell, "and running across the hole at the other half is a fall",
		"%.1f m" % runner.controller.state.position.y)

	await _dispose(game)
	_finished()


## Broadside's blurb: "Pushed apart, half the bridges, and a chopper over the middle of it."
## Until 2026-09-30 the chopper was on the Airfield's pad, a third of the way out on a 45
## degree line — (3,1) here, two jumps from the second side's start and four jumps and a
## bridge from the first's. It is parked on the middle column now, and this runs both sides
## to it at the layout's own 3.4 m jumps (which the reach section only measured) and puts
## each of them in it.
func _test_broadside() -> void:
	_section("Broadside's chopper is over the middle, and either side can run to it and take it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["broadside"])
	)
	var platforms := game.platforms
	var config := game.config

	_check(game.layout != null and game.layout.id == &"broadside",
		"the round is laid out as Broadside",
		String(game.layout.id) if game.layout != null else "none")

	var first := game.add_player(&"first", "First", 1)
	var second := game.add_player(&"second", "Second", 2)
	game.start()
	# Long enough for the chopper to drop off its pad and come to rest.
	await _step(game, 96)

	var copter: DotVehicleInstance = null if game._copter_ids.is_empty() \
		else game.vehicles.get_vehicle(game._copter_ids[0])
	var parked := copter.body().global_position if copter != null else Vector3.ZERO
	var middle := _deck_at_cell(platforms, config.columns / 2, 0)
	var under := platforms.index_at(parked.x, parked.z) if copter != null else -1

	_check(copter != null and under == middle and absf(parked.x) < 0.5
			and parked.y < config.deck_height + 2.0,
		"the chopper comes to rest on the middle column, over the field's centre line",
		"on %s at x %.2f, %.2f m over the decks" % [
			_cell_name(platforms, under) if under >= 0 else "nothing", parked.x,
			parked.y - config.deck_height])

	# Where the two sides were dealt, which the routes below start from.
	var home := _deck_at_cell(platforms, 0, 0)
	var across := _deck_at_cell(platforms, 1, 1)
	var first_on := platforms.index_at(first.controller.state.position.x,
		first.controller.state.position.z)
	var second_on := platforms.index_at(second.controller.state.position.x,
		second.controller.state.position.z)
	_check(first_on == home and second_on == across,
		"the two sides start at (0,0) and (1,1), a row apart",
		"%s and %s" % [
			_cell_name(platforms, first_on) if first_on >= 0 else "nowhere",
			_cell_name(platforms, second_on) if second_on >= 0 else "nowhere"])

	# The first side: two jumps along its own row. The second: over column 1's bridge to the
	# first row, and one jump. Each then goes to the machine and gets in, and out again.
	var near := _deck_at_cell(platforms, 1, 0)
	var runs := [
		[first, [[home, near, false], [near, middle, false]]],
		[second, [[across, near, true], [near, middle, false]]],
	]
	var metres: Array[float] = []
	var fastest := INF
	var took := PackedStringArray()
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for run: Array in runs:
		var runner: ScPlayer = run[0]
		var made := PackedStringArray()
		_track(runner)

		for leg: Array in run[1]:
			var landed := false

			if leg[2]:
				landed = await _run_to(game, runner, platforms.deck_at(leg[1]).centre, 1.0)
				landed = landed and runner.standing_on == leg[1]
			else:
				await _walk_to(game, runner, platforms.deck_at(leg[0]).centre)
				landed = await _jump_across(game, runner, leg[0], leg[1])

			made.append("%s%s" % [_cell_name(platforms, leg[1]), "" if landed else " MISSED"])

			if not landed:
				break

		# Guarded, because a runner who fell ended the round and took the machine with it.
		if copter != null and copter.body() != null:
			await _run_to(game, runner, copter.body().global_position, 3.5)

		var boarded := game.try_board(runner.player_id)
		await _step(game, 4)
		metres.append(_covered)
		fastest = minf(fastest, _top_speed)
		_track(null)
		took.append("%s: %s, %.1f m, %s" % [runner.player_id, ", ".join(made), metres.back(),
			"in" if boarded.ok and runner.riding else "not in"])

		# Out again, so the other side finds it empty.
		if runner.riding:
			var _out := game.try_board(runner.player_id)
			await _step(game, 20)

		_check(boarded.ok and not ", ".join(made).contains("MISSED"),
			"%s runs to the chopper and gets in" % runner.player_id, took[took.size() - 1])

	_check(fastest >= max_speed * 0.95, "both at a run, over the 3.4 m jumps",
		"slower top speed %.2f of %.2f m/s" % [fastest, max_speed])
	# Over the middle is what makes it contested: neither side has it on the doorstep.
	var ratio: float = float(metres.max()) / maxf(float(metres.min()), 0.01)
	_check(metres.size() == 2 and ratio <= 1.5,
		"and neither side is much nearer it than the other",
		"%.1f m against %.1f m, %.2f to one" % [metres[0], metres[1], ratio])

	var now := copter.body().global_position if copter != null and copter.body() != null \
		else Vector3(INF, INF, INF)
	_check(now.distance_to(parked) < 0.5 and platforms.standing_count() == platforms.count()
			and first.is_alive() and second.is_alive(),
		"and it is where it was after both have landed beside it, with everybody up",
		"moved %.2f m, %d of %d platforms up, alive %s and %s" % [now.distance_to(parked),
			platforms.standing_count(), platforms.count(), first.is_alive(), second.is_alive()])

	await _dispose(game)
	_finished()


func _test_the_airfield() -> void:
	_section("the Airfield's pad is the far bridge, and both sides run their own row to it")

	var game := await _world(func(c: ScConfig) -> void:
		c.cannon_enabled = false
		c.specials_enabled = false
		c.chopper_enabled = true
		c.survival_seconds = 600.0
		c.layout_ids = PackedStringArray(["airfield"])
	)
	var platforms := game.platforms
	var config := game.config
	var last := config.columns - 1

	_check(game.layout != null and game.layout.id == &"airfield",
		"the round is laid out as the Airfield",
		String(game.layout.id) if game.layout != null else "none")

	var first := game.add_player(&"first", "First", 1)
	var second := game.add_player(&"second", "Second", 2)
	game.start()
	# Long enough for the chopper to drop off its pad and come to rest.
	await _step(game, 96)

	var copter: DotVehicleInstance = null if game._copter_ids.is_empty() \
		else game.vehicles.get_vehicle(game._copter_ids[0])
	var parked := copter.body().global_position if copter != null else Vector3.ZERO
	var pad := -1

	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if deck.is_bridge and deck.column == last and deck.row == 0:
			pad = i

	var under := platforms.index_at(parked.x, parked.z) if copter != null else -1
	var pad_centre := platforms.deck_at(pad).centre if pad >= 0 else Vector3(INF, 0.0, INF)

	_check(copter != null and pad >= 0 and under == pad
			and Vector2(parked.x - pad_centre.x, parked.z - pad_centre.z).length() < 1.0
			and parked.y < config.deck_height + 2.5,
		"the chopper comes to rest on the middle of the last column's bridge",
		"on %s, %.2f m off its middle, %.2f m over the decks" % [
			_cell_name(platforms, under) if under >= 0 else "nothing",
			Vector2(parked.x - pad_centre.x, parked.z - pad_centre.z).length(),
			parked.y - config.deck_height])

	var home := _deck_at_cell(platforms, 0, 0)
	var across := _deck_at_cell(platforms, 1, 1)
	var first_on := platforms.index_at(first.controller.state.position.x,
		first.controller.state.position.z)
	var second_on := platforms.index_at(second.controller.state.position.x,
		second.controller.state.position.z)
	_check(first_on == home and second_on == across,
		"the two sides start at (0,0) and (1,1), a row apart",
		"%s and %s" % [
			_cell_name(platforms, first_on) if first_on >= 0 else "nowhere",
			_cell_name(platforms, second_on) if second_on >= 0 else "nowhere"])

	# Each side along its own row to the platform the pad rests on, jump by jump, then onto
	# the bridge and into the machine, and out again for the other.
	var routes := []

	for run: Array in [[first, 0, 0], [second, 1, 1]]:
		var legs := []

		for column in range(int(run[1]), last):
			legs.append([_deck_at_cell(platforms, column, run[2]),
				_deck_at_cell(platforms, column + 1, run[2])])

		routes.append([run[0], legs])

	var metres: Array[float] = []
	var jumps: Array[int] = []
	var fastest := INF
	var took := PackedStringArray()
	var max_speed := ScPlayer.tunables_for(config, null).max_speed

	for route: Array in routes:
		var runner: ScPlayer = route[0]
		var made := PackedStringArray()
		_track(runner)

		for leg: Array in route[1]:
			await _walk_to(game, runner, platforms.deck_at(leg[0]).centre)
			var landed := await _jump_across(game, runner, leg[0], leg[1])
			made.append("%s%s" % [_cell_name(platforms, leg[1]), "" if landed else " MISSED"])

			if not landed:
				break

		var on_pad := false

		if copter != null and copter.body() != null and not ", ".join(made).contains("MISSED"):
			await _run_to(game, runner, copter.body().global_position, 3.5)
			on_pad = runner.standing_on == pad

		var boarded := game.try_board(runner.player_id)
		await _step(game, 4)
		metres.append(_covered)
		jumps.append(made.size())
		fastest = minf(fastest, _top_speed)
		_track(null)
		took.append("%s: %s, %.1f m, %s" % [runner.player_id, ", ".join(made), metres.back(),
			"in" if boarded.ok and runner.riding else "not in"])

		if runner.riding:
			var _out := game.try_board(runner.player_id)
			await _step(game, 20)

		_check(boarded.ok and on_pad and not ", ".join(made).contains("MISSED"),
			"%s runs its own row onto the bridge and gets in" % runner.player_id,
			took[took.size() - 1])

	_check(jumps.size() == 2 and jumps[0] == last and jumps[1] == last - 1 and fastest >= max_speed * 0.95,
		"four jumps and three, at a run",
		"%s jumps, slower top speed %.2f of %.2f m/s" % [str(jumps), fastest, max_speed])
	# The far bridge is what makes it contested: each side has a row of its own to it.
	var ratio: float = float(metres.max()) / maxf(float(metres.min()), 0.01)
	_check(metres.size() == 2 and ratio <= 1.5,
		"and neither side is much nearer it than the other",
		"%.1f m against %.1f m, %.2f to one" % [metres[0], metres[1], ratio])

	var now := copter.body().global_position if copter != null and copter.body() != null \
		else Vector3(INF, INF, INF)
	_check(now.distance_to(parked) < 0.5 and platforms.standing_count() == platforms.count()
			and first.is_alive() and second.is_alive(),
		"and it is where it was after both have boarded it, with everybody up",
		"moved %.2f m, %d of %d platforms up, alive %s and %s" % [now.distance_to(parked),
			platforms.standing_count(), platforms.count(), first.is_alive(), second.is_alive()])

	# The pad goes with the platform it rests on: (last, 1) down, the bridge and the machine
	# on it go with it.
	# Both sides back home first, so nobody falls with it and the round goes on.
	first.place_at(platforms.deck_at(home).centre + Vector3.UP * 1.2, 0.0)
	second.place_at(platforms.deck_at(across).centre + Vector3.UP * 1.2, 0.0)
	await _step(game, 4)
	var lip := _deck_at_cell(platforms, last, 1)
	var _down := platforms.collapse(lip, &"test")
	await _step(game, 150)
	# Gone from the world counts: a machine that reached the floor may have been taken away.
	var after := copter.body().global_position.y \
		if copter != null and is_instance_valid(copter.body()) else -INF
	_check(not platforms.deck_at(pad).is_standing() and after < parked.y - 5.0,
		"and when a platform under the pad goes, the pad and the chopper go with it",
		"bridge standing %s, chopper %.1f m lower" % [platforms.deck_at(pad).is_standing(),
			parked.y - after])

	await _dispose(game)
	_finished()


## Runs straight at [param target] until within [param stop] metres of it, or six seconds.
##
## And lets go of the key when it gets there: the motor repeats the last command it was
## handed, so a runner nobody stops keeps running — off the far side of the platform.
func _run_to(game: ScGame, player: ScPlayer, target: Vector3, stop: float) -> bool:
	for _i in range(int(6.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if toward.length() < stop:
			var still := DotFpsCommand.new()
			still.yaw = player.controller.state.yaw
			player.controller.apply_command(still)
			return true

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	return false


## The equilibrium lean one runner's weight at a bridge's end, or at a platform's edge, puts
## on it, on The Spine's own field.
func _spine_lean(on_bridge: bool) -> float:
	var config := ScConfig.new()
	var platforms := ScPlatforms.new()
	platforms.config = config
	add_child(platforms)
	platforms.build(ScLayouts.by_id(config, &"spine"))

	var index := -1

	for i in range(platforms.count()):
		if platforms.deck_at(i).is_bridge == on_bridge:
			index = i
			break

	var deck := platforms.deck_at(index)
	var half := platforms._footprint(deck)
	var at := deck.centre + (Vector3(0.0, 0.0, half.y * 0.9) if on_bridge \
		else Vector3(half.x * 0.9, 0.0, 0.0))
	var worst := 0.0

	for _i in range(8 * TICK_RATE):
		platforms.begin_loads()
		platforms.add_load(index, at, config.player_mass, config.run_speed)
		platforms.step(TICK)
		worst = maxf(worst, deck.tilt())

	remove_child(platforms)
	platforms.free()
	return worst


## [b]The slide angle is the design, and slopes being walkable must not have moved it.[/b]
## dot-player-controller made a slope under `max_slope_angle` walkable on 2026-09-24; this
## game's is 14 degrees against a collapse at 16, so a player is meant to hold a platform
## leaning 13.5 (and walk up it), and to be thrown off one leaning 15.
func _test_a_slope_holds() -> void:
	_section("a leaning platform holds a player below the slide angle, and not above it")

	var drift := {}

	for degrees: float in [13.5, 15.0]:
		for uphill: bool in [false, true]:
			var game := await _world(func(c: ScConfig) -> void:
				c.cannon_enabled = false
				c.specials_enabled = false
				c.layout_ids = PackedStringArray(["full"])
			)
			var platforms := game.platforms
			# Held at an angle rather than leant on: the model would move it under them.
			platforms.authoritative = false
			var lean := Vector2(deg_to_rad(degrees), 0.0)
			var deck := platforms.deck_at(0)
			platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)

			var player := game.add_player(&"stander", "Stander", 1)
			var start := deck.centre + Vector3(2.0, 0.0, 0.0)
			start.y = platforms.surface_y(0, start.x, start.z) + 0.05
			player.place_at(start, 90.0)

			# Settled first, as somebody already standing there when it tipped.
			for _i in range(40):
				platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)
				game.simulate(TICK)
				await _physics_frame()

			var x := player.controller.state.position.x

			for _i in range(TICK_RATE):
				platforms.adopt(0, lean, 0.0, ScPlatforms.State.STANDING)
				var command := DotFpsCommand.new()
				command.yaw = 90.0  # toward -X, up the lean
				command.move = Vector2(0.0, 1.0) if uphill else Vector2.ZERO
				command.set_button(DotFpsCommand.BUTTON_WALK, uphill)
				player.controller.apply_command(command)
				game.simulate(TICK)
				await _physics_frame()

			drift["%.1f %s" % [degrees, "up" if uphill else "idle"]] = \
				player.controller.state.position.x - x
			await _dispose(game)

	# +X is downhill.
	_check(absf(drift["13.5 idle"]) < 0.1, "a player stands still on a platform at 13.5 degrees",
		"%.2f m" % drift["13.5 idle"])
	_check(drift["13.5 up"] < -1.5, "and walks up it",
		"%.2f m in a second" % drift["13.5 up"])
	# Only standing still is asserted at 15. Pressing uphill there is dot-player-controller's
	# steep-surface air control, which holds a body against a slope the way it holds a surfer
	# on a ramp — so a player who keeps pushing climbs a platform past its slide angle. It is
	# in the detail and in the Queue rather than asserted, because it is the addon's.
	_check(drift["15.0 idle"] > 0.5,
		"and at 15 a player standing still slides down it",
		"%.2f m in a second; pushing uphill instead, %.2f m" % [
			drift["15.0 idle"], drift["15.0 up"]])
	_finished()


func _deck_at_cell(platforms: ScPlatforms, column: int, row: int) -> int:
	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if not deck.is_bridge and deck.column == column and deck.row == row:
			return i

	return -1


## Walks, with the brake held, to a point on whatever the player is standing on, and stops.
func _walk_to(game: ScGame, player: ScPlayer, target: Vector3) -> void:
	for _i in range(int(6.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)
		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw

		if toward.length() < 0.4:
			player.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()
			break

		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_WALK, true)
		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	# Let them and the platform settle, the way a person would before committing.
	await _step(game, 40)


## Runs at platform [param to] and jumps at the lip of [param from]. True if they land on it.
func _jump_across(game: ScGame, player: ScPlayer, from: int, to: int) -> bool:
	var platforms := game.platforms
	var target := platforms.deck_at(to).centre
	var jumped := false

	for _i in range(int(4.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)

		# Off the last of the lip rather than past it. A capsule is half a metre across and a
		# deck leaning away under a runner stops holding them up a little before its edge.
		if not jumped and platforms.index_at(at.x, at.z) == from:
			var ahead := at + toward.normalized() * 0.6

			if platforms.index_at(ahead.x, ahead.z) != from:
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)
				jumped = true

		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

		if jumped and player.standing_on == to \
				and player.controller.state.mode == DotFpsState.Mode.GROUND:
			return true

		if player.controller.state.position.y < game.config.deck_height - 3.0:
			return false

	return false


func _test_delivery() -> void:
	_section("a delivered pack's own paths still resolve")

	# The seventh form of the family's delivery bug, and the one that cost a boot. A
	# publisher REWRITES every `res://` string inside a `.tscn` onto the mount prefix, so an
	# exported `model_path` arrives at runtime already absolute — and rebasing it a second
	# time produced `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/assets/...`,
	# which does not load and is long enough that the doubling is easy to read past.
	#
	# Armed: reverted to the unconditional `root().path_join(...)` this fails, and the two
	# below it pass — which is what makes it worth having as its own check.
	# [b]Against a root given rather than the one this build has.[/b] Built in, `root()` is
	# `res://` and every `res://` path is already under it — so `rebase` is the identity here
	# however it is written, and asserting its behaviour against the real root passes with
	# the bug put back. That is measured: it did. [method ScPaths.rebase_onto] is the same
	# function taking the prefix, and this is the only way the mounted case is reachable
	# from a build.
	const MOUNT := "res://dot_cloud/tmc/smash/0.1.0"

	var once := ScPaths.rebase_onto("res://assets/kenney/car/debris-tire.glb", MOUNT)
	_check(
		once == MOUNT + "/assets/kenney/car/debris-tire.glb",
		"a path a script wrote is moved onto the mount",
		once
	)
	_check(
		ScPaths.rebase_onto(once, MOUNT) == once,
		"and one the publisher already rewrote is left alone"
	)

	_check(
		ScPaths.rebase("res://props/sc_crate.tscn") == ScPaths.root().path_join("props/sc_crate.tscn"),
		"and the real root is what rebase uses"
	)

	_check(
		ScPaths.rebase("user://recording.dat") == "user://recording.dat",
		"a path that is not res:// comes back untouched"
	)

	_check(
		ScPaths.rebase("res://textures/%s.png") % "deck" == ScPaths.rebase("res://textures/deck.png"),
		"a format specifier survives being rebased"
	)

	# Form one: a `class_name` in a game repository is a global the HOST does not register,
	# so a delivered pack mounts with every script in it dead and nothing reporting it. The
	# deploy tool refuses one; this says so here as well, because the deploy tool is not what
	# somebody adding a file runs.
	var declared := PackedStringArray()

	for path: String in _scripts_here():
		var text := FileAccess.get_file_as_string(path)

		for line: String in text.split("\n"):
			if line.begins_with("class_name "):
				declared.append(path)
				break

	_check(declared.is_empty(), "no script in this game declares a class_name", ", ".join(declared))

	# Form four: the pack carries what it references. Every model and atlas named in a prop
	# scene has to exist, because a missing one is a prop that spawns, falls, lands and
	# damages a platform while being invisible — which is what game-buses-from-hell shipped.
	var missing := PackedStringArray()
	var referenced := 0

	for path: String in _prop_scenes():
		var text := FileAccess.get_file_as_string(path)

		for line: String in text.split("\n"):
			if not (line.begins_with("model_path") or line.begins_with("atlas_path")):
				continue

			var quoted := line.get_slice("\"", 1)

			if quoted == "":
				continue

			referenced += 1

			if not ResourceLoader.exists(quoted) and not FileAccess.file_exists(quoted):
				missing.append(quoted)

	_check(referenced > 0, "the prop scenes name their art by path", "%d references" % referenced)
	_check(missing.is_empty(), "every model and atlas a prop scene names is in this repository", ", ".join(missing))

	# Form three: a script naming this game's own file by a bare `"res://…"` resolves it
	# against the HOST's root once mounted. Every such path is rebased where it is defined
	# (`static var X := ScPaths.rebase("res://…")`), because a `const` rebased at each use
	# is one new use away from a prop that silently does not spawn in a delivered round.
	# Armed: with `sc_content.gd`'s CRATE_SCENE put back to a bare `const`, this fails and
	# names the line.
	var bare := _bare_own_paths()
	_check(
		_scripts_here().size() > 0 and bare.is_empty(),
		"no shipped script names this game's own file by a bare res:// path",
		", ".join(bare)
	)

	_finished()


func _test_zee_art_root() -> void:
	_section("the client points zee's art at this game, and gives it back")

	# zee-dot-weapons names its art `res://assets/…`, which in a delivered pack is the host's
	# root and holds nothing: every gun and the arms load invisible. The client sets
	# `ZeeModelCache`'s asset root to `ScPaths.root()` when it boots and puts `res://` back when
	# it goes. Built in, both are `res://`, so the root is first set to somewhere else and the
	# client has to move it. Armed: without the `_ready` line the first check fails, without
	# `_exit_tree` the second.
	const ELSEWHERE := "res://elsewhere/"
	const ART := "res://assets/blaster-kit/blaster-a.glb"

	ZeeModelCache.set_asset_root(ELSEWHERE)

	var client: Node = ScClient.new()
	client.force_offline = true
	client.offline_bots = 0
	client.config_file = "user://cfg/headless-none.json"
	add_child(client)
	# The field used to be drawn, and steered, while it was still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 3:
		await get_tree().process_frame
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	_check(
		ZeeModelCache.resolve(ART) == ScPaths.rebase(ART),
		"a booted client resolves zee's art under this game's root",
		ZeeModelCache.resolve(ART)
	)

	# And the settings: Escape used to let go of the mouse and offer nothing to click. The
	# document is built, the sampler and the camera read it, and Escape opens the screen.
	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and bool(settings.describe().get("look_bound", 0)) \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its sampler and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)

	# [b]The sensitivity survives a respawn.[/b] `ScPlayer.retune` (every respawn, every
	# special) hands the sampler a fresh tunables object at DotFpsTunables' default, and the
	# settings stayed bound to the old one: offline, the first respawn put the view back to
	# 0.25 degrees per count whatever the slider said. Armed: without `_follow_look` both fail.
	var me: ScPlayer = client.get("player")
	if me != null:
		me.retune(me.active)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var per_count := DotMenuApplier.DEGREES_PER_COUNT
	var look_after: DotFpsTunables = me.sampler.tunables if me != null and me.sampler != null else null
	_check(
		look_after != null and settings != null and is_equal_approx(look_after.mouse_sensitivity,
			settings.settings.get_float(&"sensitivity") * per_count),
		"a respawn's fresh tunables still turn at the player's sensitivity",
		"%.4f" % (look_after.mouse_sensitivity if look_after != null else -1.0)
	)
	# Read off the applier rather than by moving the slider: this client is on the player's
	# real settings document, and `sensitivity` is ACCOUNT scope, shared by every game.
	_check(
		look_after != null and settings != null and settings.applier._look.has(look_after),
		"and the slider is bound to them, so moving it after a respawn still turns the view"
	)

	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()

	# The Tab board, held: the menu's, drawn from the local world offline.
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	settings.menu.handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().size() >= 1
		and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player on it and picked out",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	settings.menu.handle_event(tab)
	_check(board != null and not board.is_open() and not settings.is_open(), "and letting go puts it away")

	ZeeModelCache.set_asset_root(ELSEWHERE)
	remove_child(client)
	client.free()

	_check(
		ZeeModelCache.resolve(ART) == ART,
		"a client leaving puts zee's art back at res://",
		ZeeModelCache.resolve(ART)
	)

	ZeeModelCache.set_asset_root("res://")
	_finished()


## Every script this game owns. Not `addons/`, which is somebody else's rules.
func _scripts_here() -> PackedStringArray:
	var found := PackedStringArray()

	for directory: String in ["res://game", "res://game/net", "res://props", "res://examples", "res://tools"]:
		for file: String in DirAccess.get_files_at(directory):
			if file.ends_with(".gd"):
				found.append(directory.path_join(file))

	return found


func _prop_scenes() -> PackedStringArray:
	var found := PackedStringArray()

	for file: String in DirAccess.get_files_at("res://props"):
		if file.ends_with(".tscn"):
			found.append("res://props".path_join(file))

	return found


# --- The harness ------------------------------------------------------------

## A watched melee swing is the kit's swing on the right arm, not a pistol's kick: the arm
## leaves the hold pose for the clip's length and comes back to it.
func _test_a_swing_is_drawn() -> void:
	_section("a watched melee swing is drawn as a swing")
	var figure := ScFigure.new()
	add_child(figure)
	figure.build(1.8, str(ScFigure.ATLASES[0]), Color.WHITE)
	figure.hold(&"knife", false)
	# The person's arms are bones: how far both upper arms are turned from where they were.
	var bones: Skeleton3D = figure.person.skeleton() if figure.person != null else null
	var arms: Array[int] = []
	if bones != null:
		arms = [bones.find_bone("UpperArm.L"), bones.find_bone("UpperArm.R")]
	figure.pose(Vector3.ZERO, 0.0, 0.0)
	await get_tree().process_frame
	figure.pose(Vector3.ZERO, 0.0, 0.0)
	var held_at: Array[Quaternion] = []
	for b in arms:
		held_at.append(bones.get_bone_pose_rotation(b))
	var turned := func() -> float:
		var most := 0.0
		for i in arms.size():
			most = maxf(most, bones.get_bone_pose_rotation(arms[i]).angle_to(held_at[i]))
		return most

	figure.fired(1, ZeeWeaponNet.KIND_SWING)
	var furthest := 0.0
	for i in 40:
		await get_tree().process_frame
		figure.pose(Vector3.ZERO, 0.0, 0.0)
		furthest = maxf(furthest, turned.call() if bones != null else 0.0)
	_check(furthest > 0.5, "the arm swings away from the hold", "%.2f rad at most" % furthest)

	for i in 60:
		await get_tree().process_frame
		figure.pose(Vector3.ZERO, 0.0, 0.0)
	_check(bones != null and turned.call() < 0.3 and not bool(figure.describe()["swinging"]),
		"and comes back to it when the swing is over")
	figure.queue_free()
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := ScSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Smash Copter",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	_check(keys.row_for_setting(&"bind_weapon_previous").get("action", &"") == &"dot_menu_weapon_previous"
		and keys.row_for_setting(&"bind_weapon_next").get("action", &"") == &"dot_menu_weapon_next"
		and keys.row_for_setting(&"bind_weapon_previous").get("default", "") == "Wheel up"
		and keys.row_for_setting(&"bind_weapon_next").get("default", "") == "Wheel down",
		"the wheel is previous and next weapon")
	var wheel_on_jump := keys.rows.filter(func(r: Dictionary) -> bool:
		return r["action"] == &"dot_fps_jump" and str(r["default"]).begins_with("Wheel"))
	_check(wheel_on_jump.is_empty(), "and the wheel is not on jump")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every
## model the weapons table names must be here. Sync it with zee-dot-weapons' tools/sync-art.sh.
func _test_the_weapon_art_is_vendored() -> void:
	_section("every model the weapon art table names is vendored in this game")
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_finished()


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## What an administrator's blind and beacon DRAW, which neither the net suite nor the
## dedicated one can reach: they assert the flags, and this asserts what a client does with
## them. Whether it looks right is `tools/shot.sh --view=beacon` and `--view=blind`.
##
## A headless viewport is 64 x 64, so "covers the viewport" is a weak claim here — but a
## blind the size of nothing, or of a HUD inset by a margin, is still caught, and the check
## was armed with the overlay anchored top-left at no size.
func _test_blind_and_beacon_drawn() -> void:
	_section("an admin's blind and beacon, drawn")

	var game := await _world()
	var me := game.add_player(&"me", "Me", 1)
	var them := game.add_player(&"them", "Them", 2)

	var hud := ScHud.new()
	add_child(hud)
	hud.bind(game, me)

	me.blinded = true
	for _i in range(30):
		hud.present_blind(1.0 / 60.0)
	_check(
		is_equal_approx(hud.blind_overlay.modulate.a, 1.0) and hud.blind_overlay.visible,
		"a blind fades the screen fully black within half a second",
		"%.2f" % hud.blind_overlay.modulate.a
	)
	var screen := hud.get_viewport().get_visible_rect()
	var covered := hud.blind_overlay.get_global_rect()
	_check(
		covered.encloses(screen) and covered.get_area() > 0.0,
		"and covers the whole viewport, not a HUD-sized part of it",
		"%s over %s" % [covered, screen]
	)
	_check(
		hud.blind_overlay.get_index() == 0,
		"under every number the HUD draws, which still say the round is going on"
	)

	# The chat box's full log against the health number, both bottom-anchored, so the
	# arithmetic holds at any height: eight rows once drew over the "100".
	var chat := ScClient.new_chat()
	add_child(chat)
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var vitals: DotVitals = hud.vitals
	var plate_bottom := -(vitals.offset_top + vitals.footprint().end.y)
	_check(
		plate_bottom >= log_top,
		"a full chat log stays under the health plate",
		"log reaches %.0f px off the bottom, the plate ends %.0f off it" % [log_top, plate_bottom]
	)
	chat.queue_free()

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var settings := ScSettings.new()
	add_child(settings)
	var _built: Variant = settings.setup(DotSettingsStoreMemory.new())
	hud.follow_menu(settings.menu)
	var plate := hud.vitals.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7, "the HUD is dark by default, in the menu's theme", str(plate))
	var _t := settings.settings.set_value(&"ui_theme", &"contrast")
	var contrast: DotMenuPalette = settings.menu.palette()
	_check(contrast.id == &"contrast" and hud.vitals.colour(&"plate") == contrast.hud_plate and hud.vitals.colour(&"text") == contrast.hud_text,
		"a theme picked in the menu reaches the pieces at once")
	_check(hud.vitals.colour(&"highlight") == Color(0.98, 0.86, 0.40) and hud._field.get_theme_color(&"font_color") == contrast.hud_text,
		"keeping this game's accent, and the HUD's own lines follow it too")
	_t = settings.settings.set_value(&"ui_theme", &"midnight")
	settings.queue_free()

	# Health and the clock are dot-ui's glance pieces, handed this world's numbers.
	me.health.health = 17.4
	hud._process(0.0)
	_check(
		vitals.number_text() == "18" and vitals.is_low(),
		"the HUD hands health to DotVitals, red at a quarter",
		"%s low=%s" % [vitals.number_text(), str(vitals.is_low())]
	)
	_check(
		hud.strip.under_text() == hud._phase_line()
		and hud.strip.clock == (
			DotScoreStrip.clock_text(game.seconds_left())
			if game.phase != ScGame.Phase.IDLE and game.sides_are_playable() else ""
		),
		"and the clock and the phase line to DotScoreStrip",
		"%s / %s" % [hud.strip.clock, hud.strip.under_text()]
	)
	me.health.health = me.health.max_health

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)

	me.blinded = false
	for _i in range(30):
		hud.present_blind(1.0 / 60.0)
	_check(not hud.blind_overlay.visible, "and lifts when the flag does")

	# The beacon, as the client presents it: once a frame at sixty frames a second for 2.9
	# seconds — short of three, because sixty sixtieths summed in floats land ON a period
	# boundary and the fourth ping would be a question about rounding. The promise is a
	# ripple a SECOND: a marker that pinged on every frame would be 174 pings, and a check
	# that asked only "does it ping" would still pass.
	them.beacon = true
	var pings := 0
	for _i in range(174):
		if them.present_beacon(1.0 / 60.0, them.global_position, false):
			pings += 1
	_check(pings == 3, "a beacon pings once a second, starting the moment it comes on",
		"%d pings in 2.9 s" % pings)
	_check(
		them.beacon_marker != null and them.beacon_marker.column_shown(),
		"and draws its column on somebody else's screen"
	)

	me.beacon = true
	var _mine := me.present_beacon(1.0 / 60.0, me.global_position, true)
	_check(
		me.beacon_marker != null and not me.beacon_marker.column_shown(),
		"but not on the beaconed player's own, where the camera is inside it"
	)

	them.beacon = false
	var _gone := them.present_beacon(1.0 / 60.0, them.global_position, false)
	_check(them.beacon_marker == null, "the marker goes when the flag does")

	me.health.alive = false
	var _out := me.present_beacon(1.0 / 60.0, me.global_position, true)
	_check(
		me.beacon_marker == null and me.beacon,
		"and while they are out, though the flag waits for the next round"
	)

	hud.queue_free()
	await _dispose(game)
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(ScConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = 3
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)
	var a := game.add_player(&"u1", "Ada", 1)
	var _mate := game.add_player(&"u1m", "Ada's mate", 1)
	var b := game.add_player(&"u2", "Bo", 2)
	var _c := game.add_player(&"u3", "Cy", 3)
	game.start()
	await _step(game, 4)
	var id := a.player_id
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, int(ScSpectate.DEATH_CAM_SECONDS * TICK_RATE) + 2)
	_check(b != null and game.spectate.is_spectating(id), "out by a real fall, and watching")
	_check(game.spectate.can_roam(id), "somebody who is out may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")
	_check(game.spectate.line_for(id).contains("free camera"), "and the line says so")
	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")

	var restricted := await _world(func(c: ScConfig) -> void:
		c.spectate_camera = 1)
	_check(restricted.spectate_rules.force_camera == 1 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	var keys := ScBindings.make()
	_check(keys.defaults_on("G").size() == 1 and str(keys.row_for_action(ScBindings.ROAM).get("default", "")) == "G",
		"the free camera is on G, and nothing else defaults to G")
	await _dispose(restricted)
	await _dispose(game)
	_finished()


## Where somebody who is out looks, on the world that decides it.
##
## Five players on three sides, so a round survives two sides losing people: `a` and `mate`
## on one, `b` and `d` on another, `c` alone on a third. Every step is the server's own
## decision — the death camera, the hand-over, the policy, the fallback — and a round
## starting is what ends all of it.
func _test_somebody_out_watches() -> void:
	_section("somebody who is out watches, and the server decides whom")

	var game := await _world(func(c: ScConfig) -> void:
		# Own side only is an operator's choice now (the default lets anybody roam).
		c.spectate_camera = 1
		c.team_count = 3
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)

	var a := game.add_player(&"a", "A", 1)
	var mate := game.add_player(&"mate", "Mate", 1)
	var b := game.add_player(&"b", "B", 2)
	var _d := game.add_player(&"d", "D", 2)
	var c := game.add_player(&"c", "C", 3)
	game.start()
	await _step(game, 4)

	var spectate := game.spectate
	_check(spectate != null and spectate.manager.rules.force_camera == 1,
		"a world configured for own side watches own side only")
	_check(not spectate.is_spectating(&"a"), "nobody who is playing is watching")

	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, 1)

	_check(
		not a.is_alive() and spectate.mode_of(&"a") == DotSpectatorView.Mode.DEATH_CAM,
		"falling off starts the death camera"
	)

	# Armed: with `on_died`'s fall case taken out, this camera is two metres above the kill
	# height looking at itself.
	var drop := spectate.camera_for(&"a")
	_check(
		drop.origin.y > game.config.deck_height and (-drop.basis.z).y < -0.9,
		"from up over the field, looking straight down the drop — not from the floor",
		"y %.1f, looking %.2f down" % [drop.origin.y, -(-drop.basis.z).y]
	)

	await _step(game, int(ScSpectate.DEATH_CAM_SECONDS * TICK_RATE) + 2)

	_check(
		spectate.mode_of(&"a") == DotSpectatorView.Mode.FIRST_PERSON
			and spectate.watching(&"a") == &"mate",
		"then through the eyes of the team-mate still up",
		"%s on %s" % [
			DotSpectatorView.Mode.keys()[spectate.mode_of(&"a")], String(spectate.watching(&"a"))
		]
	)

	var eye := mate.controller.render_state().position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0)
	_check(spectate.camera_for(&"a").origin.distance_to(eye) < 0.05,
		"where their eyes are drawn this frame")

	_check(
		not spectate.manager.may_watch("a", "b").ok and spectate.step(&"a", 1).ok
			and spectate.watching(&"a") == &"mate",
		"own side only: next is the only team-mate, and the other sides are refused"
	)
	_check(
		not spectate.step(&"a", 0).ok
			and spectate.mode_of(&"a") == DotSpectatorView.Mode.FIRST_PERSON,
		"and a chase camera is refused, because behind a team-mate sees round corners"
	)

	spectate.set_force_camera(0)
	_check(
		spectate.step(&"a", 0).ok and spectate.mode_of(&"a") == DotSpectatorView.Mode.CHASE,
		"with anybody allowed, the other camera is behind them"
	)

	var _moved := spectate.step(&"a", 1)
	_check(spectate.watching(&"a") == &"b",
		"and a viewer stepping through the list may land on another side, and stays there",
		String(spectate.watching(&"a")))

	# The server's OWN choice: b goes, the retarget sweep has to put `a` somewhere, and the
	# first allowed name in key order is `c`. Armed: with `_prefer_side` returning at once,
	# this is `c`.
	var at_b := b.controller.state.position
	b.place_at(Vector3(at_b.x, game.config.kill_height - 5.0, at_b.z), 0.0)
	await _step(game, 2)
	_check(spectate.watching(&"a") == &"mate",
		"when the server chooses, it chooses a team-mate first",
		String(spectate.watching(&"a")))

	spectate.set_force_camera(1)
	var at_mate := mate.controller.state.position
	mate.place_at(Vector3(at_mate.x, game.config.kill_height - 5.0, at_mate.z), 0.0)
	await _step(game, 2)
	_check(
		spectate.mode_of(&"a") == DotSpectatorView.Mode.FIXED,
		"a side with nobody left up watches from a fixed camera",
		DotSpectatorView.Mode.keys()[spectate.mode_of(&"a")]
	)

	var over := spectate.camera_for(&"a")
	_check(over.origin.y > game.config.deck_height + 10.0 and (-over.basis.z).y < 0.0,
		"over the field, looking down at it", "y %.1f" % over.origin.y)

	var was := game.phase
	game.phase = ScGame.Phase.SHOWDOWN
	var corners := spectate.camera_for(&"a")
	game.phase = was
	_check(
		corners.origin.distance_to(game.arena.showdown_centre())
			< over.origin.distance_to(game.arena.showdown_centre()),
		"and in the showdown, over the corners instead, where the round has gone"
	)

	# A round starting is everybody's new body. `c` going leaves one side, which ends it.
	var at_c := c.controller.state.position
	c.place_at(Vector3(at_c.x, game.config.kill_height - 5.0, at_c.z), 0.0)
	await _step(game, 12)
	_check(
		a.is_alive() and not spectate.is_spectating(&"a")
			and spectate.camera_for(&"a") == Transform3D.IDENTITY,
		"and the next round puts them back in the world, watching nothing",
		"round %d, alive %s" % [game.round_number, a.is_alive()]
	)

	await _dispose(game)
	_finished()


## What this game makes a noise about, both ways round, and the noises that are decisions.
##
## [b]The two directions that fail silently.[/b] An id with no recipe is a sound that stays
## silent for ever with nothing logged above DEBUG, and a recipe naming an id the catalogue
## does not have is a decision that reaches nothing. What no check here can reach is whether
## a speaker moves: a headless run has no device, so dot-audio builds the sink that records
## instead of playing — which is exactly why these are checks of the real manager.
func _test_the_game_makes_a_noise() -> void:
	_section("the game makes a noise, and every id has one")

	var catalogue := ScAudio.sound_catalogue()
	var recipes := ScAudio.sound_recipes()

	_check(catalogue.validate().ok, "the catalogue is a valid document")

	var declared := ScAudio.ids()
	var catalogued := catalogue.ids()
	var unlisted := catalogued.filter(func(id: StringName) -> bool: return not declared.has(id))
	var uncatalogued := declared.filter(func(id: StringName) -> bool: return not catalogued.has(id))
	_check(unlisted.is_empty() and uncatalogued.is_empty(),
		"the id list and the catalogue name the same sounds",
		"unlisted %s, uncatalogued %s" % [unlisted, uncatalogued])

	# dot-audio's stock footsteps and beds are files the addon ships, so they need no stand-in.
	var stock := DotAudioStock.ids()
	var synthesised := catalogued.filter(func(id: StringName) -> bool: return not stock.has(id))
	var silent := synthesised.filter(func(id: StringName) -> bool: return not recipes.has(id))
	_check(silent.is_empty(), "every catalogued id has a stand-in voice", str(silent))

	var nowhere: Array = recipes.keys().filter(
		func(id: Variant) -> bool: return not catalogue.has(StringName(id))
	)
	_check(nowhere.is_empty(), "and every stand-in names an id the catalogue has", str(nowhere))

	var bank := DotAudioSynth.bank(catalogue, recipes)
	var unbaked := synthesised.filter(func(id: StringName) -> bool: return not bank.has(id))
	_check(unbaked.is_empty(), "the synthesiser bakes all of them", str(unbaked))

	var kinds := [
		ZeeWeaponNet.KIND_SHOT, ZeeWeaponNet.KIND_SWING, ZeeWeaponNet.KIND_SPAWN,
		ZeeWeaponNet.KIND_BEAM, ZeeWeaponNet.KIND_THROW,
	]
	var unheard := kinds.filter(func(kind: int) -> bool:
		return not catalogue.has(ScAudio.weapon_sound(kind))
	)
	_check(
		unheard.is_empty() and ScAudio.weapon_sound(ZeeWeaponNet.KIND_NONE) == &"",
		"every kind of weapon use the snapshot can carry has a sound, and none has none",
		str(unheard)
	)

	var game := await _world()
	var audio := ScAudio.new()
	add_child(audio)
	_check(audio.setup().ok and audio.manager.sink is DotAudioSinkNull,
		"it comes up headless, on the sink that records rather than plays")

	var sink := audio.manager.sink as DotAudioSinkNull
	audio.muzzle = game.arena.muzzle()

	# The cannon is heard from anywhere on the map — and the corners are the far end of it.
	# Armed: at a corridor shooter's 90 m cull the showdown hears no cannon at all.
	audio.listen_from(game.arena.showdown_centre())
	_check(
		audio.on_prop_appeared(game.arena.muzzle() + Vector3(0.0, 1.0, 0.0)),
		"a prop at the muzzle is the cannon firing, heard from the showdown's corners",
		"%.0f m away" % game.arena.showdown_centre().distance_to(game.arena.muzzle())
	)

	audio.listen_from(game.arena.muzzle())
	_check(
		not audio.on_prop_appeared(game.arena.muzzle() + Vector3(20.0, 5.0, 0.0)),
		"and one that turns up anywhere else was already in the air — a join is not a volley"
	)

	_check(
		not audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.NONE)
			and audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.WOBBLE, 400.0)
			and audio.on_impact(Vector3.ZERO, ScPlatforms.Impact.SHATTERED, 5000.0),
		"a landing that did nothing is silent, and the others are not"
	)
	_check(
		sink.count_of(ScAudio.IMPACT_LIGHT) == 1 and sink.count_of(ScAudio.IMPACT_HEAVY) == 1,
		"and a wobble and a shattering are two different noises"
	)

	sink.forget()
	var _yours := audio.on_death(Vector3(0.0, 1.5, 0.0), true, true)
	var _theirs := audio.on_death(Vector3(0.0, 1.5, 0.0), true, false)
	var heard := sink.played()
	_check(
		heard.size() == 2 and str(heard[0]["id"]) == String(ScAudio.YOU_ARE_OUT)
			and int(heard[0]["kind"]) == DotAudioDef.Kind.FLAT
			and str(heard[1]["id"]) == String(ScAudio.PLAYER_FELL)
			and int(heard[1]["kind"]) == DotAudioDef.Kind.POSITIONAL_3D,
		"your own fall is flat and everybody else's comes from where they went",
		str(sink.played_ids())
	)

	# The creak, from the lean alone. Armed: with the hysteresis taken out, the held lean
	# creaks on every frame and this reads 1 + 29 more.
	sink.forget()
	var deck := game.platforms.deck_at(0)
	var limit := game.config.platform_collapse_lean
	audio.listen_from(deck.centre)
	deck.lean = Vector2(limit * 0.75, 0.0)
	var creaks := 0
	for _i in range(30):
		creaks += audio.present(game.platforms, limit)
	_check(
		creaks == 1 and sink.count_of(ScAudio.PLATFORM_CREAK) == 1,
		"a platform past seven tenths of its collapse angle creaks once, not every frame",
		"%d creaks, %d heard" % [creaks, sink.count_of(ScAudio.PLATFORM_CREAK)]
	)

	deck.lean = Vector2(limit * 0.3, 0.0)
	var _settled := audio.present(game.platforms, limit)
	deck.lean = Vector2(0.0, limit * 0.8)
	_check(audio.present(game.platforms, limit) == 1,
		"and again once it has settled and gone back over")

	deck.lean = Vector2(limit * 0.6, 0.0)
	var _held := audio.present(game.platforms, limit)
	deck.lean = Vector2(limit * 0.75, 0.0)
	_check(audio.present(game.platforms, limit) == 0,
		"but not for wobbling on the threshold without settling below half")

	audio.queue_free()
	await _dispose(game)
	_finished()


## The numbers a round produces, the achievements over them, and who is never counted.
##
## Three sides: `a` and `a2` on one, `b` on another, a stand-in alone on a third — so that
## `b` going over with their platform leaves the round running, and the stand-in is in
## every event a person is in and is never counted for any of them.
func _test_what_a_player_keeps() -> void:
	_section("what a player keeps from a round")

	_check(ScProgress.schema().validate().ok and ScProgress.catalogue().validate().ok,
		"the numbers and the achievements are both valid documents")

	var declared := ScProgress.ids()
	var in_schema: Array[StringName] = []
	for def in ScProgress.schema().stats:
		in_schema.append(def.id)
	var watched := ScProgress.catalogue().watched_stats()
	var unread := watched.filter(func(id: Variant) -> bool:
		return not in_schema.has(StringName(id)))
	_check(
		unread.is_empty() and in_schema.size() == declared.size()
			and declared.all(func(id: StringName) -> bool: return in_schema.has(id)),
		"every stat an achievement reads is one the schema declares, and the list is the schema",
		"unread %s" % [unread]
	)

	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = 3
		c.survival_seconds = 30.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 30.0
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)

	var a := game.add_player(&"a", "A", 1)
	var a2 := game.add_player(&"a2", "A2", 1)
	var b := game.add_player(&"b", "B", 2)
	var bot := game.add_player(&"bot", "Stand-in", 3)
	bot.is_bot = true

	var earned: Array[String] = []
	game.achievement_earned.connect(func(id: StringName, title: String, _points: int) -> void:
		earned.append("%s:%s" % [id, title]))

	game.start()
	# Long enough to land: everybody is put 1.2 m over their deck, and a player who is still
	# in the air is standing on nothing.
	await _step(game, 40)

	var progress := game.progress
	_check(progress != null, "an authoritative world keeps progress")

	var went := a.controller.state.position
	a.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, 1)
	var mine := progress.session_values(&"a")
	_check(
		mine.get_value(ScProgress.DEATHS, 0.0) == 1.0 and mine.get_value(ScProgress.FALLS, 0.0) == 1.0,
		"a fall is a death and a fall"
	)

	# Three landings on a2's own platform, on the far side of it. Each is a WOBBLE and each
	# missed them.
	var index := a2.standing_on
	var deck := game.platforms.deck_at(maxi(index, 0))
	var away := deck.centre + (deck.centre - a2.controller.state.position).normalized() * 3.0
	away.y = deck.centre.y
	for _i in range(3):
		var _hit := game.platforms.report_impact(index, 12.0, 5.0, Vector3(away.x, deck.centre.y, away.z))
	var dodged := progress.session_values(&"a2").get_value(ScProgress.PROPS_DODGED, 0.0)
	var lifetime := progress.achievements.progress_of("a2").value_of(ScProgress.PROPS_DODGED) \
		if progress.achievements.has("a2") else -1.0
	_check(index >= 0 and dodged == 3.0, "three things landing on your platform and missing you are three dodges",
		"%.0f on platform %d" % [dodged, index])
	# Armed: with the link bypassed (recorded wired straight into record), this is 1+2+3.
	_check(lifetime == 3.0, "and the lifetime total is three, not the running totals added up",
		"%.0f" % lifetime)

	# b's platform goes over by LEAN with b on it: that is b's doing.
	var tipped_at := b.standing_on
	var _went_over := game.platforms.collapse(tipped_at, ScPlatforms.WHY_LEAN)
	_check(
		tipped_at >= 0 and progress.session_values(&"b").get_value(ScProgress.PLATFORMS_TIPPED, 0.0) == 1.0,
		"a platform that goes over by lean is tipped by whoever was on it"
	)
	_check(earned.has("b:Tipping Point"), "which is a secret achievement, told the moment it is earned",
		", ".join(earned))

	# And out. Not by waiting for the drop, which is six seconds of a section about the tip;
	# that a collapse really takes everybody on it is "a platform off its pillar takes
	# everybody on it", which waits.
	var at_b := b.controller.state.position
	b.place_at(Vector3(at_b.x, game.config.kill_height - 5.0, at_b.z), 0.0)
	await _step(game, 1)

	game.round_elapsed = game.config.survival_seconds - 0.02
	await _step(game, 4)
	_check(game.phase == ScGame.Phase.HANDOVER and not b.is_alive(),
		"b reaches the floor, and the clock runs out", ScGame.Phase.keys()[game.phase])
	_check(
		progress.session_values(&"a2").get_value(ScProgress.ROUNDS_SURVIVED, 0.0) == 1.0
			and progress.session_values(&"a").get_value(ScProgress.ROUNDS_SURVIVED, 0.0) == 0.0
			and earned.has("a2:Still Standing"),
		"whoever is still up survived the round, and is told"
	)

	game.round_elapsed = game.config.showdown_starts_at() + 0.02
	await _step(game, 2)

	var shot := DotDamage.make(a2.entity_id, bot.entity_id, 1000.0, null)
	shot.point = bot.controller.state.position
	shot.tick = 10000000
	shot.context = {"why": ScGame.DIED_SHOT}
	var ended: Array[int] = []
	game.round_over.connect(func(_n: int, winner: int) -> void: ended.append(winner))
	var _applied := game.combat.apply_damage(shot)
	await _step(game, 6)

	var theirs := progress.session_values(&"a2")
	# Armed: with the counting moved back after `report_kill`, this reads 0 — the shot that
	# ends a round is counted after the round it ended has been filed.
	_check(not ended.is_empty() and theirs.get_value(ScProgress.SHOWDOWN_KILLS, 0.0) == 1.0,
		"putting the last of a side out in the corners is a showdown kill, and ends the round",
		"%.0f kills" % theirs.get_value(ScProgress.SHOWDOWN_KILLS, 0.0))
	_check(
		theirs.get_value(ScProgress.ROUNDS_WON, 0.0) == 1.0
			and theirs.get_value(ScProgress.SHOWDOWN_WINS, 0.0) == 1.0
			and theirs.get_value(ScProgress.BEST_ROUND_KILLS, 0.0) == 1.0
			and theirs.get_value(ScProgress.ROUNDS_PLAYED, 0.0) == 1.0,
		"the last side standing won the round, and the one still in the corners won the showdown",
		"winner %s; won %.0f, showdowns %.0f, best %.0f, played %.0f" % [
			ended, theirs.get_value(ScProgress.ROUNDS_WON, 0.0),
			theirs.get_value(ScProgress.SHOWDOWN_WINS, 0.0),
			theirs.get_value(ScProgress.BEST_ROUND_KILLS, 0.0),
			theirs.get_value(ScProgress.ROUNDS_PLAYED, 0.0),
		]
	)
	_check(
		progress.session_values(&"a").get_value(ScProgress.ROUNDS_WON, 0.0) == 1.0
			and progress.session_values(&"a").get_value(ScProgress.SHOWDOWN_WINS, 0.0) == 0.0,
		"a team-mate who fell off wins the round and not the showdown"
	)

	# Armed: with the bot guard taken out of `record`, the stand-in has a row.
	_check(not progress.stats.has_player(&"bot"),
		"and the stand-in, who survived, was shot and lost, was never counted at all")

	game.remove_player(&"a2")
	_check(not progress.stats.has_player(&"a2") and not progress.achievements.has("a2"),
		"somebody who leaves stops being counted, and their progress is let go of")

	await _dispose(game)
	_finished()


## A world, built and stepped by hand.
##
## [b]`register_service` is off on every world after the first, and two of these in one
## process is the ordinary case here.[/b] A registry name is global, so the last one to
## register wins — and dot-core's own random manager has the same problem, which is why
## [ScGame] turns that off too.
## The family's rule since the first play test: M opens the layout list, and solo a choice
## changes it now. The server's half (the owner's flag, the vote) is in `dedicated` and dot-vote.
## Offline the world samples the local player's movement itself, so the client's buttons
## have to go onto that sample. They were stamped on the controller's command and then sampled
## over, and offline no trigger ever reached the world's gun (game-zombie-zone's play test).
func _test_offline_trigger() -> void:
	_section("offline, the client's trigger reaches the world's gun")
	var game := await _world()
	var me := game.add_player(&"local", "You", 0, true)
	await _step(game, 2)
	var client := ScClient.new()
	client.game = game
	client._adopt(me)
	client._firing = true
	me.simulate(1, 1.0 / float(TICK_RATE))
	var pressed := game.weapon_command_for(me).is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_check(me.sampler != null and pressed, "the world's weapon command has the trigger the client holds")
	client.free()
	_finished()


## The play test's weapons, at the handover: offline the hands were never armed at all (the
## client heard the handover only from a bridge it does not have), and connected the drawn rig
## was given the whole pack, so a slot held whatever was given last; nothing counted the
## magazine; nothing said a shot had landed. Armed: without the offline handover the first check
## fails, with `give_everything` back the second, without `correct_drawn` the fourth, without
## the HIT path the last.
func _test_the_drawn_gun() -> void:
	_section("at the handover the hands draw the server's guns, counted on the HUD, with a marker for a hit")
	var client: Node = ScClient.new()
	client.force_offline = true
	client.offline_bots = 1
	client.config_file = "user://cfg/headless-none.json"
	add_child(client)
	var platform: DotGameClient = client.get("platform")
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 8:
		await get_tree().process_frame
	var world: ScGame = client.get("game")
	var me: ScPlayer = client.get("player")
	world._begin_handover()
	for i in 4:
		await get_tree().physics_frame

	var drawn: ZeeWeaponRig = client.get("weapons")
	_check(drawn != null and me.weapons != null and drawn != me.weapons, "offline, the handover arms the hands")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same and drawn.arsenal.current_slot() == me.weapons.arsenal.current_slot(),
		"the drawn gun holds exactly the server's weapons, slot for slot, the same one out", " ".join(held))

	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	var def := drawn.current_def() if drawn != null else null
	var expected := "?"
	if def != null and def.ammo_type != &"":
		expected = "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] \
			if def.magazine > 0 else "%d" % drawn.arsenal.ammo().count(def.ammo_type)
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and (def.ammo_type == &"" or counter.count_text() == expected),
		"the HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])

	var corrected := true
	var detail := "melee in hand"
	if def != null and def.magazine > 0:
		var world_count := me.weapons.arsenal.current().magazine
		drawn.arsenal.current().magazine = maxi(world_count - 1, 0)
		client.set("_drawn_quiet", 0.0)
		for i in 10:
			await get_tree().physics_frame
		var early := drawn.arsenal.current().magazine
		for i in 60:
			await get_tree().physics_frame
		corrected = early == maxi(world_count - 1, 0) and drawn.arsenal.current().magazine == world_count
		detail = "after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count]
	_check(corrected, "the drawn gun takes the server's count once quiet, and not before", detail)

	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), true, false)
	_check(marker != null and marker.alpha() > 0.9 and marker.kill, "a hit the world confirms flashes the marker, a kill's")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


func _test_the_map_menu() -> void:
	_section("M opens the layout list, and solo a choice changes it")
	var game := await _world()
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 4)
	var settings := ScSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.layout_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.layout_rows, game.change_layout_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and game.layout.id == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, game.layout.id])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


func _world(configure: Callable = Callable()) -> ScGame:
	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.vary_layout = false

	if configure.is_valid():
		configure.call(config)

	var game := ScGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)

	_worlds.append(game)

	# Two frames, so the arena, the platforms and every collider are in the physics space
	# before anything is asserted about them. `add_child` does not put a shape in a space;
	# the next physics step does.
	await _physics_frame()
	await _physics_frame()

	return game


func _step(game: ScGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame

	if _tracked != null and is_instance_valid(_tracked) and _tracked.controller != null:
		var state := _tracked.controller.state
		_covered += Vector2(state.position.x - _tracked_at.x, state.position.z - _tracked_at.z).length()
		_top_speed = maxf(_top_speed, Vector2(state.velocity.x, state.velocity.z).length())
		_tracked_at = state.position


## Starts measuring [param player]'s run from where they stand.
func _track(player: ScPlayer) -> void:
	_tracked = player
	_tracked_at = player.controller.state.position if player != null else Vector3.ZERO
	_covered = 0.0
	_top_speed = 0.0


func _dispose(game: ScGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


## Every bare `"res://…"` string in a SHIPPED script that names one of this game's own
## directories, as `file:line`. See the form-three check that calls it.
##
## The same rule `dot-server-deploy/tools/check.sh` counts, asked here because that tool is
## not what somebody adding a file runs: comments are prose and skipped, a literal already
## inside `<Game>Paths.rebase("…")` is the fixed form and skipped, and a path whose first
## segment this game does not ship — `res://addons/…`, `res://audio/…` in a game with no
## audio — names the HOST's file and is right as it stands.
func _bare_own_paths() -> PackedStringArray:
	var skip := ["addons", "examples", "tools", "screenshots"]
	var owned := PackedStringArray()

	for directory: String in DirAccess.get_directories_at("res://"):
		if not directory.begins_with(".") and not skip.has(directory):
			owned.append(directory)

	var wrapped := RegEx.create_from_string("[A-Za-z0-9_]*Paths\\.rebase\\(\"res://[^\"]*\"\\)")
	var bare := RegEx.create_from_string("\"res://([^/\"]+)")
	var hits := PackedStringArray()
	var pending: Array[String] = []

	for directory: String in owned:
		pending.append("res://".path_join(directory))

	while not pending.is_empty():
		var at: String = pending.pop_back()

		for sub: String in DirAccess.get_directories_at(at):
			pending.append(at.path_join(sub))

		for file: String in DirAccess.get_files_at(at):
			if not file.ends_with(".gd"):
				continue

			var path := at.path_join(file)
			var lines := FileAccess.get_file_as_string(path).split("\n")

			for i in lines.size():
				if lines[i].strip_edges().begins_with("#"):
					continue

				for found in bare.search_all(wrapped.sub(lines[i], "", true)):
					if owned.has(found.get_string(1)):
						hits.append("%s:%d" % [path, i + 1])

	return hits
