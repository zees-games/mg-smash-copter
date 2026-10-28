extends DotGameCheckSuite

const ScMapConfig := preload("../game/sc_map_config.gd")

## A layout gets its file's whitelisted values and the next layout gets the previous ones back.
## Run: `godot --headless --path . res://examples/headless_mapcfg.tscn`
## The cvars start away from the file's values, so "got them" cannot be a default showing through.

const SECTIONS := 2
const CHECKS := 9
const FIXTURE_CFG := "res://examples/fixtures/mapcfg"

var _sections := 0


class SmashModule extends DotGameModule:
	func _module_name() -> String:
		return "smash"

	func _map_config_game() -> String:
		return ScMapConfig.GAME_ID

	func _map_config_keys() -> Dictionary:
		return ScMapConfig.KEYS


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-smash-copter: per-layout cvars")
	if not ResourceLoader.exists(DotGameMapConfig.SCRIPT_PATH):
		print("SKIPPED: dot-map is not linked into this project (addons/dot_map)")
		get_tree().quit(0)
		return

	DotAddonConfig.config_root = ProjectSettings.globalize_path(FIXTURE_CFG)
	var console := DotConsole.new()
	add_child(console)
	console.cvar("sc_gravity", "9.8", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sc_cannon_interval", "4", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sc_teams", "2", "", DotConVar.FLAG_ARCHIVE)
	var module := SmashModule.new()
	module.console = console
	add_child(module)

	_sections += 1
	module.report_map("ring")
	_check(console.find_cvar("sc_gravity").get_float() == 6.5, "ring sets sc_gravity")
	_check(console.find_cvar("sc_cannon_interval").get_float() == 2.5, "ring sets sc_cannon_interval")
	_check(console.find_cvar("sc_teams").get_int() == 2, "sc_teams is not whitelisted and stays")
	_check(module.map_config.applied().size() == 2, "exactly the two whitelisted keys applied")

	_sections += 1
	module.report_map("full")
	_check(console.find_cvar("sc_gravity").get_float() == 9.8, "the next layout has sc_gravity back")
	_check(console.find_cvar("sc_cannon_interval").get_float() == 4.0, "and sc_cannon_interval")
	_check(module.map_config.applied().is_empty(), "a layout with no values applies nothing")
	module.report_map("ring")
	module._teardown()
	_check(console.find_cvar("sc_gravity").get_float() == 9.8, "unloading restores")
	_check(ScMapConfig.KEYS.has("mp_killcam_time") and not ScMapConfig.KEYS.has("sc_teams"), "whitelist keeps rules, not layout size")

	_report(CHECKS)
