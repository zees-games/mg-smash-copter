extends CanvasLayer

const ScGame := preload("sc_game.gd")
const ScPlayer := preload("sc_player.gd")

## The clock, the health, and the two numbers that say whether this is still winnable.
##
## [b]How many platforms are left is the number that is not obvious and is the most
## important of the four.[/b] Health says how many mistakes you have left and the clock says
## how long you have to survive; neither says whether surviving is still possible. The
## platform count does: a field down to its last three is a field where standing still has
## stopped working, and a player who watches that number fall starts moving before it is too
## late rather than after.
##
## [b]And the lean of the floor you are on, which nothing else could tell you.[/b] A player
## in first person looking at the horizon cannot see the platform under their feet; the one
## in third person can see it and cannot judge it. Ten degrees is the number, and the bar
## goes red at the angle a player starts sliding.

# No `const CHANNEL`. This draws numbers from state somebody else owns and has nothing an
# operator would act on; the round, the deaths and the collapses are logged by [ScGame],
# which is where the decisions are. A channel declared and never used is a file that meant
# to say something and does not.

## Radians of lean at which the tilt bar goes red. The angle a player slides at.
const SLIDE_LEAN := 0.244

## Seconds left at which the clock turns red.
const LOW_CLOCK_SEC := 10.0

## The tilt bar's green, which the health bar shares: one "fine" colour on this HUD.
const FINE_COLOUR := Color(0.45, 0.82, 0.48)


## This game's accent over whichever theme the player picked in the menu (its highlight and
## the plates' edge). The plates, the words and their outline are the theme's, dark by default,
## so a light or high-contrast theme can change them. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(0.98, 0.86, 0.40, 0.3))
	t.set_color(&"highlight", type, Color(0.98, 0.86, 0.40))
	t.set_color(&"good", type, FINE_COLOUR)
	return t


## The Escape menu, whose theme this HUD follows (dot-menu's `follow_hud`): the menu sets the
## theme on the HUD's root now and at every theme change, and applies the player's HUD size.
## Christian's first play test (2026-10-11) asked for a darker HUD a player can restyle in
## the menu. Duck-typed and called by name, for a client shell older than dot-menu 7.
var _menu: Object = null


func follow_menu(menu: Object) -> void:
	_menu = menu
	_follow()


func _follow() -> void:
	if _root != null and _menu != null and _menu.has_method(&"follow_hud"):
		_menu.call(&"follow_hud", _root, piece_theme())

var game: ScGame = null
var player: ScPlayer = null

## Bottom right while armed: the weapon in hand and `magazine | reserve`. See [method _draw_ammo].
var ammo: DotAmmoCounter = null

## The rig the counter reads: the gun this client draws (`ScClient.weapons`), which
## `ScClient.correct_drawn` brings to the server's count once quiet.
var weapons_fn: Callable = Callable()

## Four ticks round the crosshair for a hit the server confirmed. See [method confirm_hit].
var hit_marker: DotHitMarker = null

## The clock with the phase line under it: dot-ui's [DotScoreStrip], clock alone (the
## sides' state is the field line, bottom right).
var strip: DotScoreStrip = null
## Health: dot-ui's [DotVitals], bar and number on one plate, red at a quarter.
var vitals: DotVitals = null
var _field: Label = null
var _special: Label = null
var _shout: Label = null

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null
var _tilt_back: ColorRect = null
var _tilt_fill: ColorRect = null
var _root: Control = null

## Seconds left of the big shouted line in the middle of the screen.
var _shout_for: float = 0.0

## An administrator's `blind`, over the world and under the HUD's numbers.
##
## [b]Under the numbers, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the phase and their own health still say the round is going on and
## that they are in it, which is what makes it read as "an admin did this" rather than as a
## client that stopped drawing.
##
## [b]But not under the tilt bar, which a blind hides.[/b] The bar is the floor under their
## feet drawn as a number — in this game the one thing their eyes would have told them —
## and a blind that left it would leave a player who can still balance by instrument.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and not
## instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)


func bind(p_game: ScGame, p_player: ScPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# [b]A full-rect Control between the CanvasLayer and the labels, and the first render of
	# game-buses-from-hell is why.[/b] A CanvasLayer is not a Control and does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing:
	# every label lands in the top-left corner on top of the others, and the only one
	# visible is whichever drew last, clipped in half by the edge of the screen. It reads as
	# the HUD being half-written.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# First, so every widget added below draws over it. Full rect on `_root`, which is full
	# rect on a CanvasLayer — so the whole viewport, with no safe-area inset between them to
	# leave a frame of the world showing round the edge, which is what game-arena's first
	# render of its own blind found. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	_root.add_child(blind_overlay)

	var size := 22

	# The glance pieces read their colours from the theme on the type DotHudPiece; set on
	# the root, every piece under it inherits them. See [method piece_theme].
	_root.theme = piece_theme()
	_follow()

	# The clock, and the phase line under it. Full width, because the strip centres itself
	# on its own middle; it ends above the special line at 110.
	strip = DotScoreStrip.new()
	strip.name = "Clock"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 16.0
	strip.offset_bottom = 96.0
	_root.add_child(strip)

	_special = _label(size)
	_special.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_special.offset_top = 110.0
	_special.offset_bottom = 144.0
	_special.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_special.add_theme_color_override("font_color", Color(0.98, 0.78, 0.33))

	_shout = _label(size + 20)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 190.0
	_shout.offset_bottom = 260.0
	_shout.offset_left = -520.0
	_shout.offset_right = 520.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# [b]Above the chat box, because the chat box also draws itself bottom-left.[/b] The
	# first render had the health number and the first line of chat in the same forty pixels,
	# one on top of the other — which is exactly the shape of the bug game-buses-from-hell
	# shipped with four HUD labels, and is invisible to a headless suite because a headless
	# viewport is 64 x 64 and nothing there can overlap anything.
	vitals = DotVitals.new()
	vitals.name = "Vitals"
	vitals.bar_end = 220.0
	vitals.fill_colour = FINE_COLOUR
	vitals.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	vitals.offset_left = 24.0
	vitals.offset_right = 24.0 + 340.0
	# Above the chat box's FULL log, not its first line: eight rows reached y 518 at 720 and
	# drew over the old number. ScClient.new_chat caps the box at six rows, so its log tops
	# out 162 pixels off the bottom, under this plate's 170 (it is 56 tall; checked in
	# headless_run).
	vitals.offset_top = -226.0
	vitals.offset_bottom = -170.0
	_root.add_child(vitals)


	# Bottom right, above the field line: what is in hand and how much is in it. The play test
	# found a gun with no counter anywhere; dot-ui's DotAmmoCounter is the family's one.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo.offset_left = -420.0
	ammo.offset_right = -24.0
	ammo.offset_top = -176.0
	ammo.offset_bottom = -100.0
	ammo.visible = false
	_root.add_child(ammo)

	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(hit_marker)

	_field = _label(size)
	_field.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_field.offset_left = -400.0
	_field.offset_right = -30.0
	_field.offset_top = -80.0
	_field.offset_bottom = -26.0
	_field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Bottom middle, above where the chat box's input line opens, and under nothing else:
	# the health number is bottom-left and the field bottom-right, and a player who is out
	# has no use for either.
	watching_label = _label(size)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_build_tilt()

	# A dot rather than a cross. For the whole first half there is nothing to aim at, and in
	# the second half every weapon in the pack has its own spread — so what a player needs is
	# "the point I am looking at", which is one pixel.
	var dot := ColorRect.new()
	dot.name = "Crosshair"
	dot.color = Color(1.0, 1.0, 1.0, 0.75)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dot.offset_left = -3.0
	dot.offset_top = -3.0
	dot.offset_right = 3.0
	dot.offset_bottom = 3.0
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dot)


## The one instrument in the game: how far over the floor you are standing on has gone.
func _build_tilt() -> void:
	_tilt_back = ColorRect.new()
	_tilt_back.name = "TiltBack"
	_tilt_back.color = Color(0.0, 0.0, 0.0, 0.42)
	_tilt_back.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_back.offset_left = -150.0
	_tilt_back.offset_right = 150.0
	_tilt_back.offset_top = -46.0
	_tilt_back.offset_bottom = -30.0
	_tilt_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_back)

	_tilt_fill = ColorRect.new()
	_tilt_fill.name = "TiltFill"
	_tilt_fill.color = Color(0.45, 0.82, 0.48, 0.9)
	_tilt_fill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_fill.offset_left = -150.0
	_tilt_fill.offset_right = -150.0
	_tilt_fill.offset_top = -46.0
	_tilt_fill.offset_bottom = -30.0
	_tilt_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_fill)


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	# An outline rather than a panel behind it. This HUD is drawn over a bright sky, a dark
	# floor and a grey platform in the same frame; white is unreadable over one and black
	# over another, and an outline is readable over all three and costs nothing.
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


## The spectator line, or an empty string to take it away. See [ScSpectate.line_for].
func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds. What a special announces itself
## with, and what a round ending says.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var left := game.seconds_left()
	# No clock between rounds: a plate reading 0:00 over "between rounds" said the same
	# thing twice. Red for the last ten seconds of a phase.
	var running := game.phase != ScGame.Phase.IDLE and game.sides_are_playable()
	strip.show_clock(
		DotScoreStrip.clock_text(left) if running else "", left <= LOW_CLOCK_SEC, _phase_line()
	)
	_special.text = game.special_line()

	if player != null and player.health != null:
		# Red at a quarter (DotVitals.low_fraction), which in the showdown is one burst from
		# gone and in the survival phase is one crate.
		vitals.show_vitals(player.health.health, player.health.max_health)

	_draw_ammo()

	_field.text = "%d up   %d left   %d sides" % [
		game.standing_platforms(), game.alive_count(), game.teams_alive(),
	]

	_draw_tilt()

	if _shout_for > 0.0:
		_shout_for -= delta

		if _shout_for <= 0.0:
			_shout.text = ""


## Fades [member blind_overlay] toward whether the followed player is blinded.
##
## Read off [member player] rather than pushed by anybody, because the flag arrives in a
## snapshot on a connected client and is set directly offline, and a HUD that had to be told
## would need telling from two places. Public so a check can step it.
func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if is_blind() else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0


## Whether the player this HUD follows is blinded.
func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


func _phase_line() -> String:
	if not game.sides_are_playable():
		return "waiting for players"

	match game.phase:
		ScGame.Phase.SURVIVAL:
			if player != null and player.riding:
				return "flying"
			return "stay on something"
		ScGame.Phase.HANDOVER:
			return "hold — weapons hot shortly"
		ScGame.Phase.SHOWDOWN:
			return "last team standing"
		_:
			return "between rounds"


## The tilt bar, from the platform the player is actually on.
##
## Hidden when they are not on one, because a bar reading zero while somebody is falling
## says the floor is level rather than that there is no floor.
func _draw_tilt() -> void:
	if _tilt_fill == null or _tilt_back == null:
		return

	var deck = game.platforms.deck_at(player.standing_on) if player != null and game.platforms != null else null

	# Hidden under a blind as well — see [member blind_overlay].
	if deck == null or is_blind():
		_tilt_back.visible = false
		_tilt_fill.visible = false
		return

	_tilt_back.visible = true
	_tilt_fill.visible = true

	var fraction := clampf(deck.tilt() / maxf(game.config.platform_collapse_lean, 0.001), 0.0, 1.0)
	_tilt_fill.offset_right = -150.0 + 300.0 * fraction

	var sliding := deck.tilt() >= SLIDE_LEAN

	_tilt_fill.color = (
		Color(0.92, 0.28, 0.26, 0.95) if sliding
		else Color(0.45, 0.82, 0.48, 0.9).lerp(Color(0.95, 0.76, 0.28, 0.92), fraction)
	)


## A hit the server confirmed for this player's shot: the marker, larger and red on a kill.
func confirm_hit(killed: bool, headshot: bool) -> void:
	if hit_marker != null:
		hit_marker.flash(killed, headshot)


## The counter, from the rig this player draws: the magazine and the reserve, low at a quarter
## of a magazine; a melee weapon by its name alone; hidden unarmed, dead or blind.
func _draw_ammo() -> void:
	if ammo == null:
		return

	var rig: ZeeWeaponRig = null
	if weapons_fn.is_valid():
		rig = weapons_fn.call() as ZeeWeaponRig

	var def := rig.current_def() if rig != null and is_instance_valid(rig) and rig.arsenal != null else null
	var shown := def != null and player != null and is_instance_valid(player) and player.is_alive() \
		and not is_blind()
	ammo.visible = shown

	if not shown:
		ammo.clear()
		return

	var title := def.display_name if def.display_name != "" else String(def.id)
	var held := rig.arsenal.current()

	if def.ammo_type == &"" or held == null:
		ammo.show_ammo(title, -1, -1)
		return

	var reserve := rig.arsenal.ammo().count(def.ammo_type)

	if def.magazine > 0:
		ammo.show_ammo(title, held.magazine, reserve,
			float(held.magazine) <= float(def.magazine) * 0.25, def.infinite_reserve)
	else:
		ammo.show_ammo(title, reserve, -1, reserve <= 0, false)
