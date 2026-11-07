extends "headless_run_part6.gd"

## The flashlight section of the headless_run suite (headless_run.gd extends this): the sky sets it, a player switches it, the out and a config may not.

const ScFlashlight := preload("../game/sc_flashlight.gd")


func _test_the_flashlight() -> void:
	_section("the flashlight: the sky sets it, a player switches it, the out and a config may not")
	var game := await _world(func(c: ScConfig) -> void:
		c.team_count = 3
		c.cannon_enabled = false
		c.specials_enabled = false
		c.clear_platforms_for_showdown = false
	)
	var a := game.add_player(&"f1", "Ada", 1)
	var _mate := game.add_player(&"f1m", "Ada's mate", 1)
	var b := game.add_player(&"f2", "Bo", 2)
	var _c := game.add_player(&"f3", "Cy", 3)
	game.start()
	await _step(game, 4)
	var cfg := game.flashlight_conf()
	var keys := ScBindings.make()
	_check(cfg.key == "F" and game.flashlight_binder != null, "the key is F and the config has a binder", cfg.key)
	_check(str(keys.row_for_action(ScBindings.FLASHLIGHT).get("default", "")) == "F" and keys.defaults_on("F").size() == 1,
		"the key is a bindings row, and nothing else defaults to F")
	_check(not ScFlashlight.starts_on(cfg, "terraces"), "the lit sky starts dark")
	_check(ScFlashlight.starts_on(cfg, "terraces", "outdoor_night"), "and a night mood would start lit")

	cfg.default_state = DotFlashlightConfig.START_ON
	a.flashlight_ready = false
	await _step(game, 2)
	_check(a.flashlight, "a config that starts lit lights the player")
	cfg.default_state = DotFlashlightConfig.START_OFF
	a.flashlight_ready = false
	await _step(game, 2)
	_check(not a.flashlight, "and one that starts dark does not")

	_check(game.toggle_flashlight(a.player_id) and a.flashlight, "the switch turns a light on")
	_check(game.toggle_flashlight(a.player_id) and not a.flashlight, "and the next press turns it off")

	var went := b.controller.state.position
	b.place_at(Vector3(went.x, game.config.kill_height - 5.0, went.z), 0.0)
	await _step(game, int(ScSpectate.DEATH_CAM_SECONDS * TICK_RATE) + 2)
	_check(not game.toggle_flashlight(b.player_id) and not b.flashlight, "somebody out of the round has no switch")

	cfg.enabled = false
	_check(not game.toggle_flashlight(a.player_id) and not a.flashlight, "a disabled config has no light")
	cfg.enabled = true
	cfg.default_state = DotFlashlightConfig.START_DARK
	await _dispose(game)
	_finished()


## The aim button, as the game reads it: `ScPlayer.aiming` (the client sets it offline, the wire sets it online) reaches the rig as BUTTON_AIM,
## slows the motor to the rules' pace and closes the spread. Armed: with `ScGame.weapon_command_for` not setting BUTTON_AIM, the first,
## second and fourth checks fail; with `ScPlayer.step_controller` calling the motor unscaled, the first.
func _test_the_aim_button() -> void:
	_section("the aim button slows an armed player's pace and closes the spread")

	var game := await _world(func(c: ScConfig) -> void:
		c.survival_seconds = 2.0
		c.showdown_warmup_seconds = 0.5
		c.showdown_seconds = 60.0
		c.warmup_seconds = 0.0
		c.cannon_enabled = false
	)
	var hunter := game.add_player(&"aimer", "Aimer", 1)
	var _other := game.add_player(&"other", "Other", 2)
	game.start()
	await _step(game, int(3.0 * TICK_RATE))

	var rig := hunter.weapons
	var armed := game.phase == ScGame.Phase.SHOWDOWN and rig != null and rig.current_def() != null
	_check(armed, "the showdown is running and the player holds a gun", ScGame.Phase.keys()[game.phase])
	if not armed:
		_finished()
		return

	var rules := game.ads_rules
	var held := rig.current_def()
	var paced := rules.move_speed_for(held.id)
	var start := hunter.controller.state.position

	# The fastest the body gets in half a second from the same spot, best of four directions (the arena is small: peak speed, not distance, so a wall does not hide the difference), sights down then up.
	var walk := func(direction: Vector2, aim: bool) -> float:
		hunter.place_at(start, 0.0)
		hunter.controller.state.velocity = Vector3.ZERO
		hunter.aiming = aim
		var command := DotFpsCommand.new()
		command.move = direction
		await _step(game, 4)
		var peak := 0.0
		for i in range(TICK_RATE / 2):
			hunter.controller.apply_command(command)
			hunter.aiming = aim
			await _step(game, 1)
			var v := hunter.controller.state.velocity
			peak = maxf(peak, Vector2(v.x, v.z).length())
		return peak
	var best := Vector2.ZERO
	var hip := 0.0
	for direction: Vector2 in [Vector2(0.0, 1.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, -1.0)]:
		var reach: float = await walk.call(direction, false)
		if reach > hip:
			hip = reach
			best = direction
	var hip_scale := rig.ads_move_scale()
	var aimed: float = await walk.call(best, true)
	var aimed_scale := rig.ads_move_scale()
	_check(hip > 1.0 and absf(aimed / hip - paced) < 0.1 and absf(aimed_scale - paced) < 0.001 and hip_scale == 1.0,
		"aimed, the player walks at the rules' pace and not otherwise", "hip %.2f m/s aimed %.2f m/s, ratio %.2f of %.2f, rig %.2f" % [hip, aimed, aimed / maxf(hip, 0.001), paced, aimed_scale])

	# The wire to the rig: the server builds the weapon command from the body's flag.
	hunter.controller.apply_command(DotFpsCommand.new())
	hunter.aiming = true
	var up := game.weapon_command_for(hunter)
	hunter.aiming = false
	var down := game.weapon_command_for(hunter)
	_check(up.is_pressed(DotWeaponCommand.BUTTON_AIM) and not down.is_pressed(DotWeaponCommand.BUTTON_AIM),
		"the body's flag is the weapon command's aim button")

	# The spread: first shots of a held trigger with the sights down, then up for longer than they take to rise.
	var spreads := func(aim: bool) -> float:
		var command := DotWeaponCommand.new()
		command.set_button(DotWeaponCommand.BUTTON_AIM, aim)
		var tick := 100000
		for i in range(TICK_RATE * 2):
			tick += 1
			var _o := rig.simulate_tick(command, tick)
		command.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		var total := 0.0
		var shots := 0
		for i in range(TICK_RATE):
			tick += 1
			rig.arsenal.current().magazine = held.magazine
			var outcome := rig.simulate_tick(command, tick)
			for shot in outcome.shots:
				total += shot.spread
				shots += 1
			command.set_button(DotWeaponCommand.BUTTON_ATTACK, i % 2 == 1)
		return total / float(maxi(shots, 1))
	var hip_spread: float = spreads.call(false)
	var aimed_spread: float = spreads.call(true)
	_check(hip_spread > 0.0 and aimed_spread < hip_spread * 0.9,
		"and the sights close the spread", "hip %.3f, aimed %.3f degrees, rule %.2f" % [hip_spread, aimed_spread, rules.spread_for(held.id)])
	_check(rig.ads_progress() > 0.99 and rig.ads_move_scale() == paced, "fully raised, the rig is at full progress and the rules' pace",
		"%.2f, %.2f" % [rig.ads_progress(), rig.ads_move_scale()])
	await _dispose(game)
	_finished()
