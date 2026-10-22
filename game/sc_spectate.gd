extends Node

const ScPlayer := preload("sc_player.gd")

## Where somebody who is out looks, and what the server lets them see.
##
## [b]Until this existed, falling was the end of the game for the rest of the round.[/b] The
## camera hangs off the player's own node, and a player who ran out of map is a body at the
## kill height: so the next two minutes were spent looking at the floor of the map from
## inside it, while the round that decides whether your side wins happened forty metres
## overhead. This is last-team-standing, which means the people who are out are exactly the
## people with the most reason to watch.
##
## [b]The camera part is four lines; who decides is the part that matters.[/b] dot-spectate
## computes a transform and touches no camera, and the policy — may this person watch, whom,
## through which camera — is the server's, so a client that decided for itself what it may
## look at would be a client that may look at anything. On a server this runs an
## authoritative [DotSpectatorManager]; on a connected client it runs a MIRROR that is told
## each view change in a `SPECTATE` event and computes the camera itself from the players it
## already draws. That split is what keeps the wire to one small event per decision rather
## than a camera transform per frame.
##
## [b]No delay, and it would protect nothing here.[/b] dot-spectate's delay exists because a
## spectator watching live is a live intelligence feed — but every player in this game is
## always relevant (the map is open air), so every client already receives every player's
## live position in its snapshots. A delayed spectator camera would hide nothing that the
## same client's own world is not already drawing. `delay_ticks` stays 0 and a mirror never
## needs the history a delay samples, which is also why the mirror's `advance` records none.
##
## [b]No `class_name`, like everything in this game.[/b] Reached by preload from [ScGame].
## It does not preload [ScGame] back: the world hands it the two dictionaries it reads and a
## callable for the phase, which is a smaller contract than the world and no cycle.

const CHANNEL := "sc.spectate"

## Seconds the death camera holds before handing over.
##
## [b]A second and a half, and it is not a killcam.[/b] Most deaths here are falls, where
## there is no killer to look at; what the moment is for is seeing the drop you just went
## down, so the next round is played a metre further from that edge.
const DEATH_CAM_SECONDS := 1.5

## Seconds the freeze camera holds on whoever shot you, in the showdown.
const FREEZE_CAM_SECONDS := 1.5

## How far above the deck a faller's death camera hangs, looking straight down the drop.
##
## [b]Not where they died, which is the floor.[/b] A fall is recorded at the kill height —
## the one place in the map nothing is worth seeing from — so the camera goes back up to
## the field over the point they left it by and looks down the forty metres instead.
const DROP_CAM_RISE := 6.0

## Which of the two overview cameras is the showdown's. See [method set_overviews].
const OVERVIEW_FIELD := 0
const OVERVIEW_SHOWDOWN := 1

## A viewer's camera changed: a death, a hand-over, a target leaving, a step through the
## list. [param player_id] is theirs. What the bridge tells that one client about.
signal view_changed(player_id: StringName)

var manager: DotSpectatorManager = null

## player id -> ScPlayer. The world's own dictionary, shared rather than copied, so a join
## is visible here the moment the world has it.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}

## [code]() -> int[/code], the world's phase. See [method camera_for].
var phase_fn: Callable = Callable()

## [code](phase) -> bool[/code]: whether a phase is the showdown's half of the map.
var in_showdown_fn: Callable = Callable()

## Whether this decides anything. A connected client's world is a mirror.
var authoritative: bool = true

## Set while a viewer is stepping through the list themselves. See [method _prefer_side].
var _stepping: bool = false

## Set while [method _prefer_side] is moving somebody, so its own watch does not re-enter.
var _preferring: bool = false


## The key the HUD names for the free camera; the client sets it from the bindings.
var roam_key: String = "G"


## Builds the manager on [param rules], the world's own [member ScGame.spectate_rules].
func setup(p_authoritative: bool, tick_rate: int, rules: DotSpectatorRules) -> DotResult:
	authoritative = p_authoritative

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = authoritative
	manager.rules = configure_rules(rules, tick_rate)
	manager.participants_fn = _participants
	manager.team_fn = func(key: String) -> int: return int(sides.get(StringName(key), 0))
	manager.alive_fn = _alive
	manager.pose_fn = _pose_of
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("smash-copter spectating")

	manager.view_changed.connect(_on_view_changed)
	manager.retargeted.connect(_on_retargeted)

	# DEBUG rather than INFO: the world is built once per process on a server but once per
	# test in every suite, and the policy it logs is already in `sc_status`.
	DotLog.debug(CHANNEL, "spectating is set up", {
		"authoritative": authoritative,
		"force_camera": manager.rules.force_camera,
		"roaming": manager.rules.roaming_permitted(),
	})
	return DotResult.success(null)


## The policy this game adds to the operator's: how long the cameras hold and where they stand.
##
## Static so a suite can read the numbers without a world. [b]`force_camera` and
## `allow_roaming` are not set here[/b]: they are the operator's (`mp_forcecamera`,
## `mp_freeroam`) and default to anybody-may-watch with free roam on. Until 2026-10-21 this
## forced roaming off whatever the operator said.
static func configure_rules(rules: DotSpectatorRules, tick_rate: int) -> DotSpectatorRules:
	# Dead players stay dead until the next round, so a list that included them would be
	# a list of bodies at the kill height.
	rules.cycle_includes_dead = false
	rules.death_cam_ticks = int(DEATH_CAM_SECONDS * float(maxi(tick_rate, 1)))
	rules.freeze_cam_ticks = int(FREEZE_CAM_SECONDS * float(maxi(tick_rate, 1)))
	rules.chase_distance = 4.6
	rules.chase_height = 1.2
	rules.delay_ticks = 0
	rules.history_ticks = 2
	return rules


## Changes who may watch whom, from the next decision on. What the deprecated `sc_spectate_camera` writes (`mp_forcecamera` is the rule now).
func set_force_camera(force_camera: int) -> void:
	if manager == null or manager.rules == null:
		return

	manager.rules.force_camera = clampi(force_camera, 0, 2)

	# INFO: a rule an admin changed and a player is going to ask about.
	DotLog.info(CHANNEL, "the spectator policy changed", {
		"force_camera": manager.rules.force_camera,
	})


## The two places nobody-left-to-watch looks from: over the field, and over the corners.
##
## [b]Two, because the round is in two places.[/b] A viewer whose whole side is out has
## nobody the "own side" rule lets them follow, and dot-spectate falls back to a fixed
## camera — which with one camera over the field would spend the showdown pointed at the
## place the round has just left.
func set_overviews(field: Transform3D, showdown: Transform3D) -> void:
	if manager == null:
		return

	var cameras: Array[Transform3D] = [field, showdown]
	manager.fixed_cameras = cameras


# --- What the world reports -------------------------------------------------

## Somebody is out. Starts the death camera; the server's tick hands it over.
##
## [param at] is where they died. A fall is recorded at the kill height, so the death camera
## is moved back up over the point they went down — see [constant DROP_CAM_RISE].
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	manager.on_death(String(player_id), where, String(by), tick)

	# DEBUG: a transition. "My camera went somewhere odd when I fell" is answered by what
	# it was put on.
	DotLog.debug(CHANNEL, "somebody who is out is watching", {
		"player": String(player_id), "by": String(by), "fell": fell,
	})


## Somebody is back in the world — a new round, or a join. They stop watching.
func on_spawned(player_id: StringName) -> void:
	if manager == null:
		return

	if manager.is_spectating(String(player_id)):
		DotLog.debug(CHANNEL, "a new round ends watching", {"player": String(player_id)})

	manager.on_spawn(String(player_id))


## Somebody left. Called AFTER the world has dropped them, which is dot-spectate's rule:
## the replacement is chosen from the roster, and a roster still holding the leaver picks
## the leaver.
func on_left(player_id: StringName) -> void:
	if manager != null:
		manager.on_leave(String(player_id))


func advance(tick: int) -> void:
	if manager != null:
		manager.advance(tick)


# --- What a viewer asks for -------------------------------------------------

## The free-roam key, asked of the server like every other camera change: into a free camera
## from a player, and back onto one from it. Refused with a line to show when roaming is off
## (`mp_freeroam 0`) or a restricted camera is set (`mp_forcecamera`).
##
## [b]The server owns the mode; the client flies the camera.[/b] The SPECTATE event carries
## ROAMING, and each frame's pose is the client's own ([DotSpectatorFreeCam]), because a
## camera position per frame is the wire cost this game's one small event avoids.
func toggle_roam(player_id: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	var key := String(player_id)

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	if not manager.can_roam(key):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Free roam is off on this server.")

	return manager.toggle_roam(key)


func can_roam(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id)) \
		and manager.can_roam(String(player_id))


func is_roaming(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id)) \
		and manager.view(String(player_id)).mode == DotSpectatorView.Mode.ROAMING


## The next or the previous person this viewer may watch, or 0 for the other camera.
##
## [b]Asked of the server and answered by it.[/b] On a connected client this arrives as a
## request, and a refusal goes back as a notice; the list is the server's own
## `targets_for`, so a client can never step onto somebody the policy forbids.
func step(player_id: StringName, direction: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	var key := String(player_id)

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	if direction == 0:
		return _cycle_camera(key)

	_stepping = true
	var moved := manager.next_target(key) if direction > 0 else manager.previous_target(key)
	_stepping = false
	return moved


## First person, then behind them, when the policy allows it.
func _cycle_camera(key: String) -> DotResult:
	var view := manager.view(key)

	if not view.follows_target() or view.mode == DotSpectatorView.Mode.FREEZE_CAM:
		return DotResult.fail(DotError.CODE_STATE, "There is nobody in front of this camera.")

	var wanted := DotSpectatorView.Mode.CHASE
	if view.mode == DotSpectatorView.Mode.CHASE:
		wanted = DotSpectatorView.Mode.FIRST_PERSON

	var set_to := manager.set_mode(key, wanted)

	if not set_to.ok:
		return set_to

	if int(set_to.value) != wanted:
		# dot-spectate downgrades rather than refuses, and says so at DEBUG; the viewer who
		# pressed the key is the one who needs to hear it.
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This server only lets you watch through their eyes."
		)

	return set_to


## Adopts a view the server decided. The client half.
func apply_view(
	player_id: StringName, mode: int, target: StringName, killer: StringName, death_at: Vector3
) -> void:
	if manager == null:
		return

	var view := manager.view(String(player_id))
	view.mode = clampi(mode, 0, DotSpectatorView.Mode.size() - 1) as DotSpectatorView.Mode
	view.target = String(target)
	view.killer = String(killer)
	# [b]Carried by this game's own event.[/b] dot-spectate's wire had no death position
	# until 2026-09-25 (it is `"d"` now), and a mirror without one puts every death camera
	# at the world origin — which in this map is inside the cannon. The event stays this
	# game's own because it is bit-packed and session-keyed, which the dictionary is not.
	view.death_position = death_at
	view.until_tick = -1
	view_changed.emit(player_id)


# --- What is drawn ----------------------------------------------------------

func is_spectating(player_id: StringName) -> bool:
	return manager != null and manager.is_spectating(String(player_id))


func mode_of(player_id: StringName) -> int:
	return int(manager.view(String(player_id)).mode) if manager != null else 0


## Who a viewer is watching, or an empty name.
func watching(player_id: StringName) -> StringName:
	if manager == null or not manager.is_spectating(String(player_id)):
		return &""

	return StringName(manager.view(String(player_id)).target)


## Where [param player_id]'s camera goes this frame. Identity when they are playing.
##
## [b]The fixed camera is chosen by the phase, here, on both ends.[/b] dot-spectate keeps a
## per-view index into its fixed cameras; this game has exactly two and which one is right
## is a fact about the round rather than about the viewer, so it is read from the phase a
## client already has rather than sent.
func camera_for(player_id: StringName) -> Transform3D:
	if manager == null:
		return Transform3D.IDENTITY

	var key := String(player_id)

	if not manager.is_spectating(key):
		return Transform3D.IDENTITY

	var view := manager.view(key)

	if view.mode == DotSpectatorView.Mode.FIXED:
		var showdown := false
		if phase_fn.is_valid() and in_showdown_fn.is_valid():
			showdown = bool(in_showdown_fn.call(int(phase_fn.call())))
		view.fixed_index = OVERVIEW_SHOWDOWN if showdown else OVERVIEW_FIELD

	return manager.camera_of(key)


## One line for the HUD, or an empty string while playing.
func line_for(player_id: StringName) -> String:
	if not is_spectating(player_id):
		return ""

	var view := manager.view(String(player_id))

	match view.mode:
		DotSpectatorView.Mode.DEATH_CAM:
			return "you are out"
		DotSpectatorView.Mode.FREEZE_CAM:
			return "shot by %s" % _name_of(StringName(view.target))
		DotSpectatorView.Mode.FIXED:
			return "nobody left to watch%s" % _roam_suffix(player_id)
		DotSpectatorView.Mode.ROAMING:
			return "free camera   %s back to players" % roam_key
		DotSpectatorView.Mode.CHASE:
			return "watching %s  (behind)   click: next   F5: their eyes%s" % [
				_name_of(StringName(view.target)), _roam_suffix(player_id)
			]
		_:
			return "watching %s   click: next   F5: behind them%s" % [
				_name_of(StringName(view.target)), _roam_suffix(player_id)
			]


## The hint for the free camera, only while the server allows it.
func _roam_suffix(player_id: StringName) -> String:
	return "   %s: free camera" % roam_key if can_roam(player_id) else ""


func _name_of(player_id: StringName) -> String:
	var body: ScPlayer = players.get(player_id)
	return body.display_name if body != null else String(player_id)


# --- The manager's callables ------------------------------------------------

func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _alive(key: String) -> bool:
	var body: ScPlayer = players.get(StringName(key))
	return body != null and is_instance_valid(body) and body.is_alive()


## Where somebody's eyes are, from where this process DRAWS them.
##
## [b]The drawn position and not the node, on a world that simulates.[/b] A node here moves
## once a tick, so a camera hung on it advances in steps — the jitter this game measured
## at 160 frames still in 288 and fixed for the player's own camera by drawing from
## `render_state`. The same blend serves the spectator camera. A mirror's remote players
## are written once a frame by the interpolator, so there the node is already right, and a
## rider's controller is not simulated at all.
func _pose_of(key: String) -> Transform3D:
	var body: ScPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative and not body.riding:
		at = body.controller.render_state().position

	var state := body.controller.state
	var basis := Basis.from_euler(Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0))
	return Transform3D(basis, at + Vector3(0.0, ScPlayer.EYE_HEIGHT, 0.0))


# --- Team-mates first -------------------------------------------------------

func _on_view_changed(key: String, mode: int, target: String) -> void:
	_prefer_side(key, mode, target)
	view_changed.emit(StringName(key))


func _on_retargeted(key: String, _from: String, to: String, _reason: StringName) -> void:
	_prefer_side(key, int(manager.view(key).mode), to)
	view_changed.emit(StringName(key))


## When the server picks somebody for a viewer, it picks a team-mate if there is one.
##
## [b]dot-spectate chooses the first allowed name in key order, and here that is a
## stranger.[/b] Under "own side" it can only be a team-mate anyway; under "anybody" it is
## whoever sorts first, and somebody who has just fallen off wants to see how their own side
## is doing — which is also who they are rooting for in the corners. So an AUTOMATIC choice
## is moved to the first living team-mate the policy allows. A viewer stepping through the
## list themselves is left exactly where they asked to be.
func _prefer_side(key: String, mode: int, target: String) -> void:
	if not authoritative or _stepping or _preferring or target == "":
		return

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.CHASE:
		return

	var mine := int(sides.get(StringName(key), 0))

	if mine <= 0 or int(sides.get(StringName(target), 0)) == mine:
		return

	for candidate in manager.targets_for(key):
		if int(sides.get(StringName(candidate), 0)) != mine:
			continue

		_preferring = true
		var _moved := manager.watch(key, candidate, mode)
		_preferring = false
		return


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])

	return manager.describe_lines()
