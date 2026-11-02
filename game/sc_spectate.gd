extends DotSpectatorHost

const ScPlayer := preload("sc_player.gd")

## Where somebody who is out looks, and what the server lets them see. The policy (who may watch whom, through which camera) is the server's: an authoritative [DotSpectatorManager] there, and a MIRROR on a client told each change in a `SPECTATE` event; dot-spectate computes a transform and touches no camera.
## No delay, as it would protect nothing: every player is always relevant (open air), so every client already receives every live position. `delay_ticks` stays 0 and the mirror's `advance` records no history.
## No `class_name`, like everything in this game; reached by preload from [ScGame], which hands it the two dictionaries it reads and a phase callable rather than being preloaded back (no cycle).

const CHANNEL := "sc.spectate"

## Seconds the death camera holds before handing over.
## A second and a half, not a killcam: most deaths are falls with no killer, and the moment is for seeing the drop you went down.
const DEATH_CAM_SECONDS := 1.5

## Seconds the freeze camera holds on whoever shot you, in the showdown.
const FREEZE_CAM_SECONDS := 1.5

## How far above the deck a faller's death camera hangs, looking straight down the drop.
## Not where they died: a fall is recorded at the kill height, where nothing is worth seeing, so the camera goes back up over the point they left it by.
const DROP_CAM_RISE := 6.0

## Which of the two overview cameras is the showdown's. See [method set_overviews].
const OVERVIEW_FIELD := 0
const OVERVIEW_SHOWDOWN := 1

## player id -> ScPlayer. The world's own dictionary, shared rather than copied, so a join
## is visible here the moment the world has it.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}

## [code]() -> int[/code], the world's phase. See [method camera_for].
var phase_fn: Callable = Callable()

## [code](phase) -> bool[/code]: whether a phase is the showdown's half of the map.
var in_showdown_fn: Callable = Callable()


## Builds the manager on [param p_rules], the world's own [member ScGame.spectate_rules].
func bind(p_authoritative: bool, p_tick_rate: int, p_rules: DotSpectatorRules) -> DotResult:
	authoritative = p_authoritative
	tick_rate = p_tick_rate
	rules = p_rules
	chase_distance = 4.6
	chase_height = 1.2
	eye_height = ScPlayer.EYE_HEIGHT
	prefer_own_side = true
	name_fn = _display_name
	fixed_index_fn = _fixed_index

	var res := setup()
	return res if res.ok else res.wrap("smash-copter spectating")


func _channel() -> String:
	return CHANNEL


## `force_camera` and `allow_roaming` are the operator's (`mp_forcecamera`, `mp_freeroam`), not set here.
func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	# Dead players stay dead until the next round, so a list that included them would be
	# a list of bodies at the kill height.
	r.cycle_includes_dead = false
	r.delay_ticks = 0
	r.history_ticks = 2
	return r


## Somebody is out. Starts the death camera; the server's tick hands it over. [param at] is where
## they died; a fall is recorded at the kill height, so the camera is moved back up over the point
## they went down ([constant DROP_CAM_RISE]).
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	death(String(player_id), where, String(by), tick)

	DotLog.debug(CHANNEL, "somebody who is out is watching", {
		"player": String(player_id), "by": String(by), "fell": fell,
	})


## Somebody is back in the world — a new round, or a join. They stop watching.
func on_spawned(player_id: StringName) -> void:
	if is_spectating(String(player_id)):
		DotLog.debug(CHANNEL, "a new round ends watching", {"player": String(player_id)})

	spawned(String(player_id))


## The free-roam key, asked of the server like every other camera change; refused with a line when
## roaming is off (`mp_freeroam 0`) or a camera is forced. The server owns the mode (the SPECTATE
## event carries ROAMING); the client flies the camera ([DotSpectatorFreeCam]).
func toggle_roam(key: String) -> DotResult:
	if manager == null:
		return _unset()

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	return super(key)


func can_roam(key: String) -> bool:
	return is_spectating(key) and super(key)


func _fixed_index(_key: String) -> int:
	var showdown := false
	if phase_fn.is_valid() and in_showdown_fn.is_valid():
		showdown = bool(in_showdown_fn.call(int(phase_fn.call())))
	return OVERVIEW_SHOWDOWN if showdown else OVERVIEW_FIELD


func _display_name(key: String) -> String:
	var body: ScPlayer = players.get(StringName(key))
	return body.display_name if body != null else key


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _team_of(key: String) -> int:
	return int(sides.get(StringName(key), 0))


func _is_alive(key: String) -> bool:
	var body: ScPlayer = players.get(StringName(key))
	return body != null and is_instance_valid(body) and body.is_alive()


## Where somebody's eyes are, from where this process DRAWS them.
## The drawn position, not the node, on a world that simulates: a node moves once a tick, so a camera hung on it steps. A mirror's remote players are written once a frame by the interpolator, so there the node is already right, and a rider's controller is not simulated at all.
func _pose_of(key: String) -> Transform3D:
	var body: ScPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative and not body.riding:
		at = body.controller.render_state().position

	var state := body.controller.state
	return eye_pose(at, state.pitch, state.yaw)
