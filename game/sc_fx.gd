extends Node

## What a client draws that nothing simulates: splinters where a crate or cone breaks.

const ScContent := preload("sc_content.gd")

## Dot-fx's break effect. Its own crack stays on: nothing else in this game sounds a break.
var break_fx: DotFxBreak = null

var _world: Node = null


## Builds the effect and listens to [param world]'s `shattered`, offline. Online, call [method on_shatter] from the bridge.
func setup(world: Node) -> DotResult:
	_world = world
	break_fx = DotFxBreak.new()
	break_fx.name = "Break"
	add_child(break_fx)

	if world != null and world.has_signal("shattered"):
		world.connect("shattered", on_shatter)

	return DotResult.success(self)


## One burst for a break at [param at]; [param material] indexes [constant ScContent.BREAK_MATERIALS].
func on_shatter(at: Vector3, material: int) -> void:
	if break_fx == null or material < 0 or material >= ScContent.BREAK_MATERIALS.size():
		return

	var _b := break_fx.burst(ScContent.BREAK_MATERIALS[material], at, Vector3.UP, 1.0)


func describe() -> Dictionary:
	return {"breaks": break_fx.spawned if break_fx != null else 0}
