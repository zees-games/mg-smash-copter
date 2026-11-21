extends GSGameCheckSuite

## The phone's on-screen buttons: the layout fits phone screens, each button reaches its handler, jump reaches the sampler.
##
## Run: `./game.sh test headless_touch`

const ScTouch := preload("../game/sc_touch.gd")
const CHECKS := 29
const SECTIONS := 1

var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-smash-copter: touch buttons")
	_entered += 1
	await _touch_buttons()
	_finished += 1
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


func _touch_buttons() -> void:
	var list := ScTouch.touch_layout().buttons()
	var ids: Array = list.map(func(b: Dictionary) -> Variant: return b["id"])
	for want: StringName in [ScTouch.FIRE, ScTouch.ALT, ScTouch.JUMP, ScTouch.CROUCH, ScTouch.USE, ScTouch.RELOAD, ScTouch.PREV, ScTouch.NEXT, ScTouch.BOARD, ScTouch.CHAT]:
		_check(ids.has(want), "the layout has the %s button" % want)
	var probe := GSTouchButtons.new()
	var m := probe.margin
	probe.free()
	for size: Vector2 in [Vector2(667, 375), Vector2(844, 390), Vector2(932, 430)]:
		var clear := true
		var inside := true
		for i in list.size():
			var a: Vector2 = size - Vector2(m, m) - (list[i]["offset"] as Vector2)
			var ra: float = list[i]["radius"]
			inside = inside and a.x - ra >= size.x * 0.5 and a.y - ra >= 0.0 and a.x + ra <= size.x and a.y + ra <= size.y
			for j in range(i + 1, list.size()):
				var b: Vector2 = size - Vector2(m, m) - (list[j]["offset"] as Vector2)
				clear = clear and a.distance_to(b) >= ra + float(list[j]["radius"])
		_check(inside, "every button sits in the right half at %dx%d" % [size.x, size.y])
		_check(clear, "and no two overlap at %dx%d" % [size.x, size.y])
	_check(ScTouch.layout().size() == list.size(), "dot-mobile gets every button of the preset")
	var held := {}
	for row in ScTouch.layout():
		held[row["id"]] = int(row.get("hold", 0))
	_check(held[ScTouch.JUMP] == GSFpsCommand.BUTTON_JUMP and held[ScTouch.CROUCH] == GSFpsCommand.BUTTON_CROUCH, "jump and crouch hold their bits on the sampler")
	await _overlay()
	var kb := ScTouch.make_sampler(GSFpsTunables.new())
	_check(not GSPlatform.has_touch() and not kb is GSFpsTouchSampler, "no touch device gets the keyboard sampler")
	_check(ids.size() == list.size(), "every button id is unique")


## dot-mobile's overlay on the client's own sampler, built the way the client builds it (a Node host, the overlay on its own CanvasLayer).
func _overlay() -> void:
	var state: Node = (load("res://game/sc_game_state.gd") as GDScript).new()
	var rules: GSMobileRules = state.mobile_rules
	_check(rules.autofire == GSMobileRules.OFF and rules.aim_assist == GSMobileRules.OFF, "auto-fire and aim assist are off by default", "%d %d" % [rules.autofire, rules.aim_assist])
	GSPlatform.touch_override = 1
	var host := Node.new()
	add_child(host)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var got: Array = []
	var handlers := {}
	for id: StringName in [ScTouch.FIRE, ScTouch.USE, ScTouch.BOARD]:
		handlers[id] = func(down: bool) -> void: got.append([id, down])
	var touch := ScTouch.new()
	var controls := touch.build(host, sampler, rules, handlers)
	await get_tree().process_frame
	_check(controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	_check(touch.buttons == controls.buttons and controls.buttons.size.x > 0.0, "the buttons have a size", str(controls.buttons.size))
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(touch.takes(tap) and touch.takes(fake), "it takes touches and the mouse emulated from them")
	_finger(controls, ScTouch.FIRE, true)
	_finger(controls, ScTouch.FIRE, false)
	_finger(controls, ScTouch.USE, true)
	_check(got == [[ScTouch.FIRE, true], [ScTouch.FIRE, false], [ScTouch.USE, true]], "a press and a release reach the game's handlers", str(got))
	_finger(controls, ScTouch.JUMP, true)
	_check(controls.is_held(ScTouch.JUMP) and sampler.sample(0.016).buttons & GSFpsCommand.BUTTON_JUMP != 0, "jump is held on the sampler")
	_finger(controls, ScTouch.JUMP, false)
	_check(sampler.sample(0.016).buttons & GSFpsCommand.BUTTON_JUMP == 0, "and let go with the thumb")
	var other := GSFpsTouchSampler.new(GSFpsTunables.new())
	touch.sync(other, true, true)
	_check(controls.sampler == other and not touch.active(), "the overlay follows the sampler in use and a menu pauses it")
	touch.sync(other, false, true)
	_check(touch.active(), "and closing the menu brings it back")
	host.free()
	state.free()
	GSPlatform.touch_override = -1


var _next_finger := 10


## A finger down on, or up from, the middle of a button; the finger is the one last put down.
func _finger(controls: GSMobileControls, id: StringName, down: bool) -> void:
	if down:
		_next_finger += 1
	var ev := InputEventScreenTouch.new()
	ev.index = _next_finger
	ev.pressed = down
	ev.position = controls.buttons.centre_of(id)
	controls.buttons._input(ev)
