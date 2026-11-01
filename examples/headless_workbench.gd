extends DotGameWorkbenchSuite

## mg-smash-copter: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const ScConfig := preload("../game/sc_config.gd")


func _make_config() -> DotConfig:
	return ScConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return ScConfig.make_binder(config)
