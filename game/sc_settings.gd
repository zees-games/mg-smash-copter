extends DotMenuGameSettings

const ScBindings := preload("sc_bindings.gd")

## A player's own settings and the menu that changes them: how fast the view turns, how wide
## it is, how loud things are, the window, and the look of the menu itself.
##
## [codeblock]
## var settings := ScSettings.new()
## add_child(settings)
## settings.setup()                    # loads, and pushes every value at what reads it
## settings.bind_look(sampler.tunables)
## settings.bind_camera(camera)
## settings.bind_audio(audio.manager)
## settings.open()                     # Escape does this in the client
## [/codeblock]
##
## [b]dot-menu's `DotMenuGameSettings` with this game's spec[/b] (2026-10-09). It was a 250-line
## copy of mg-wipeout's file — a manager, a `match` over four keys and a bare settings
## screen — and the same copy was in five other games. What is left here is what is this
## game's: where the document lives, and the stock keys it has nothing to apply to.
##
## [b]The scopes are the family's, not this game's.[/b] `sensitivity` is ACCOUNT under the
## shared `tmc_account` namespace — a person's hand, the same number in every game here.
## `field_of_view` is SERVER_CLAMPED: a wide view is an advantage a server may cap, and
## dot-settings gives a server no way to READ it. The volumes are this machine's.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://smash_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"smash_copter"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Smash Copter"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.reduce_motion_text = "The end-of-round announcement appears at once, with nothing sliding, rising or bursting."
	s.comfort_row_text = "The end-of-round announcement appears at once."
	s.ambient_text = "Quiet sounds under the sky."
	s.not_applied = NOT_APPLIED
	# The touch Menu button sits top left, clear of the field-count line and the thumbs.
	s.menu_button_corner = &"top_left"
	s.bindings_maker = func() -> DotMenuBindings: return ScBindings.make()
	s.help_about = "Two to six teams stand on platforms balanced on pillars forty metres up while a cannon in the middle throws props at them. A platform leans toward whoever stands on it, and past sixteen degrees it comes off and takes everybody down. Stay up."
	s.help_cards = [
		["Staying up", "Shift is a brake, not a sprint: running leans a platform about three times as far as standing, so slow down to cross one somebody else is on. When you fall you are out until the next round, watching somebody on your side."],
		["The fight", "The last ninety seconds put everybody still standing on a corner pad in the sky with random weapons. The last team standing wins. Some layouts park a chopper: the pilot flies it with the movement keys and drops crates, and the passenger can shoot."],
	]
	s.help_sections = [["Mouse", [["Left", "Fire in the fight; drop a crate from the chopper; watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys"]]
	return s
