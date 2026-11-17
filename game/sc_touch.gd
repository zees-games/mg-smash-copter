extends RefCounted

## The phone's controls: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's own [DotFpsTouchSampler].
## The buttons are the ones this game always had (dot-game's fps preset, the use button labelled E): fire and alt-fire (in the chopper's seat, the same two),
## jump/up, crouch/down, get in or out of the chopper, reload, the showdown's weapon arrows, the held scoreboard and chat.
## Auto-fire and aim assist are dot-mobile's and stay off: this is a team game of platforms where a gun is only the last round's, so the overlay is given no crosshair query.

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


## The preset's rows for [DotMobileControls.setup]: jump and crouch hold their command bit on the sampler.
static func layout() -> Array[Dictionary]:
	var rows := touch_layout().buttons()
	for row in rows:
		if row["id"] == JUMP:
			row["hold"] = DotFpsCommand.BUTTON_JUMP
		elif row["id"] == CROUCH:
			row["hold"] = DotFpsCommand.BUTTON_CROUCH
	return rows


var controls: DotMobileControls = null
## dot-ui's buttons inside the overlay, for the shell's DPI fit.
var buttons: DotTouchButtons:
	get:
		return controls.buttons if controls != null else null

var _handlers: Dictionary = {}


## Builds the overlay on a CanvasLayer under [param parent] (a HUD layer is not a Control, and the overlay needs a size), following [param rules] (the server's). [param handlers] is button id to a Callable taking `down: bool`, for every button but jump and crouch (the sampler's). [param ignore_fn] keeps a finger on the menu button off the sticks. [param client] fits the buttons to the screen when it can.
func build(parent: Node, sampler: DotFpsSampler, rules: DotMobileRules, handlers: Dictionary, ignore_fn: Callable = Callable(), client: Object = null) -> DotMobileControls:
	_handlers = handlers
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	if ignore_fn.is_valid():
		controls.ignore_fn = ignore_fn
	controls.setup(sampler, layout())
	controls.button_pressed.connect(func(id: StringName) -> void: _route(id, true))
	controls.button_released.connect(func(id: StringName) -> void: _route(id, false))
	var layer := CanvasLayer.new()
	layer.name = "TouchLayer"
	layer.add_child(controls)
	parent.add_child(layer)
	if client != null and client.has_method(&"fit_touch_buttons") and controls.buttons != null:
		client.call(&"fit_touch_buttons", controls.buttons, layout())
	return controls


func _route(id: StringName, down: bool) -> void:
	if _handlers.has(id):
		(_handlers[id] as Callable).call(down)


## Called every frame by the client: follows the sampler in use (the player's own offline, the client's online), and pauses under a menu, the console, typing or the load gate.
func sync(sampler: DotFpsSampler, busy: bool, live: bool) -> void:
	if controls == null:
		return
	if sampler != null and sampler != controls.sampler:
		controls.setup(sampler, layout())
	controls.paused = busy
	controls.live_fn = func() -> bool: return live


## True when the overlay forwards [param event] itself, or [param event] is the mouse Godot emulates from a touch, which would turn the view a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


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
