extends DotLoadProbe

## The load probe: dot-game's [DotLoadProbe] on this game's offline solo client, with the phase and tick
## column(s) before player/cam/hud. Needs xvfb-run, never --headless:
##   xvfb-run -a godot --path . res://tools/load_probe.tscn -- [--frames=90] [--shot=N]
const ScClient := preload("../game/sc_client.gd")


func _make_client() -> Node:
	var c := ScClient.new()
	c.set("force_offline", true)
	return c


func _columns(gate: Object) -> String:
	return "phase=%s tick=%s %s" % [client.get("game").phase, client.get("game").get("_tick"), super(gate)]
