extends RefCounted

const ScGame := preload("../sc_game.gd")

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, and nothing checks that they are inverses for you —
## `headless_net` round-trips every one of them, because this family has already shipped a
## serialisation whose two ends never met: dot-moderation wrote `"voice muted"` and read
## back a warning, and the one thing that addon existed for silently did nothing.
##
## [b]The map is a description, not a file, and that is what this format is built
## around.[/b] A round's platform field is an id and six numbers; a client rebuilds the
## identical field from them and every platform in it comes out in the same order, which is
## what lets a snapshot move platform number seven without ever saying what a platform is.
## The alternative — a scene per layout — would be content to publish, to version and to
## keep in step across two machines, in exchange for nothing this cannot say.

enum Kind {
	## Who you are, how fast the server ticks, and how long each half of a round is.
	HELLO,
	## What the field of platforms looks like this round. Rebuild it from this.
	LAYOUT,
	## A player is in the world: net id, name, side.
	JOIN,
	LEAVE,
	## A player changed sides.
	TEAM,
	## A platform now exists, and which net id moves it.
	PLATFORM,
	## A prop or a chopper now exists.
	PROP,
	## It is gone, and why.
	PROP_GONE,
	## Somebody got into or out of a chopper.
	SEAT,
	## The clock and the numbers a client cannot count for itself.
	CLOCK,
	## A round began or ended.
	ROUND,
	## The round changed half.
	PHASE,
	## Something strange started or stopped.
	SPECIAL,
	## Somebody was crushed, shot, blown up or simply missed.
	DEATH,
	## A barrel went off. The client draws it; the server decided it.
	BLAST,
	## A platform came off its pillar, and why.
	COLLAPSE,
	## A survivor was handed a weapon.
	ARMED,
	## Text for one player.
	NOTICE,
	## One chat line, already routed, sanitised and addressed by [DotChatRouter].
	CHAT,
	## What this one player's camera is on now that they are out. To its owner only.
	SPECTATE,
	## Something landed on a platform hard enough to matter. What a client makes a noise
	## about; the lean it caused arrives in the snapshot like any other.
	IMPACT,
	## Your shot landed: where, whether it killed, whether to the head. To the shooter only.
	HIT,
	## The field's toys: their net ids in deck order (both ends place them from the layout).
	## After LAYOUT, and to a joiner after theirs.
	TOYS,
}

enum Ask {
	## I have built my world and can receive. Tell me everything in it.
	READY,
	## I typed a line. The server decides what channel it lands on and who hears it.
	SAY,
	## I am next to a chopper and I would like to be in it — or out of it.
	BOARD,
	## Put me on that side.
	TEAM,
	## I am out: show me the next person, the previous one, or the other camera.
	SPECTATE,
	## I am out: take me into the free camera, or back onto a player from it.
	ROAM,
}

## Every decoder returns an `ok` beside its fields, and every caller checks it.
##
## [b]A reader past its end returns plausible zeros rather than failing.[/b] dot-net shipped
## with exhaustion that was not sticky, so a decoder that skipped this check got a
## believable value for the field AFTER the overrun — and a truncated packet decodes as a
## valid message about nothing.
const NAME_BYTES := 64
const ID_BYTES := 64
const TEXT_BYTES := 256

## The most an avatar document may take in a JOIN. One slot is about eighty bytes; the rest
## is room for slots this game does not have yet, and a cap that a hostile document cannot
## talk its way past.
const AVATAR_BYTES := 1024

## Where a body may be, in metres, on the wire.
##
## [b]Read from [ScGame], not written here.[/b] A quantised position is decoded against this
## range, so two files holding two numbers do not lose precision — they put the thing
## somewhere else. game-arena had exactly this, 256 against 128, in two files that each
## looked right on its own.
const WORLD_EXTENT := ScGame.NET_WORLD_EXTENT
const POS_BITS := 24

## The round clock, in seconds. Well past anything the configuration allows, because the
## extra bit is cheaper than the bug of a clock that wraps.
const CLOCK_MAX := 1800.0
const CLOCK_BITS := 15

## Team ids are 1..6 and zero is "no side", so three bits and one to spare.
const TEAM_BITS := 3

## Up to 255 platforms in a field, which is twenty times what any layout builds.
const PLATFORM_BITS := 8


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Hello -----------------------------------------------------------------

static func write_hello(
	player_id: int,
	tick_rate: int,
	server_tick: int,
	team_count: int,
	survival_seconds: float,
	showdown_seconds: float,
	handover_seconds: float
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(tick_rate, 9)
	w.write_varint(server_tick)
	w.write_uint(clampi(team_count, 1, 7), TEAM_BITS)
	w.write_float_range(survival_seconds, 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(showdown_seconds, 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(handover_seconds, 0.0, 120.0, 10)
	return w.to_bytes()


static func read_hello(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var tick_rate := r.read_uint(9)
	var server_tick := r.read_varint()
	var team_count := r.read_uint(TEAM_BITS)
	var survival := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var showdown := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var handover := r.read_float_range(0.0, 120.0, 10)
	return {
		"player_id": player_id,
		"tick_rate": tick_rate,
		"server_tick": server_tick,
		"team_count": team_count,
		"survival_seconds": survival,
		"showdown_seconds": showdown,
		"handover_seconds": handover,
		"ok": r.ok(),
	}


# --- The map ---------------------------------------------------------------

## The whole of this round's geometry.
##
## [b]Nine numbers, and the client builds the identical field from them.[/b] The layout id
## chooses which cells carry a platform and where the bridges go; the rest is the scale the
## server is playing at, which an operator may have changed with a cvar. A client that
## guessed any of them would build a field whose platform seven is somewhere else — and
## every snapshot after that would move the wrong floor.
static func write_toys(map_id: StringName, net_ids: PackedInt64Array) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), ID_BYTES)
	w.write_varint(net_ids.size())
	for id in net_ids:
		w.write_varint(maxi(int(id), 0))
	return w.to_bytes()


static func read_toys(r: DotNetReader) -> Dictionary:
	var map_id := StringName(r.read_string(ID_BYTES))
	var count := r.read_varint()
	var ids := PackedInt64Array()
	if count < 0 or count > 256:
		return {"map_id": map_id, "ids": ids, "ok": false}
	for i in count:
		ids.append(r.read_varint())
	return {"map_id": map_id, "ids": ids, "ok": r.ok()}


static func write_layout(
	layout_id: StringName,
	columns: int,
	rows: int,
	column_pitch: float,
	row_pitch: float,
	platform_size: float,
	deck_height: float,
	pitch_scale: float,
	stiffness_scale: float,
	cells: Array[Vector3i],
	row_pitch_scale: float = 1.0,
	row_shift: float = 0.0
) -> PackedByteArray:
	var w := _w()
	w.write_string(String(layout_id), ID_BYTES)
	w.write_uint(clampi(columns, 1, 63), 6)
	w.write_uint(clampi(rows, 1, 15), 4)
	# [b]Half a millimetre on every length, and the first version was two centimetres.[/b]
	# These are sent ONCE a round, so the bits are free — and what they buy is the client's
	# platform seven being in the same place as the server's rather than near it. A 14-bit
	# pitch over 128 m is 8 mm, which compounds across five columns into 2 cm of floor that
	# is somewhere else, and the edge of a platform is exactly where a player is standing
	# when that matters.
	w.write_float_range(column_pitch, 0.0, 128.0, 18)
	w.write_float_range(row_pitch, 0.0, 256.0, 19)
	w.write_float_range(platform_size, 0.0, 64.0, 17)
	w.write_float_range(deck_height, 0.0, 512.0, 20)
	w.write_float_range(pitch_scale, 0.0, 4.0, 16)
	w.write_float_range(stiffness_scale, 0.0, 4.0, 16)
	# The rows' own scale, which only the chequerboard moves off one. A client that built
	# it at the configured spacing would put its second row 11.4 m from the server's.
	w.write_float_range(row_pitch_scale, 0.0, 4.0, 16)
	# And how far the field is moved along the rows, which only the chequerboard does.
	w.write_float_range(row_shift, -2.0, 2.0, 16)

	# The field itself, one cell at a time. Fifteen bits each and never more than a couple of
	# dozen of them, which is thirty-odd bytes once a round for the one thing both ends have
	# to agree about exactly.
	w.write_uint(clampi(cells.size(), 0, (1 << PLATFORM_BITS) - 1), PLATFORM_BITS)

	for cell: Vector3i in cells:
		w.write_uint(clampi(cell.x, 0, 63), 6)
		w.write_uint(clampi(cell.y, 0, 15), 4)
		# The kind in two bits and the level in three: see `ScLayouts.make_cell`. The tower and
		# the stepped islands are the reason this is not a bool any more, and a client that
		# read one would build a ramp as a flat bridge at the wrong height.
		w.write_uint(clampi(cell.z & 3, 0, 3), 2)
		w.write_uint(clampi((cell.z >> 2) & 7, 0, 7), 3)

	return w.to_bytes()


static func read_layout(r: DotNetReader) -> Dictionary:
	var layout_id := r.read_string(ID_BYTES)
	var columns := r.read_uint(6)
	var rows := r.read_uint(4)
	var column_pitch := r.read_float_range(0.0, 128.0, 18)
	var row_pitch := r.read_float_range(0.0, 256.0, 19)
	var platform_size := r.read_float_range(0.0, 64.0, 17)
	var deck_height := r.read_float_range(0.0, 512.0, 20)
	var pitch_scale := r.read_float_range(0.0, 4.0, 16)
	var stiffness_scale := r.read_float_range(0.0, 4.0, 16)
	var row_pitch_scale := r.read_float_range(0.0, 4.0, 16)
	var row_shift := r.read_float_range(-2.0, 2.0, 16)

	var count := r.read_uint(PLATFORM_BITS)
	var cells: Array[Vector3i] = []

	for _i in range(count):
		var column := r.read_uint(6)
		var row := r.read_uint(4)
		var kind := r.read_uint(2)
		var level := r.read_uint(3)
		cells.append(Vector3i(column, row, kind | (level << 2)))

	return {
		"layout_id": StringName(layout_id),
		"cells": cells,
		"columns": columns,
		"rows": rows,
		"column_pitch": column_pitch,
		"row_pitch": row_pitch,
		"platform_size": platform_size,
		"deck_height": deck_height,
		"pitch_scale": pitch_scale,
		"stiffness_scale": stiffness_scale,
		"row_pitch_scale": row_pitch_scale,
		"row_shift": row_shift,
		"ok": r.ok(),
	}


## Which net id moves which platform.
##
## [b]An index rather than a position, because the client already knows where it is.[/b] It
## built the same field from the same description; what it cannot work out is which of the
## server's replicated entities is the platform it calls number seven.
static func write_platform(net_id: int, index: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_uint(clampi(index, 0, (1 << PLATFORM_BITS) - 1), PLATFORM_BITS)
	return w.to_bytes()


static func read_platform(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var index := r.read_uint(PLATFORM_BITS)
	return {"net_id": net_id, "index": index, "ok": r.ok()}


static func write_collapse(index: int, why: StringName) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(index, 0, (1 << PLATFORM_BITS) - 1), PLATFORM_BITS)
	w.write_string(String(why), ID_BYTES)
	return w.to_bytes()


static func read_collapse(r: DotNetReader) -> Dictionary:
	var index := r.read_uint(PLATFORM_BITS)
	var why := r.read_string(ID_BYTES)
	return {"index": index, "why": StringName(why), "ok": r.ok()}


# --- Players ---------------------------------------------------------------

## A join, or a change to who somebody is: their name, their side, their avatar.
##
## [b]The avatar is the document, not the skin it picks[/b] — as JSON, capped at
## [constant AVATAR_BYTES], and empty for the stock person. A skin index would be smaller,
## and would make every client's reading of a document the server's, so a slot this game
## adds later would need a new wire. [b]Appended, never inserted[/b]: a field before it
## would move the team for every reader of the old layout.
static func write_join(
	player_id: int, net_id: int, display_name: String, team: int,
	avatar: DotAvatar = null
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_string(display_name, NAME_BYTES)
	w.write_uint(clampi(team, 0, 7), TEAM_BITS)
	w.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return w.to_bytes()


static func read_join(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var display_name := r.read_string(NAME_BYTES)
	var team := r.read_uint(TEAM_BITS)
	var text := r.read_string(AVATAR_BYTES)
	var avatar: DotAvatar = null

	# A document that does not parse is the stock person, not a refused join: an avatar is
	# cosmetic, and somebody who cannot be drawn as themselves can still be drawn.
	if text != "":
		var parsed: Variant = JSON.parse_string(text)

		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)

			if built.ok:
				avatar = built.value

	return {
		"player_id": player_id,
		"net_id": net_id,
		"name": display_name,
		"team": team,
		"avatar": avatar,
		"ok": r.ok(),
	}


static func write_player(player_id: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	return w.to_bytes()


static func read_player(r: DotNetReader) -> int:
	return r.read_varint()


static func write_team(player_id: int, team: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(clampi(team, 0, 7), TEAM_BITS)
	return w.to_bytes()


static func read_team(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var team := r.read_uint(TEAM_BITS)
	return {"player_id": player_id, "team": team, "ok": r.ok()}


## [param death] is how the body falls (dot-player-char's [DotPlayerDeath], the server's pick),
## last and optional, so every client draws the same fall and an older one reads the rest.
static func write_death(player_id: int, by: int, why: StringName, death: DotPlayerDeath = null) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(by)
	w.write_string(String(why), ID_BYTES)
	if death != null:
		death.write_to(w)
	return w.to_bytes()


static func read_death(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var by := r.read_varint()
	var why := r.read_string(ID_BYTES)
	var out := {"player_id": player_id, "by": by, "why": StringName(why)}
	# A byte or more left is the fall; less is the padding to the last byte.
	if r.bits_remaining() >= 8:
		out["death"] = DotPlayerDeath.read_from(r)
	out["ok"] = r.ok()
	return out


## What a survivor was handed, so a watcher's HUD can name it.
static func write_armed(player_id: int, weapon_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(String(weapon_id), ID_BYTES)
	return w.to_bytes()


static func read_armed(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var weapon_id := r.read_string(ID_BYTES)
	return {"player_id": player_id, "weapon_id": StringName(weapon_id), "ok": r.ok()}


# --- What is in the world --------------------------------------------------

## Something the world has put out: a prop, or a chopper.
##
## [param vehicle] says which catalogue [param kind_id] is in. A bit rather than a second
## message kind, because everything else about the two is identical — a net id, a scene and
## a place to put it — and two near-identical messages is two decoders to keep in step.
static func write_prop(
	net_id: int, kind_id: StringName, at: Vector3, vehicle: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(kind_id), ID_BYTES)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_bool(vehicle)
	return w.to_bytes()


static func read_prop(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var kind_id := r.read_string(ID_BYTES)
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var vehicle := r.read_bool()
	return {
		"net_id": net_id,
		"kind_id": StringName(kind_id),
		"position": at,
		"vehicle": vehicle,
		"ok": r.ok(),
	}


static func write_prop_gone(net_id: int, reason: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(reason), ID_BYTES)
	return w.to_bytes()


static func read_prop_gone(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var reason := r.read_string(ID_BYTES)
	return {"net_id": net_id, "reason": StringName(reason), "ok": r.ok()}


static func write_seat(player_id: int, net_id: int, seated: bool) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_bool(seated)
	return w.to_bytes()


static func read_seat(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var seated := r.read_bool()
	return {"player_id": player_id, "net_id": net_id, "seated": seated, "ok": r.ok()}


# --- The round -------------------------------------------------------------

## The clock, and the three numbers a client cannot count for itself.
##
## [b]`standing` is why this message exists.[/b] A client runs no platform model — its
## platforms are mirrors moved by snapshots — so counting the ones that are still up would
## count whatever it last heard, and that number is the most important one on this game's
## HUD: it is what tells a player whether there is anywhere left to stand.
static func write_clock(
	round_number: int,
	elapsed: float,
	phase: int,
	standing: int,
	alive: int,
	teams_alive: int,
	playable: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(round_number)
	w.write_float_range(clampf(elapsed, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_uint(clampi(phase, 0, 3), 2)
	w.write_uint(clampi(standing, 0, (1 << PLATFORM_BITS) - 1), PLATFORM_BITS)
	w.write_uint(clampi(alive, 0, 255), 8)
	w.write_uint(clampi(teams_alive, 0, 7), TEAM_BITS)
	w.write_bool(playable)
	return w.to_bytes()


static func read_clock(r: DotNetReader) -> Dictionary:
	var round_number := r.read_varint()
	var elapsed := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var phase := r.read_uint(2)
	var standing := r.read_uint(PLATFORM_BITS)
	var alive := r.read_uint(8)
	var teams_alive := r.read_uint(TEAM_BITS)
	var playable := r.read_bool()
	return {
		"round": round_number,
		"elapsed": elapsed,
		"phase": phase,
		"standing": standing,
		"alive": alive,
		"teams_alive": teams_alive,
		"playable": playable,
		"ok": r.ok(),
	}


static func write_round(number: int, began: bool, winner: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(number)
	w.write_bool(began)
	w.write_uint(clampi(winner, 0, 7), TEAM_BITS)
	return w.to_bytes()


static func read_round(r: DotNetReader) -> Dictionary:
	var number := r.read_varint()
	var began := r.read_bool()
	var winner := r.read_uint(TEAM_BITS)
	return {"round": number, "began": began, "winner": winner, "ok": r.ok()}


static func write_phase(phase: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(phase, 0, 3), 2)
	return w.to_bytes()


static func read_phase(r: DotNetReader) -> Dictionary:
	var phase := r.read_uint(2)
	return {"phase": phase, "ok": r.ok()}


## Something strange started or stopped, and what to shout about it.
##
## [b]The blurb travels rather than being looked up.[/b] A client with an older build of
## this game has a catalogue that does not know the new special, and the honest thing for
## it to do is print what the server said rather than nothing at all. Bounded like every
## other string here, so a server cannot put a paragraph on somebody's screen.
static func write_special(
	special_id: StringName, starting: bool, blurb: String
) -> PackedByteArray:
	var w := _w()
	w.write_string(String(special_id), ID_BYTES)
	w.write_bool(starting)
	w.write_string(blurb, TEXT_BYTES)
	return w.to_bytes()


static func read_special(r: DotNetReader) -> Dictionary:
	var special_id := r.read_string(ID_BYTES)
	var starting := r.read_bool()
	var blurb := r.read_string(TEXT_BYTES)
	return {
		"special_id": StringName(special_id),
		"starting": starting,
		"blurb": blurb,
		"ok": r.ok(),
	}


static func write_blast(at: Vector3, radius: float) -> PackedByteArray:
	var w := _w()
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float_range(radius, 0.0, 64.0, 12)
	return w.to_bytes()


static func read_blast(r: DotNetReader) -> Dictionary:
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var radius := r.read_float_range(0.0, 64.0, 12)
	return {"position": at, "radius": radius, "ok": r.ok()}


# --- Watching --------------------------------------------------------------

## A view dot-spectate decided, for the one player it belongs to.
##
## [b]The death position travels.[/b] `DotSpectatorView.to_wire` did not carry it until
## 2026-09-25, and a mirror without it puts every death camera at the world origin, which
## in this map is inside the cannon. This event stays the game's own: bit-packed and keyed
## by session, where dot-spectate's is a dictionary keyed by string. Everything else a mirror needs to
## draw the camera it already has: the players are in its world.
##
## Sessions rather than keys, as everywhere on this wire; zero is nobody.
static func write_spectate(
	viewer: int, mode: int, target: int, killer: int, death_at: Vector3
) -> PackedByteArray:
	var w := _w()
	w.write_varint(viewer)
	w.write_uint(clampi(mode, 0, 7), 3)
	w.write_varint(maxi(target, 0))
	w.write_varint(maxi(killer, 0))
	w.write_vector3_range(death_at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_spectate(r: DotNetReader) -> Dictionary:
	var viewer := r.read_varint()
	var mode := r.read_uint(3)
	var target := r.read_varint()
	var killer := r.read_varint()
	var death_at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {
		"viewer": viewer, "mode": mode, "target": target, "killer": killer,
		"death_at": death_at, "ok": r.ok(),
	}


## Next (+1), previous (-1), or the other camera (0).
static func write_ask_roam() -> PackedByteArray:
	return PackedByteArray([0])


static func write_ask_spectate(direction: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(direction, -1, 1) + 1, 2)
	return w.to_bytes()


static func read_ask_spectate(r: DotNetReader) -> Dictionary:
	var raw := r.read_uint(2)
	return {"direction": clampi(raw, 0, 2) - 1, "ok": r.ok()}


# --- Impacts ---------------------------------------------------------------

## Where something landed, and what it did to the platform. [param outcome] is
## [enum ScPlatforms.Impact].
static func write_impact(at: Vector3, outcome: int, impulse: float) -> PackedByteArray:
	var w := _w()
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_uint(clampi(outcome, 0, 3), 2)
	# Kilogram metres per second, to the nearest ten. What a client scales the noise by, and
	# nothing a client decides anything from.
	w.write_float_range(clampf(impulse, 0.0, 40000.0), 0.0, 40000.0, 12)
	return w.to_bytes()


static func read_impact(r: DotNetReader) -> Dictionary:
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var outcome := r.read_uint(2)
	var impulse := r.read_float_range(0.0, 40000.0, 12)
	return {"position": at, "outcome": outcome, "impulse": impulse, "ok": r.ok()}


# --- Asking ----------------------------------------------------------------

static func write_board() -> PackedByteArray:
	var w := _w()
	w.write_bool(true)
	return w.to_bytes()


static func write_ask_team(team: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(team, 0, 7), TEAM_BITS)
	return w.to_bytes()


static func read_ask_team(r: DotNetReader) -> Dictionary:
	var team := r.read_uint(TEAM_BITS)
	return {"team": team, "ok": r.ok()}


# --- Chat ------------------------------------------------------------------

## A chat line's own field widths. Wider than the rules allow, so a rule can be raised
## without the wire silently truncating what it lets through.
const CHAT_BYTES := 200
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48
const CHAT_KIND_BITS := 4


## Whether every [enum DotChatMessage.Kind] fits in [constant CHAT_KIND_BITS]. dot-chat owns
## that enum, so it can grow under this game; headless_net reads this.
static func chat_kinds_fit() -> bool:
	return DotChatMessage.KIND_NAMES.size() <= (1 << CHAT_KIND_BITS)


## One routed line, in [DotChatMessage]'s own wire shape.
##
## [b]Field by field rather than `var_to_bytes`, like every other message here.[/b] A
## dictionary serialised whole is a dictionary whose contents are whatever the sender put
## in it — including keys a client will happily read — and the widths below are the
## validation. `x.p` is the one meta field this game carries: the speaker's session id, so
## a client can colour a line by whose it is.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_varint(int(wire.get("n", 0)))
	w.write_uint(int(wire.get("t", 0)), 32)
	w.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	w.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	w.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("d", "")), NAME_BYTES)
	w.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var player_id := 0

	if typeof(meta) == TYPE_DICTIONARY:
		player_id = int((meta as Dictionary).get("p", 0))

	w.write_varint(maxi(player_id, 0))
	return w.to_bytes()


static func read_chat(r: DotNetReader) -> Dictionary:
	var out := {
		"n": r.read_varint(),
		"t": r.read_uint(32),
		"c": r.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := r.read_uint(CHAT_KIND_BITS)
	out["k"] = (
		DotChatMessage.KIND_NAMES[kind] if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size()
		else "say"
	)

	out["s"] = r.read_string(CHAT_KEY_BYTES)
	out["d"] = r.read_string(NAME_BYTES)
	out["w"] = r.read_string(CHAT_KEY_BYTES)
	out["m"] = r.read_string(CHAT_BYTES)

	var player_id := r.read_varint()

	if player_id > 0:
		out["x"] = {"p": player_id}

	out["ok"] = r.ok()
	return out


## What a client sends when somebody presses Enter: a channel and a line, and nothing else.
##
## [b]No speaker, no time, no colour.[/b] Everything about what a line MEANS is decided on
## the server — who said it, whether they are gagged, whether they are talking too fast,
## which channel they may use and who can hear it. A client that sent any of that would be
## a client that could claim it.
static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	w.write_string(text, CHAT_BYTES)
	return w.to_bytes()


static func read_say(r: DotNetReader) -> Dictionary:
	var out := {
		"channel": r.read_string(CHAT_CHANNEL_BYTES),
		"text": r.read_string(CHAT_BYTES),
	}
	out["ok"] = r.ok()
	return out


static func write_notice(text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(text, TEXT_BYTES)
	return w.to_bytes()


static func read_notice(r: DotNetReader) -> Dictionary:
	var text := r.read_string(TEXT_BYTES)
	return {"text": text, "ok": r.ok()}


# --- A hit ----------------------------------------------------------------------

static func write_hit(point: Vector3, killed: bool, headshot: bool) -> PackedByteArray:
	var w := _w()
	w.write_float32(point.x)
	w.write_float32(point.y)
	w.write_float32(point.z)
	w.write_bool(killed)
	w.write_bool(headshot)
	return w.to_bytes()


static func read_hit(r: DotNetReader) -> Dictionary:
	var point := Vector3(r.read_float32(), r.read_float32(), r.read_float32())
	var killed := r.read_bool()
	var headshot := r.read_bool()
	return {"point": point if point.is_finite() else Vector3.ZERO, "killed": killed, "headshot": headshot, "ok": r.ok()}
