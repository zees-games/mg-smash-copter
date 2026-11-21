extends GSGameVisualQaCapture

## Smash Copter's visual QA capture (docs/testing.md; the loop is gs-game's docs/visual-qa.md). Four kinds of item, each
## recorded frame by frame at --fps in three views (f first person, t behind-right, o an opponent in front):
##   person_<letter>  one of the six people (ScFigure) standing, walking, running, jumping.
##   weapon_<id>      a weapon the server deals: f is the real view model (ZeeViewModel with its arms) at the eye, t and o
##                    draw the person holding it (ScFigure.hold) through draw, fire and reload.
##   copter           the chopper parked with its rotor idling, and flying nose-down; f is the pilot's seat.
##   prop_<id>        a prop the cannon throws, on a turntable, one full turn in two seconds.

const ScFigure := preload("../game/sc_figure.gd")
const ScContent := preload("../game/sc_content.gd")
const ScGameFlow := preload("../game/sc_game_flow.gd")
const ScPlayer := preload("../game/sc_player.gd")

## Your own body draws only in the outside views; the view model (ZeeViewModel's view_layer 20) only in the first-person one.
const BODY_LAYER := 1 << 18
const ALL_LAYERS := 0xFFFFF
const BODY_HEIGHT := 1.8
## The client camera's base_fov (sc_client_state.gd), so the view model is framed as a player sees it.
const GAME_FOV := 92.0
const STAGE_FOV := 75.0
const PERSON_CLIPS: PackedStringArray = ["idle", "walk", "run", "jump"]
const WEAPON_CLIPS: PackedStringArray = ["idle", "draw", "fire", "reload"]
const COPTER_CLIPS: PackedStringArray = ["idle", "fly"]
## Ground speed per person clip (metres a second): ScConfig run 6.4, walking 0.42 of it.
const PERSON_SPEED := {"idle": 0.0, "walk": 2.7, "run": 6.4, "jump": 2.7}
## A jump as the controller makes it: 1.15 m high under 20 m/s^2, so 6.8 m/s up and 0.68 s in the air, once a second.
const JUMP_HEIGHT := 1.15
const JUMP_AIR := 0.68
const SECONDS := {"idle": 2.0, "walk": 2.4, "run": 2.0, "jump": 2.0, "draw": 1.0, "fire": 2.0, "reload": 3.0, "turntable": 2.0, "fly": 3.0}
## Seconds between shots in the fire clip when a weapon has no use interval; otherwise its own, as in a match.
const FIRE_EVERY := 0.5
## bone_pop limit in a fire clip whose arm swings: a real strike turns the forearm about 1700 deg/s.
const STRIKE_POP_DEG := 130.0
const PROPS: PackedStringArray = ["crate", "tyre", "cone", "barrel", "boulder", "container", "slab", "monolith"]
const COPTER_SPEED := 12.0
const COPTER_ALTITUDE := 5.0
const COPTER_PITCH := -0.14
## The pilot's eye above the seat marker.
const PILOT_EYE := Vector3(0.0, 0.7, 0.0)

var _figure: ScFigure = null
var _model: ZeeViewModel = null
var _body: RigidBody3D = null
var _holder := Node3D.new()
var _shown_kind := ""
var _shown_id := ""
var _shots_done := 0
var _weapon_defs := {}
var _rest_y := 0.0
var _prop_height := 1.0
var _prop_away := 2.5
var _struck := false


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for path in ScFigure.ATLASES:
		items.append("person_" + path.get_file().get_basename().trim_prefix("texture-"))
	for def in ZeeWeaponPack.weapons():
		_weapon_defs[String(def.id)] = def
	for id in ScGameFlow.default_weapon_pool():
		items.append("weapon_" + String(id))
	items.append("copter")
	for id in PROPS:
		items.append("prop_" + id)
	return items


func _clips(item: String) -> PackedStringArray:
	if item.begins_with("person_"):
		return PERSON_CLIPS
	if item.begins_with("weapon_"):
		return WEAPON_CLIPS
	if item == "copter":
		return COPTER_CLIPS
	return PackedStringArray(["turntable"])


func _seconds(_item: String, clip: String) -> float:
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	build_stage()
	first_person.cull_mask = ALL_LAYERS & ~BODY_LAYER
	root.add_child(_holder)


func _stage(item: String, clip: String) -> GSResult:
	_clear()
	first_person.fov = STAGE_FOV
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	views.opponent_offset = Vector3(0.4, 1.6, -4.0)
	views.opponent_look_height = 1.3
	_shown_id = item
	if item.begins_with("person_"):
		_shown_kind = "person"
		_stand_person(item.trim_prefix("person_"), Color(0.3, 0.45, 0.9))
	elif item.begins_with("weapon_"):
		return _stage_weapon(StringName(item.trim_prefix("weapon_")), clip)
	elif item == "copter":
		_shown_kind = "copter"
		var made := _make_body(String(ScContent.COPTER_SCENE))
		if not made.ok:
			return made
		_body.freeze = clip != "fly"
		_body.custom_integrator = true
		# Already at speed: the spin-up from idle is a second of the clip spent on nothing.
		if clip == "fly":
			_body.set(&"_rotor_speed", 40.0)
		views.behind_offset = Vector3(7.0, 4.0, 13.0)
		views.behind_look_height = 0.0
		views.opponent_offset = Vector3(4.0, 2.5, -13.0)
		views.opponent_look_height = 0.0
	else:
		var id := item.trim_prefix("prop_")
		var path := _prop_scene(id)
		if path == "":
			return GSResult.fail(GSError.CODE_INVALID, "no prop %s" % id)
		_shown_kind = "prop"
		var made := _make_body(path)
		if not made.ok:
			return made
		_body.freeze = true
		_frame_prop(_bounds(_body).size)
	return GSResult.success(clip)


func _stage_weapon(id: StringName, clip: String) -> GSResult:
	var art: Variant = ZeeWeaponArtTable.table().get(id)
	if not (art is ZeeWeaponArt):
		return GSResult.fail(GSError.CODE_INVALID, "no art for %s" % id)
	var def: GSWeaponDef = _weapon_defs.get(String(id))
	if clip == "reload" and (def == null or not def.uses_magazine()):
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "%s has no magazine" % id)
	_shown_kind = "weapon"
	first_person.fov = GAME_FOV
	# Straight ahead, a held gun points down the lens and draws as a thin stick; from the gun-hand side it reads in profile.
	views.behind_offset = Vector3(2.4, 1.5, 2.2)
	views.opponent_offset = Vector3(3.0, 1.3, -2.2)
	views.opponent_look_height = 1.0
	_stand_person("a", Color(0.9, 0.35, 0.3))
	_figure.hold(id, false)
	_model = ZeeViewModel.new()
	_model.name = "ViewModel"
	first_person.add_child(_model)
	_model.set_process(false)
	var equipped := _model.equip(art as ZeeWeaponArt)
	if not equipped.ok:
		return equipped
	_model.on_deploy(1.0)
	_shots_done = 0
	_struck = false
	return GSResult.success(clip)


## The scene a prop id is thrown as, rebased the way the game loads it.
func _prop_scene(id: String) -> String:
	match id:
		"crate": return ScContent.CRATE_SCENE
		"tyre": return ScContent.TYRE_SCENE
		"cone": return ScContent.CONE_SCENE
		"barrel": return ScContent.BARREL_SCENE
		"boulder": return ScContent.BOULDER_SCENE
		"container": return ScContent.CONTAINER_SCENE
		"slab": return ScContent.SLAB_SCENE
		"monolith": return ScContent.MONOLITH_SCENE
	return ""


func _make_body(path: String) -> GSResult:
	var scene := load(path) as PackedScene
	if scene == null:
		return GSResult.fail(GSError.CODE_IO, "%s would not load" % path)
	_body = scene.instantiate() as RigidBody3D
	if _body == null:
		return GSResult.fail(GSError.CODE_INVALID, "%s is not a RigidBody3D" % path)
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_holder.add_child(_body)
	_body.global_position = Vector3.ZERO
	# Resting on the floor by its drawn lowest point, as it lands in a round.
	_rest_y = -_bounds(_body).position.y
	_body.global_position = Vector3(0.0, _rest_y, 0.0)
	return GSResult.success(_body)


## Cameras that fit the prop: a cone and a container are not one size, so the distance and look height follow it.
func _frame_prop(size: Vector3) -> void:
	var reach := maxf(size.y, maxf(size.x, size.z))
	var away := reach * 1.6
	_prop_height = size.y
	_prop_away = away
	var base := -_rest_y
	views.behind_offset = Vector3(away * 0.45, base + size.y * 0.7 + reach * 0.15, away)
	views.behind_look_height = base + size.y * 0.5
	views.opponent_offset = Vector3(away * 0.15, base + size.y * 0.6 + reach * 0.15, -away)
	views.opponent_look_height = base + size.y * 0.5


func _stand_person(letter: String, colour: Color) -> void:
	_figure = ScFigure.new()
	_figure.name = "Figure"
	_holder.add_child(_figure)
	_figure.global_position = Vector3.ZERO
	_figure.build(BODY_HEIGHT, _atlas_of(letter), colour)


func _atlas_of(letter: String) -> String:
	for path in ScFigure.ATLASES:
		if path.ends_with("texture-%s.png" % letter):
			return path
	return ScFigure.ATLASES[0]


func _clear() -> void:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.free()
	if _model != null and is_instance_valid(_model):
		first_person.remove_child(_model)
		_model.free()
	_model = null
	_figure = null
	_body = null


func _subject(_item: String) -> Node3D:
	return _figure if _figure != null else _body


func _drive(item: String, clip: String, t: float, _frame: int) -> void:
	var step := 1.0 / float(fps)
	if _shown_kind == "prop":
		_body.rotation.y = TAU * t / float(SECONDS["turntable"])
		return
	if _shown_kind == "copter":
		_drive_copter(clip, t)
		return
	var speed := float(PERSON_SPEED.get(clip, 0.0))
	var airborne := false
	var vertical := 0.0
	if clip == "jump":
		var phase := fmod(t, 1.0) / JUMP_AIR
		airborne = phase < 1.0
		var up := 4.0 * JUMP_HEIGHT / JUMP_AIR
		vertical = up * (1.0 - 2.0 * phase) if airborne else 0.0
		_figure.global_position.y = 4.0 * JUMP_HEIGHT * phase * (1.0 - phase) if airborne else 0.0
	_figure.set_motion({"on_floor": not airborne, "vertical": vertical, "crouched": false,
		"sprinting": clip == "run", "aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.global_position.z = -speed * t + (speed * float(SECONDS.get(clip, 2.0)) * 0.5)
	_figure.global_position.x = 0.0
	_figure.rotation = Vector3.ZERO
	_figure.person.animate(speed, step)
	_figure.clip = _figure.person.clip
	if _shown_kind == "weapon":
		_drive_weapon(clip, t, step)


## Parked, the rotor idles on the skids. Flying, it crosses the stage nose-down at speed with a gentle bank, which is
## what spins the rotor up (ScCopterBody reads the body's velocity).
func _drive_copter(clip: String, t: float) -> void:
	if clip != "fly":
		_body.global_position = Vector3(0.0, _rest_y, 0.0)
		_body.rotation = Vector3.ZERO
		return
	var across := COPTER_SPEED * float(SECONDS["fly"])
	_body.linear_velocity = Vector3(0.0, 0.0, -COPTER_SPEED)
	_body.global_position = Vector3(0.0, COPTER_ALTITUDE + 0.3 * sin(t * 2.0), across * 0.5 - COPTER_SPEED * t)
	_body.rotation = Vector3(COPTER_PITCH, 0.0, 0.12 * sin(t * 1.4))


func _drive_weapon(clip: String, t: float, step: float) -> void:
	var id := StringName(_shown_id.trim_prefix("weapon_"))
	var art := ZeeWeaponArtTable.table().get(id) as ZeeWeaponArt
	var def: GSWeaponDef = _weapon_defs.get(String(id))
	match clip:
		"draw":
			_model.on_deploy(clampf(t / 0.6, 0.0, 1.0))
			_figure.hold(id, t < 0.3)
		"fire":
			var every := _fire_interval(def)
			var due := int(floor((t - 0.2) / every)) + 1 if t >= 0.2 else 0
			while _shots_done < due:
				_shots_done += 1
				_fire(art)
		"reload":
			if t < step:
				_model.on_reload_begin(0, def.magazine)
			_model.on_reload(clampf(t / 2.6, 0.0, 1.0))
	_model.advance(step)


func _fire_interval(def: GSWeaponDef) -> float:
	if def == null or def.use_interval_ticks <= 0:
		return FIRE_EVERY
	var rate := def.authored_tick_rate if def.authored_tick_rate > 0 else ZeeWeaponPack.TICK_RATE
	return float(def.use_interval_ticks) / float(rate)


func _fire(art: ZeeWeaponArt) -> void:
	_struck = art.pose == ZeeWeaponArtTable.POSE_MELEE or art.pose == ZeeWeaponArtTable.POSE_THROWN
	if art.pose == ZeeWeaponArtTable.POSE_MELEE:
		_model.on_swing()
		_figure.fired(1, ZeeWeaponNet.KIND_SWING)
	elif art.pose == ZeeWeaponArtTable.POSE_THROWN:
		var outcome := GSWeaponOutcome.of(GSWeaponOutcome.KIND_THROW)
		outcome.used = true
		_model.on_used(outcome)
		_figure.fired(1, ZeeWeaponNet.KIND_THROW)
	else:
		_model.on_fired()
		_figure.fired(1, ZeeWeaponNet.KIND_SHOT)


func _grounded(_item: String, clip: String, t: float) -> bool:
	if clip == "fly":
		return false
	return not (clip == "jump" and fmod(t, 1.0) < JUMP_AIR)


func _before_draw(_item: String, _clip: String, _frame: int) -> void:
	if _figure != null:
		var _tagged := GSGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


## Weapons: the real view model's camera at the person's eye. Copter: the pilot's seat. People and props: an opponent's
## eye a few metres in front, looking at the subject.
func _place_first_person(_item: String) -> void:
	if _shown_kind == "weapon":
		first_person.global_position = _figure.global_position + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0)
		first_person.rotation = Vector3.ZERO
		return
	if _shown_kind == "copter":
		var seat := _body.get_node_or_null(^"PilotSeat") as Node3D
		var eye := (seat.position if seat != null else Vector3.ZERO) + PILOT_EYE
		first_person.global_transform = Transform3D(_body.global_basis, _body.global_transform * eye)
		return
	var subject := _subject("")
	var height := BODY_HEIGHT if _shown_kind == "person" else _prop_height
	var away := 2.5 if _shown_kind == "person" else _prop_away
	var base := 0.0 if _shown_kind == "person" else -_rest_y
	var eye_y := 1.6 if _shown_kind == "person" else clampf(height * 1.4, 0.1, 1.6)
	first_person.global_position = subject.global_position + Vector3(0.0, base + eye_y, -away)
	first_person.look_at(subject.global_position + Vector3(0.0, base + height * 0.5, 0.0))


## A strike's swing relaxes bone_pop; a prop or the parked copter gets a row for where its lowest point sits on the floor.
func _checks(_item: String, clip: String, rows: Array[Dictionary]) -> Array[Dictionary]:
	if _shown_kind == "weapon" and clip == "fire" and _struck:
		for row: Dictionary in rows:
			if row["check"] == "bone_pop" and not row.get("skip", false):
				row["pass"] = float(row["value"]) <= STRIKE_POP_DEG
				row["limit"] = STRIKE_POP_DEG
				row["note"] = "%s (a strike or throw)" % row.get("note", "")
	if _shown_kind == "prop" or (_shown_kind == "copter" and clip != "fly"):
		var box := _bounds(_body)
		var gap := absf(box.position.y)
		rows.append({"check": "floor_m", "pass": gap <= 0.03, "value": snappedf(gap, 0.001), "limit": 0.03,
			"note": "lowest drawn point above (+) or under (-) the floor: %s" % snappedf(box.position.y, 0.001)})
	return rows


func _bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var m := mesh as MeshInstance3D
		var local := m.global_transform * m.get_aabb()
		box = local if first else box.merge(local)
		first = false
	return box
