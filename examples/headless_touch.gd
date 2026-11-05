extends DotGameCheckSuite

## The phone's on-screen buttons: the layout fits phone screens, each button reaches its handler, jump reaches the sampler.
##
## Run: `./game.sh test headless_touch`

const ScTouch := preload("../game/sc_touch.gd")
const CHECKS := 21
const SECTIONS := 1

var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-smash-copter: touch buttons")
	_entered += 1
	await _touch_buttons()
	_finished += 1
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


func _touch_buttons() -> void:
	var list := ScTouch.layout()
	var ids: Array = list.map(func(b: Dictionary) -> Variant: return b["id"])
	for want: StringName in [ScTouch.FIRE, ScTouch.ALT, ScTouch.JUMP, ScTouch.DUCK, ScTouch.USE, ScTouch.RELOAD, ScTouch.PREV, ScTouch.NEXT, ScTouch.BOARD, ScTouch.CHAT]:
		_check(ids.has(want), "the layout has the %s button" % want)
	var probe := DotTouchButtons.new()
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
	var got: Array = []
	var handlers := {}
	for id: StringName in [ScTouch.USE, ScTouch.BOARD]:
		handlers[id] = func(down: bool) -> void: got.append([id, down])
	ScTouch.route(ScTouch.USE, true, Callable(), handlers)
	ScTouch.route(ScTouch.BOARD, false, Callable(), handlers)
	_check(got == [[ScTouch.USE, true], [ScTouch.BOARD, false]], "a press and a release reach their handlers", str(got))
	var sampler := DotFpsTouchSampler.new(DotFpsTunables.new())
	ScTouch.route(ScTouch.JUMP, true, func() -> Variant: return sampler, handlers)
	_check(sampler._held == DotFpsCommand.BUTTON_JUMP, "jump is held on the sampler")
	var host := Node.new()
	add_child(host)
	var touch := ScTouch.new()
	var built := touch.build(host, Callable(), handlers)
	await get_tree().process_frame
	_check(touch.buttons == built and built.size.x > 0.0, "build gives the buttons a size", str(built.size))
	host.free()
	var kb := ScTouch.make_sampler(DotFpsTunables.new())
	_check(not DotPlatform.has_touch() and not kb is DotFpsTouchSampler, "no touch device gets the keyboard sampler")
	_check(ids.size() == list.size(), "every button id is unique")
