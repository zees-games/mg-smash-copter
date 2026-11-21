extends GSNetBehaviour

const ScPlatforms := preload("../sc_platforms.gd")

## What a platform replicates: two angles, a height and a state. Four numbers.
##
## [b]The cheapest thing on the wire and the most important thing on the screen.[/b] A
## platform is not a rigid body — see [ScPlatforms] for why it must not be — so there is no
## transform to send and no solver to agree with. What the server has decided is a lean and
## a sink, and those are exactly what it says.
##
## [b]It is also the one replicated thing in this game that is the FLOOR.[/b] Everything
## else being a snapshot behind is a cosmetic cost; a floor being a snapshot behind is a
## player standing on something that is not there. So the lean is interpolated — it moves
## continuously and a client between two snapshots should be between two leans — and the
## STATE is not: a platform that has come off its pillar takes its collider away on the
## tick the client is told, not smoothly over the next three.

## Which platform in the field this is. Set on both ends; the wire never carries it per
## tick, because it does not change.
var index: int = -1

## The field this platform belongs to, so a mirror can be written straight into the model.
var platforms: ScPlatforms = null

var net_lean_x: float = 0.0
var net_lean_y: float = 0.0
var net_sink: float = 0.0
var net_state: int = 0


func _register_net_vars() -> void:
	# [b]The range is a shade past what a platform can actually reach, and that is
	# deliberate.[/b] A quantised value is decoded against its declared range, so a lean
	# that saturated at the collapse angle would make every platform that is about to go
	# over look identical to every other. Half a radian is about twice the angle anything
	# survives, so the interesting part of the range is the middle of it.
	replicate(&"net_lean_x", GSNetVar.Type.FLOAT_RANGE).range_of(-0.5, 0.5).bits(11).interpolated()
	replicate(&"net_lean_y", GSNetVar.Type.FLOAT_RANGE).range_of(-0.5, 0.5).bits(11).interpolated()
	replicate(&"net_sink", GSNetVar.Type.FLOAT_RANGE).range_of(-64.0, 4.0).bits(14).interpolated()
	# Three states in two bits, and NOT interpolated: half way between standing and gone is
	# not a thing a floor can be.
	replicate(&"net_state", GSNetVar.Type.UINT).bits(2)


## Authority only: what the model decided this tick.
func pull() -> void:
	if platforms == null or index < 0:
		return

	var deck := platforms.deck_at(index)

	if deck == null:
		return

	net_lean_x = clampf(deck.lean.x, -0.5, 0.5)
	net_lean_y = clampf(deck.lean.y, -0.5, 0.5)
	net_sink = clampf(deck.sink, -64.0, 4.0)
	net_state = deck.state


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


func _net_state_applied(_tick: int) -> void:
	_draw()


func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if platforms == null or index < 0:
		return

	if identity != null and identity.is_authoritative:
		return

	platforms.adopt(index, Vector2(net_lean_x, net_lean_y), net_sink, net_state)
