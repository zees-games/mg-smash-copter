extends RefCounted

## The on-screen buttons a phone needs for this game: fire and alt-fire (in the chopper's seat, the same two),
## jump/up, crouch/down, get in or out of the chopper, reload, the showdown's weapon arrows, the held scoreboard and chat.
## The look and move halves of the screen are [DotFpsTouchSampler]'s; [member buttons] tells it where a button is.

const FIRE := &"fire"
const ALT := &"alt"
const JUMP := &"jump"
const DUCK := &"duck"
const USE := &"use"
const RELOAD := &"reload"
const PREV := &"prev"
const NEXT := &"next"
const BOARD := &"board"
const CHAT := &"chat"

## Offsets are from the bottom-right corner towards the middle; small enough for a 375 px tall screen.
static func layout() -> Array[Dictionary]:
	return [
		{"id": FIRE, "label": "FIRE", "offset": Vector2(80, 84), "radius": 44.0},
		{"id": ALT, "label": "ALT", "offset": Vector2(190, 60), "radius": 30.0},
		{"id": JUMP, "label": "JUMP", "offset": Vector2(80, 172), "radius": 32.0},
		{"id": DUCK, "label": "DUCK", "offset": Vector2(262, 60), "radius": 28.0},
		{"id": USE, "label": "E", "offset": Vector2(190, 150), "radius": 26.0},
		{"id": RELOAD, "label": "R", "offset": Vector2(262, 128), "radius": 22.0},
		{"id": PREV, "label": "<", "offset": Vector2(138, 246), "radius": 22.0},
		{"id": NEXT, "label": ">", "offset": Vector2(80, 246), "radius": 22.0},
		{"id": BOARD, "label": "TAB", "offset": Vector2(196, 246), "radius": 22.0},
		{"id": CHAT, "label": "CHAT", "offset": Vector2(254, 246), "radius": 22.0},
	]

var buttons: DotTouchButtons = null


## Builds the buttons on a CanvasLayer under [param parent] (a HUD layer is not a Control, and the buttons need a size) and routes them: jump and duck to the sampler (read through the callable, the active one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Node, sampler_fn: Callable, handlers: Dictionary) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout())
	var layer := CanvasLayer.new()
	layer.name = "TouchLayer"
	layer.add_child(buttons)
	parent.add_child(layer)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == DUCK:
		var sampler: Variant = sampler_fn.call() if sampler_fn.is_valid() else null
		if sampler != null and sampler.has_method(&"hold"):
			var bit := DotFpsCommand.BUTTON_JUMP if id == JUMP else DotFpsCommand.BUTTON_CROUCH
			sampler.call(&"hold", bit, down)
		return
	if handlers.has(id):
		(handlers[id] as Callable).call(down)


## A touch sampler where a phone is, the keyboard one otherwise; [param ignore_fn] keeps a button's finger off the stick (it may be assigned later); the caller registers the actions.
static func make_sampler(tunables: DotFpsTunables, ignore_fn: Callable = Callable()) -> DotFpsSampler:
	var sampler: DotFpsSampler
	if DotPlatform.has_touch():
		var touch := DotFpsTouchSampler.new(tunables)
		touch.ignore_fn = ignore_fn
		sampler = touch
	else:
		sampler = DotFpsSampler.new(tunables)
	return sampler
