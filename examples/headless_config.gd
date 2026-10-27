extends DotGameCheckSuite

## ScConfig through DotGameConfigBinder: fields, cvars, strict refusal, the diff, a shipped yml loading back, and the workbench round trip.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const ScConfig := preload("../game/sc_config.gd")
const ROOT := "user://sc_cfgtest"
const GAME := "mg-smash-copter"
const CHECKS := 31


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("mg-smash-copter: config binder")
	var config := ScConfig.new()
	var binder := ScConfig.make_binder(config)
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	for k in ["survival_seconds", "platform_stiffness", "cannon_interval", "friendly_fire", "impact_min_speed", "impact_loss",
			"impact_hurt_radius", "impact_hurt_per_impulse", "fall_gravity_scale", "fall_tip_rate", "death_cam_seconds", "freeze_cam_seconds"]:
		_check(keys.has(k), "%s is exposed" % k)

	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	console.set_cvar("sc_impact_hurt_radius", "0.6")
	_check(is_equal_approx(config.impact_hurt_radius, 0.6) and binder.source_of("impact_hurt_radius") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("impact_hurt_radius: 0.6"), "the diff names the edit")
	var schema_path := "user://sc_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	var bad := FileAccess.open("user://sc_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := ScConfig.make_binder(ScConfig.new(), "user://sc_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute("user://sc_config_bad.json")

	var shipped := "res://cfg/game/%s/config_cannon/game.yml" % GAME
	var kept := FileAccess.get_file_as_string(shipped)
	DirAccess.make_dir_recursive_absolute(shipped.get_base_dir())
	var yml := FileAccess.open(shipped, FileAccess.WRITE)
	yml.store_string("cannon_interval: 2.5\n")
	yml.close()
	var loaded := ScConfig.new()
	var from_yml := ScConfig.make_binder(loaded)
	from_yml.strict = true
	var got := from_yml.load_layers()
	_check(got.ok and is_equal_approx(loaded.cannon_interval, 2.5) and from_yml.source_of("cannon_interval") != "default",
		"an exported cfg/game/<game>/config_cannon/game.yml loads back as defaults", "" if got.ok else got.error.message)
	yml = FileAccess.open(shipped, FileAccess.WRITE)
	yml.store_string(kept)
	yml.close()

	_layers()
	_templates(binder)

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for pset: DotProfileSet in binder.profile_sets():
		wb.add_set(pset, pset.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var lg: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if lg.ok:
			listed.append_array(PackedStringArray((lg.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 3, "the workbench lists all %d keys over %d files" % [keys.size(), binder.profile_sets().size()], ",".join(missing))
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_round", "id": binder.profile_id, "key": "impact_loss", "value": 0.3})
	_check(res.ok and is_equal_approx(config.impact_loss, 0.3), "a workbench edit reaches the live config", "" if res.ok else res.error.message)
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/%s/config_round/game.yml" % GAME, "")
	_check(text.contains("impact_loss: 0.3"), "the export holds the edit in the cfg layout")

	wb.free()
	console.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _write_root(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := ScConfig.new()
	var binder := ScConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s surv=%s surv_src=%s cols=%s cols_src=%s cvar=%s cannon=%s cannon_src=%s grav=%s grav_src=%s" % [
		loaded.ok, config.survival_seconds, binder.source_of("survival_seconds"), config.columns, binder.source_of("columns"),
		console.find_cvar("sc_columns").get_string(), config.cannon_interval, binder.source_of("cannon_interval"),
		config.gravity, binder.source_of("gravity")])
	get_tree().quit(0)


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--sc-cannon-interval=3.5", "--sc-gravity=15.0"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write_root("game/%s/config_round/game.yml" % GAME, "survival_seconds: 200.0\n")
	_write_root("game/%s/config_floor/game.yml" % GAME, "columns: 6\n")
	OS.set_environment("SC_COLUMNS", "7")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process", text.right(300))
	_check(text.contains("surv=200") and text.contains("surv_src=yml"), "a cfg file reaches the live config")
	_check(text.contains("cols=7") and text.contains("cols_src=env") and text.contains("cvar=7"), "the environment beats the file and reaches the cvar")
	_check(text.contains("cannon=3.5") and text.contains("cannon_src=argv"), "argv alone reaches the config")
	_check(text.contains("grav=15") and text.contains("grav_src=argv"), "a second argv flag reaches it too")
	OS.unset_environment("SC_COLUMNS")
	_write_root("game/%s/config_round/game.yml" % GAME, "cannon_interval: 2.0\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/config_round/game.yml" % GAME)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/config_floor/game.yml" % GAME)))


## The shipped cfg files hold every key, in step with ScConfig, and change nothing as they are.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 3, "three shipped cfg files", str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd)", ",".join(stale))
