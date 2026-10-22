extends Node

const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScPlayer := preload("../game/sc_player.gd")

## Bot soak on the real game: N stand-ins play rounds on one layout for M simulated minutes through
## dot-bot's DotBotSoak, fed by dot-spawn's DotSpawnWatch. A "map" here is a layout id.
##
## [codeblock]
## ./game.sh soak [layout] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map terraces --bots 4 --minutes 2
## [/codeblock]
##
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<layout>.json, prints the SOAK line, exits 1 when the run fails.
## Rounds run back to back. A stand-in is only judged stuck in the showdown while alive: on the
## platforms it stands still by design, and a fall is the game. Kills are off.

const DEFAULT_MAP := &"terraces"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 4
const TICK_RATE := 64
const FIGHT_RANGE := 30.0

var _game: ScGame
var _rounds_over := 0
var _showdown_ticks := 0
var _traced_sec := {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := _arg("map", String(DEFAULT_MAP))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	# The object count saws up and down with each round's field and props, so a run that ends
	# mid-round reads 25 to 30 percent over its start; a real leak keeps climbing past 40.
	cfg.max_object_growth_pct = 40.0
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.vary_layout = false
	# Short platform phase so the showdown, the only phase the stand-ins walk, is most of the run.
	config.survival_seconds = 15.0
	config.layout_ids = PackedStringArray([map_id])
	var known := false
	for layout in ScLayouts.all(config):
		known = known or String(layout.id) == map_id
	if not known:
		_fail("no layout %s" % map_id)
		return

	_game = ScGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.authoritative = true
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	_game.round_over.connect(func(_n: int, _w: int) -> void: _rounds_over += 1)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var taken: Array = []
	for i in range(cfg.bots):
		var bot_name := DotBotNames.pick(taken, i, ScGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := _game.add_player(StringName("u%d" % (900100 + i)), bot_name)
		bot.is_bot = true
	_game.start()

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees run.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = map_id
	report["rounds"] = _game.round_number
	report["rounds_over"] = _rounds_over
	report["showdown_sec"] = snappedf(float(_showdown_ticks) / float(TICK_RATE), 0.1)
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a world still loaded at quit can abort the process.
func _release_game() -> void:
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _step(delta: float) -> void:
	if _game.phase == ScGame.Phase.SHOWDOWN:
		_showdown_ticks += 1
	_game.simulate(delta)


func _movers() -> Array:
	var out: Array = []
	var fighting: bool = _game.phase == ScGame.Phase.SHOWDOWN
	for id: StringName in _game.players:
		var body: ScPlayer = _game.players[id]
		out.append({"id": id, "position": body.controller.state.position, "kind": &"bot",
			"has_goal": fighting and body.is_alive() and not body.riding and not _in_firefight(body)})
		if fighting and body.is_alive():
			_trace(id, body)
	return out


## A stand-in that stopped to shoot an enemy inside gun range is fighting, not stuck.
func _in_firefight(body: ScPlayer) -> bool:
	for id: StringName in _game.players:
		var other: ScPlayer = _game.players[id]
		if other.team != body.team and other.is_alive() \
				and other.controller.state.position.distance_to(body.controller.state.position) < FIGHT_RANGE:
			return true
	return false


## `--trace` prints each live stand-in once a second in the showdown: position, speed, zone.
func _trace(id: StringName, body: ScPlayer) -> void:
	if not OS.get_cmdline_user_args().has("--trace"):
		return
	var sec := _showdown_ticks / TICK_RATE
	if _traced_sec.get(id, -1) == sec:
		return
	_traced_sec[id] = sec
	var p := body.controller.state.position
	var v := body.controller.state.velocity
	var zone: Dictionary = _game._showdown_zone(p)
	print("TRACE t=%d %s team=%d hp=%s pos=(%.1f,%.1f,y%.1f) v=%.1f %s arm=%d s=%.1f" % [sec, id, body.team, str(body.health.health), p.x, p.z, p.y,
		Vector2(v.x, v.z).length(), zone.where, zone.arm, zone.s])


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
