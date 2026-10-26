extends Node

const ScConfig := preload("sc_config.gd")
const ScGame := preload("sc_game.gd")
const ScMapConfig := preload("sc_map_config.gd")

## What a [DotServer] loads as its game scene. Never a client.
##
## [b]Small on purpose.[/b] Everything a dedicated server does is in `sc_module.gd`; this
## exists because dot-server loads a SCENE and the game needs one, and because the world has
## to be in the tree — registered under [constant ScGame.SERVICE] — before the module looks
## for it. dot-server loads the scene and then the module, in that order, for exactly this
## reason.
##
## [b]It lives in `game/`, not beside its own scene in `scenes/`.[/b] That is a deployment
## constraint rather than a preference: a game is vendored by copying its `game/` wholesale
## and its `scenes/*.tscn` — only the `.tscn` — so a script under `scenes/` is a script that
## never reaches the build. The scene then fails to load with "referenced non-existent
## resource", the module refuses to load because no game registered itself, and the server
## reports that the game loaded but its module did not. Every other game in this family keeps
## its server scene's script in `game/`, having learned it the same way.

const CHANNEL := "sc.server"

## The world this server is running. What the module will find in the registry.
var game: ScGame = null


func _ready() -> void:
	var config := ScConfig.new()

	# The family's `defaults < JSON < environment < argv` chain, on the server too. It is how
	# an operator sets `SC_SURVIVAL_SECONDS` or `--sc-columns` without editing anything, and
	# the cvars the module adds are the live half of the same numbers.
	# Plus the cfg/ yml layers; strict (a typo or bad value stops the boot) on a dedicated server.
	var binder := ScConfig.make_binder(config, "user://cfg/smash-copter.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = ScGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# [b]The engine's rate, which the server has already set from `sv_tickrate`.[/b] Read
	# rather than chosen: this scene is loaded after the server has booted and executed its
	# config, so the number is already decided — and a game that picked its own would be a
	# simulation running at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"field": "%d x %d" % [config.columns, config.rows],
		"teams": config.team_count,
	})

	# [b]Not started here.[/b] `start()` lays the field out and puts everybody on it, and
	# nothing is listening yet: the module builds the bridge that answers `world_rebuilt`, so
	# a field laid out now is a dozen platforms no client is ever told about. The module
	# starts it, on the last line of its own load.
