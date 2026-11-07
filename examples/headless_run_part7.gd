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
