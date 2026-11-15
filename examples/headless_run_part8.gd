extends "headless_run_part7.gd"

## The retune section of the headless_run suite (headless_run.gd extends this): a special's tunables reach the motor, not only the controller's field.


## `ScPlayer.retune` replaces the controller's tunables at every special start and end, and the motor keeps the object it was built with, so the special's run speed, gravity and grip once never reached the movement. Measured, not read off the fields: the speed and the fall are what a player feels.
## Armed: with `retune` not handing the new tunables to the motor, every check after the first two fails (the motor still has the base numbers); with the mask not carried across, the mask check.
func _test_a_special_reaches_the_motor() -> void:
	_section("a special's run speed, gravity and grip reach the motor, and the end of it puts them back")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 2.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 60.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
		c.specials_enabled = false
	)
	var runner := game.add_player(&"retuned", "Retuned", 1)
	var _other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, int(3.0 * TICK_RATE))

	var armed := game.phase == ScGame.Phase.SHOWDOWN and runner.weapons != null and runner.weapons.current_def() != null
	_check(armed, "the showdown is running and the player holds a gun", ScGame.Phase.keys()[game.phase])
	if not armed:
		_finished()
		return

	var start := runner.controller.state.position
	var plain := ScSpecials.Active.new()
	var special := ScSpecials.Active.new()
	special.run_speed_scale = 1.5
	special.gravity_scale = 0.5
	special.grip_scale = 0.25

	var mask := runner.controller.motor.tunables.collision_mask

	var base_run: float = await _retune_best_peak(game, runner, start, false)
	var base_fall: float = await _retune_fall(game, runner, start)
	var base_glide: float = await _retune_glide(game, runner, start)

	runner.retune(special)
	var motor := runner.controller.motor
	_check(motor != null and motor.tunables == runner.controller.tunables,
		"after a special starts, the motor holds the controller's tunables, not the ones it was built with")
	_check(runner.controller.tunables.collision_mask == mask and motor.tunables.collision_mask == mask,
		"and the body rules' collision mask survived the new object", "%d, was %d" % [motor.tunables.collision_mask, mask])

	var fast_run: float = await _retune_best_peak(game, runner, start, false)
	var light_fall: float = await _retune_fall(game, runner, start)
	var slick_glide: float = await _retune_glide(game, runner, start)
	_check(base_run > 1.0 and fast_run > base_run * 1.25 and fast_run < base_run * 1.6,
		"the special's run speed is the speed they run at", "%.2f m/s against %.2f, a x1.5 special (the half second and the small arena stop short of the full ratio)" % [fast_run, base_run])
	_check(base_fall > 1.0 and absf(light_fall / base_fall - 0.5) < 0.1,
		"and its gravity is the gravity they fall under", "%.2f m/s after a third of a second against %.2f, expected x0.5" % [light_fall, base_fall])
	_check(slick_glide > base_glide * 1.5,
		"and its grip is the grip they stop with", "%.2f m/s left after 6 ticks against %.2f" % [slick_glide, base_glide])

	# The aim pace scales the motor's own tunables for the tick, so it must work under the special too, and leave them as they were.
	var paced := game.ads_rules.move_speed_for(runner.weapons.current_def().id)
	var kept_speed := motor.tunables.max_speed
	var aimed_run: float = await _retune_best_peak(game, runner, start, true)
	_check(absf(aimed_run / fast_run - paced) < 0.1 and is_equal_approx(motor.tunables.max_speed, kept_speed),
		"aimed under a special, the pace scales the special's speed and puts it back",
		"%.2f of %.2f m/s, ratio %.2f of %.2f, top speed %.2f from %.2f" % [aimed_run, fast_run, aimed_run / maxf(fast_run, 0.001), paced, motor.tunables.max_speed, kept_speed])

	runner.retune(plain)
	_check(motor.tunables == runner.controller.tunables and is_equal_approx(motor.tunables.max_speed, ScPlayer.tunables_for(game.config, plain).max_speed),
		"when it ends the motor is back on the ordinary numbers")
	var back_run: float = await _retune_best_peak(game, runner, start, false)
	var back_fall: float = await _retune_fall(game, runner, start)
	var back_glide: float = await _retune_glide(game, runner, start)
	_check(absf(back_run - base_run) < 0.1 and absf(back_fall - base_fall) < 0.1 and absf(back_glide - base_glide) < 0.1,
		"and they run, fall and stop as they did before", "run %.2f/%.2f, fall %.2f/%.2f, glide %.2f/%.2f" % [back_run, base_run, back_fall, base_fall, back_glide, base_glide])

	await _dispose(game)
	_finished()


## The fastest [param runner] gets in half a second from [param start] walking [param direction], sights up or down.
func _retune_peak(game: ScGame, runner: ScPlayer, start: Vector3, direction: Vector2, aim: bool) -> float:
	runner.place_at(start, 0.0)
	runner.controller.state.velocity = Vector3.ZERO
	runner.aiming = aim
	var command := DotFpsCommand.new()
	command.move = direction
	await _step(game, 4)
	var top := 0.0
	for i in range(TICK_RATE / 2):
		runner.controller.apply_command(command)
		runner.aiming = aim
		await _step(game, 1)
		var v := runner.controller.state.velocity
		top = maxf(top, Vector2(v.x, v.z).length())
	runner.aiming = false
	return top


## The best of four directions (the arena is small), from the same spot.
func _retune_best_peak(game: ScGame, runner: ScPlayer, start: Vector3, aim: bool) -> float:
	var most := 0.0
	for direction: Vector2 in [Vector2(0.0, 1.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, -1.0)]:
		var reach: float = await _retune_peak(game, runner, start, direction, aim)
		most = maxf(most, reach)
	return most


## The vertical speed after a fall of a third of a second.
func _retune_fall(game: ScGame, runner: ScPlayer, start: Vector3) -> float:
	runner.place_at(start + Vector3.UP * 6.0, 0.0)
	runner.controller.state.velocity = Vector3.ZERO
	await _step(game, TICK_RATE / 3)
	return -runner.controller.state.velocity.y


## The horizontal speed left after a glide with no key down.
func _retune_glide(game: ScGame, runner: ScPlayer, start: Vector3) -> float:
	runner.place_at(start, 0.0)
	runner.controller.state.velocity = Vector3.ZERO
	await _step(game, 6)
	runner.controller.state.velocity = Vector3(4.0, 0.0, 0.0)
	runner.controller.apply_command(DotFpsCommand.new())
	await _step(game, 6)
	var v := runner.controller.state.velocity
	return Vector2(v.x, v.z).length()
