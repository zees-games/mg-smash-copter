extends Node

const ScPlayer := preload("sc_player.gd")

## The killcam at a round's end. Client side: every frame drawn goes into dot-replay's
## [DotKillcamBuffer], every decisive moment (a death, a finish) is noted, and when the round
## ends on one, [DotKillcam] replays it from the eyes of the player it happened to.
## The length is `mp_killcam_time`; 0 skips straight to [signal over].

const CHANNEL := "smashcopter.killcam"

## Skip keys: jump, the use key and Escape.
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "ui_cancel"]

## The killcam is over (or never began); the end-of-round flow goes on from here.
signal over(skipped: bool)

## Every ScPlayer to record, this frame.
var players_fn: Callable = Callable()

## `func(key: StringName) -> ScPlayer` or null.
var player_for_fn: Callable = Callable()

## `func(p: ScPlayer) -> Vector3`: where this frame draws the player's feet.
var feet_fn: Callable = Callable()

## `func(p: ScPlayer) -> Color`: the colour of the player's side.
var colour_fn: Callable = func(_p: Node) -> Color: return Color.WHITE

## The killcam's length in seconds; 0 disables.
var seconds_fn: Callable = func() -> float: return 7.0

## Seconds, monotonic. Injected by a test.
var now_fn: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

## Nodes hidden while the replay runs (the HUD): anything with `visible`.
var hide_while_playing: Array = []

var buffer := DotKillcamBuffer.new()
var killcam: DotKillcam = null
var camera: Camera3D = null

var _previous_camera: Camera3D = null
var _touched: Dictionary = {}
var _hidden: Dictionary = {}


func _ready() -> void:
	killcam = DotKillcam.new()
	killcam.name = "Killcam"
	killcam.skip_actions = SKIP_ACTIONS
	add_child(killcam)
	killcam.started.connect(_on_started)
	killcam.frame_drawn.connect(_apply)
	killcam.finished.connect(_on_finished)
	camera = Camera3D.new()
	camera.name = "KillcamCamera"
	add_child(camera)


func is_playing() -> bool:
	return killcam != null and killcam.is_active()


## Records this frame, once a frame after every body is presented; while the replay runs it
## re-applies the replayed frame instead, over what presentation just drew.
func frame() -> void:
	if is_playing():
		if killcam.state == DotKillcam.State.WAITING:
			_record()
		return
	_record()


## A moment worth replaying: [param subject] is whose eyes the replay is behind, [param what]
## the banner's words ("reached the end", "caught by a trap"), [param victim] the one a shot
## put down or "".
func note_moment(subject: StringName, what: String, victim: String = "") -> void:
	buffer.note_event(now_fn.call(), &"moment", {"subject": String(subject), "what": what, "victim": victim})


## The round ended: replay its last moment if there is one to show. False means [signal over]
## has already been emitted and nothing will play.
func round_ended() -> bool:
	if killcam == null or is_playing():
		return is_playing()
	killcam.max_seconds = maxf(float(seconds_fn.call()), 0.0)
	var moment := buffer.last_event(&"moment")
	var subject: Node = _player(StringName(String(moment["data"].get("subject", "")))) if not moment.is_empty() else null
	if not killcam.enabled() or subject == null:
		over.emit(false)
		return false
	var played := killcam.play(buffer, moment, {
		"title": "THE LAST MOMENT",
		"killer": String(subject.get(&"display_name")),
		"victim": String(moment["data"].get("victim", "")),
		"weapon": String(moment["data"].get("what", "")),
		"hint": "Jump to skip",
	})
	if not played.ok:
		DotLog.debug(CHANNEL, "no killcam", {"why": played.error.message})
		over.emit(false)
		return false
	return true


func skip() -> void:
	if killcam != null:
		killcam.skip()


func _player(key: StringName) -> Node:
	if key == &"" or not player_for_fn.is_valid():
		return null
	var p: Variant = player_for_fn.call(key)
	return p as Node if p is Node and is_instance_valid(p) else null


func _record() -> void:
	if not players_fn.is_valid():
		return
	var shot := {}
	for p: Node in players_fn.call():
		var row := _state_of(p)
		if not row.is_empty():
			shot[String(p.get(&"player_id"))] = row
	var _kept := buffer.push_frame(now_fn.call(), shot)


# [feet, yaw, pitch, alive, ground speed]: where the body was drawn, not where the tick put it.
func _state_of(p: Node) -> Array:
	var controller: Object = p.get(&"controller")
	if controller == null or not feet_fn.is_valid():
		return []
	var st: DotFpsState = controller.get(&"state")
	var speed := Vector2(st.velocity.x, st.velocity.z).length()
	return [feet_fn.call(p), st.yaw, st.pitch, bool(p.call(&"is_alive")), speed]


func _on_started(_kill: Dictionary) -> void:
	_previous_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _previous_camera != null and _previous_camera != camera:
		camera.fov = _previous_camera.fov
		camera.cull_mask = _previous_camera.cull_mask
	camera.make_current()
	for n: Variant in hide_while_playing:
		if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
			_hidden[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)
	DotLog.info(CHANNEL, "round killcam", killcam.describe())


func _apply(s: Dictionary) -> void:
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	var subject := String(killcam.kill()["data"].get("subject", ""))
	if not camera.current:
		camera.make_current()
	for id: Variant in b:
		var p := _player(StringName(String(id)))
		if p == null:
			continue
		var rb: Array = b[id]
		var ra: Array = a.get(id, rb)
		var feet: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var yaw := rad_to_deg(lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
		var pitch := lerpf(ra[2], rb[2], alpha)
		var alive: bool = rb[3] if alpha >= 0.5 else ra[3]
		if String(id) == subject:
			camera.global_position = feet + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0)
			camera.global_rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)
			_place_body(p, feet, yaw, false, 0.0, 0.0)
		else:
			_place_body(p, feet, yaw, alive, pitch, lerpf(ra[4], rb[4], alpha))


func _place_body(p: Node, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float) -> void:
	var figure: Node3D = p.get(&"figure")
	if figure == null and shown:
		# Builds the figure the way a normal frame would, then this frame's pose overrides it.
		var _built: Variant = p.call(&"present_body", false, feet, colour_fn.call(p))
		figure = p.get(&"figure")
	if figure == null:
		return
	if not _touched.has(p):
		_touched[p] = [figure.transform, figure.visible]
	figure.visible = shown
	if not shown:
		return
	figure.call(&"set_motion", {"on_floor": true, "aim": deg_to_rad(pitch)})
	figure.call(&"pose", feet, deg_to_rad(yaw), speed)


func _on_finished(skipped: bool) -> void:
	for p: Variant in _touched:
		if is_instance_valid(p):
			var figure: Node3D = (p as Node).get(&"figure")
			if figure != null:
				figure.transform = _touched[p][0]
				figure.visible = _touched[p][1]
	_touched.clear()
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe_lines() -> PackedStringArray:
	var out := buffer.describe_lines()
	if killcam != null:
		out.append_array(killcam.describe_lines())
	return out
