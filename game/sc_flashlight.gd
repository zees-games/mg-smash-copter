extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are dot-flashlight's).

const ScAmbience := preload("sc_ambience.gd")

const GAME_ID := "mg-smash-copter"

## The ambience moods whose rounds start with the light on. The sky is lit by day and its mood is snow wind, so the light starts off; a layout set at night would be added here.
const DARK_MOODS: PackedStringArray = ["interior_horror", "cave_tunnel", "outdoor_night"]


## A config with this game's defaults: F, off while the sky is lit, on in a dark mood.
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "F"
	cfg.dark_moods = DARK_MOODS
	return cfg


## The binder: `sc_flashlight_<field>` cvars, `cfg/game/mg-smash-copter/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "sc_flashlight")
	b.profile_kind = "flashlight"
	return b


## Whether a player starts a round with the light on: the sky's mood against the config's dark moods.
static func starts_on(cfg: DotFlashlightConfig, layout_id: String, mood: String = "") -> bool:
	return DotFlashlightRules.start_on(cfg, layout_id, 1.0, mood if mood != "" else String(ScAmbience.DEFAULT_MOOD))
