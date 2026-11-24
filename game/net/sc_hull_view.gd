extends RefCounted

## Where every other player stood on a mover's screen, for `mp_solidplayers_unlag`: this game's wiring of gs-player-controller's [GSPlayerHullView] (the ring, the resolve rule and the client's fill live there; docs/collision.md "Sharing the view").
## A command names how far behind its tick the sender drew the others and the snapshot pair it drew between ([ScNetCommand.view_lag_q], `view_back`, `view_span`, kept per player as `ScPlayerNet.last_view_*`). The server answers from its per-tick ring of feet, the client from the interpolator's samples of the same two ticks, so the hull a bump meets is the same one on both.
## The bodies it moves are `ScGame.players` (each has its `SolidHull` from `GSPlayerBodyRules.apply_hull`). A stand-in or a player with no command sends no view and its step runs against the present.

const ScNetCommand := preload("sc_net_command.gd")
const ScPlayer := preload("../sc_player.gd")
const ScPlayerNet := preload("sc_player_net.gd")

## The shared view: `counts`, `capacity` and `rewind` are read off it.
var view := GSPlayerHullView.new()

var _game: Object = null
var _net: GSNetManager = null
## The bridge's behaviours by session id, shared by reference.
var _behaviours: Dictionary = {}
var _wire_var: GSNetVar = null


func _init(game: Object, net: GSNetManager, behaviours: Dictionary) -> void:
	_game = game
	_net = net
	_behaviours = behaviours
	view.is_server = net.is_server
	view.snap_fn = _snap
	view.view_fn = _view_of
	view.client_fn = _drawn_feet


## Runs [param work] for [param mover]'s step at [param tick] with the other hulls where the mover's last command said they were drawn.
func around(mover: StringName, tick: int, work: Callable) -> Variant:
	return view.around(_game.body_rules, mover, _game.players, tick, work)


## Server, after the tick's moves: every player's feet on the wire's grid. Kept while players are solid, so turning `mp_solidplayers_unlag` on finds history already there.
func record(tick: int) -> void:
	if not _game.body_rules.solid:
		return

	var config: Object = _game.combat.config if _game.combat != null else null
	var max_rewind_sec: float = config.max_rewind_ms / 1000.0 if config != null else 1.0
	view.capacity = ceili(max_rewind_sec * float(_game.tick_rate)) + 4
	var positions := {}

	for id: StringName in _game.players:
		positions[id] = (_game.players[id] as ScPlayer).controller.state.position

	view.record(tick, positions)


## Client, building a command for [param tick]: the lag and bracket as this client draws the others now, kept on [param mine] (its own behaviour) for the predicted step. Leaves none when the rules are off or the interpolator is not running yet.
func fill(command: ScNetCommand, tick: int, mine: ScPlayerNet) -> void:
	command.view_lag_q = -1
	command.view_back = -1
	command.view_span = 0
	var net := _net

	if _game.body_rules.solid and _game.body_rules.unlag and net.interpolator != null and net.clock.is_synced():
		_name_view(command, tick)

	if mine != null:
		mine.last_view_q = command.view_lag_q
		mine.last_view_back = command.view_back
		mine.last_view_span = command.view_span
		mine.last_view_tick = tick


func _name_view(command: ScNetCommand, tick: int) -> void:
	var net := _net

	var drawn: float = float(net.clock.received_tick()) + clampf(net.clock.render_alpha(), -1.0, 2.0) + net.clock.receive_slip() - net.interpolator.delay_ticks()
	var q := GSPlayerHullView.lag_q_for(tick, drawn, ScNetCommand.MAX_VIEW_LAG_Q)
	var pair: Vector2i = net.interpolator.bracket_at(float(tick) - float(q) * 0.25)
	var bracket := GSPlayerHullView.bracket_for(tick, pair, ScNetCommand.VIEW_BACK_BITS, ScNetCommand.VIEW_SPAN_BITS)
	command.view_lag_q = q
	command.view_back = bracket[0]
	command.view_span = bracket[1]


## `[lag_q, command_tick, back, span]` of the mover's last command, or null (a stand-in has no behaviour, and no view).
func _view_of(mover: Variant) -> Variant:
	var behaviour: ScPlayerNet = _behaviour(mover)

	if behaviour == null:
		return null

	return [behaviour.last_view_q, behaviour.last_view_tick, behaviour.last_view_back, behaviour.last_view_span]


## Client: [param other]'s drawn feet at [param render], from the interpolator's samples.
func _drawn_feet(other: Variant, older: int, span: int, render: float) -> Variant:
	var theirs: ScPlayerNet = _behaviour(other)
	var net := _net

	if theirs == null or theirs.identity == null or net.interpolator == null:
		return null

	var id: int = theirs.identity.net_id

	if older >= 0:
		return net.interpolator.value_between(id, &"net_position", older, older + span, render, view.teleport_cut)

	return net.interpolator.value_at(id, &"net_position", render, view.teleport_cut)


## The behaviour of the player with this id, or null (a stand-in has none; neither has an id that is not one).
func _behaviour(id: Variant) -> ScPlayerNet:
	if typeof(id) != TYPE_STRING_NAME:
		return null

	return _behaviours.get(String(id).trim_prefix("u").to_int())


func _snap(feet: Vector3) -> Vector3:
	if _wire_var == null:
		for id: StringName in _game.players:
			var behaviour: ScPlayerNet = _behaviour(id)

			if behaviour != null:
				_wire_var = behaviour.find_var(&"net_position")

				if _wire_var != null:
					break

	return _wire_var.wire_value(feet) if _wire_var != null else feet


## Hands gs-combat the two callables that make shot lag compensation real (the sibling of the hull rewind below: that one moves hulls for a mover, this one moves entities for a shot).
##
## [b]Two lines, and without them the setting is a lie.[/b] gs-combat names no gs-net type
## — the whole point of the seam — so it takes a rewind and a restore as [Callable]s and,
## unset, says so once at boot and then resolves every shot against the present anyway. A
## game that left the flag on and the callables unset would report lag compensation as
## enabled, do nothing, and cost the next reader an afternoon; this family calls that
## "produced correctly and consumed by nothing" and it is its second most repeated bug.
##
## gs-net already records the history: `GSNetManager.server_tick` calls
## `history.record(identities, tick)` once a snapshot. There is nothing to build.
##
## [b]The shooter is not excluded, and that is safe here rather than an oversight.[/b]
## `GSNetHistory.rewind` can leave one entity alone so that rewinding does not move the
## shooter's own muzzle — but `resolve_shot` fixes `shot.origin` before it rewinds anything,
## so the muzzle has already been decided, and the resolver refuses self damage separately.
## What excluding would buy is one fewer entity moved and put back.
static func wire_combat(game: Object, net: GSNetManager) -> void:
	if game.combat == null or net == null:
		return

	if game.combat.config != null:
		game.combat.config.lag_compensation = true

	game.combat.rewind_fn = func(target_tick: float) -> void:
		var _rewound := net.history.rewind(
			net.registry.all(), int(target_tick), net.clock.tick
		)

	game.combat.restore_fn = func() -> int:
		return net.history.restore()

	GSLog.debug("sc.net", "lag compensation is wired to the netcode's history", {
		"max_rewind_ms": game.combat.config.max_rewind_ms if game.combat.config != null else 0.0,
	})
