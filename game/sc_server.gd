extends Node

const ScConfig := preload("sc_config.gd")
const ScGame := preload("sc_game.gd")
const ScMapConfig := preload("sc_map_config.gd")

## What a [DotServer] loads as its game scene; never a client. The work is in `sc_module.gd`: dot-server
## loads a SCENE, and the world must be in the tree under [constant ScGame.SERVICE] before the module looks.
## It lives in `game/`, not `scenes/`: only `scenes/*.tscn` is vendored, so a script there never ships.

const CHANNEL := "sc.server"

## The world this server is running. What the module will find in the registry.
var game: ScGame = null


func _ready() -> void:
	var config := ScConfig.new()

	# The family's `defaults < JSON < environment < argv` chain on the server too (an operator sets
	# `SC_SURVIVAL_SECONDS` or `--sc-columns` without editing), plus the cfg/ yml layers; strict, so a
	# typo or bad value stops the boot.
	var binder := ScConfig.make_binder(config, "user://cfg/smash-copter.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = ScGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# The engine's rate, already set from `sv_tickrate`: read, not chosen, because a game that picked
	# its own would simulate at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"field": "%d x %d" % [config.columns, config.rows],
		"teams": config.team_count,
	})

	# Not started here: nothing listens yet (the module builds the bridge that answers `world_rebuilt`),
	# so a field laid out now is platforms no client is told about. The module starts it, last.
