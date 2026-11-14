extends RefCounted

## The on-screen buttons a phone needs for this game: fire and alt-fire (in the chopper's seat, the same two),
## jump/up, crouch/down, get in or out of the chopper, reload, the showdown's weapon arrows, the held scoreboard and chat.
## The look and move halves of the screen are [DotFpsTouchSampler]'s; [member buttons] tells it where a button is.

const FIRE := DotGameTouchLayout.FIRE
const ALT := DotGameTouchLayout.ALT
const JUMP := DotGameTouchLayout.JUMP
const CROUCH := DotGameTouchLayout.CROUCH
const USE := DotGameTouchLayout.USE
const RELOAD := DotGameTouchLayout.RELOAD
const PREV := DotGameTouchLayout.PREV
const NEXT := DotGameTouchLayout.NEXT
const BOARD := DotGameTouchLayout.BOARD
const CHAT := DotGameTouchLayout.CHAT

## dot-game's fps preset with the use button labelled E, as the keyboard key is.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {USE: {"slot": &"inner", "label": "E"}})
	if not res.ok:
		push_error("mg-smash-copter touch layout refused: %s" % str(res.error))
		return DotGameTouchLayout.custom()
	return res.value

var buttons: DotTouchButtons = null


## Builds the buttons on a CanvasLayer under [param parent] (a HUD layer is not a Control, and the buttons need a size) and routes them: jump and crouch to the sampler (read through the callable, the active one changes on JOIN), the rest to [param handlers], button id to a Callable taking `down: bool`.
func build(parent: Node, sampler_fn: Callable, handlers: Dictionary, client: Object = null) -> DotTouchButtons:
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout().apply(buttons, client)
	var layer := CanvasLayer.new()
	layer.name = "TouchLayer"
	layer.add_child(buttons)
	parent.add_child(layer)
	buttons.button_down.connect(func(id: StringName) -> void: route(id, true, sampler_fn, handlers))
	buttons.button_up.connect(func(id: StringName) -> void: route(id, false, sampler_fn, handlers))
	return buttons


static func route(id: StringName, down: bool, sampler_fn: Callable, handlers: Dictionary) -> void:
	if id == JUMP or id == CROUCH:
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
