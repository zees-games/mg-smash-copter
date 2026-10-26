extends SceneTree

## Rewrites cfg/game/mg-smash-copter/config_*/game.yml from ScConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const ScConfig := preload("../game/sc_config.gd")


func _init() -> void:
	var binder := ScConfig.make_binder(ScConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
