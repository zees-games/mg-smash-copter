extends RefCounted

## Smash Copter's per-layout settings: the tunables a layout's `cfg/game/mg-smash-copter/dot_map/map/<id>.yml` may set.

const GAME_ID := "mg-smash-copter"

## cvar -> constraint. Only these are accepted from a map file; anything else is logged and ignored.
const KEYS := {
	"sc_survival_seconds": {"type": "float", "min": 5.0, "max": 3600.0},
	"sc_showdown_seconds": {"type": "float", "min": 5.0, "max": 3600.0},
	"sc_gravity": {"type": "float", "min": 1.0, "max": 50.0},
	"sc_stiffness": {"type": "float", "min": 0.0, "max": 1000.0},
	"sc_motion_gain": {"type": "float", "min": 0.0, "max": 100.0},
	"sc_collapse_lean": {"type": "float", "min": 0.1, "max": 3.0},
	"sc_cannon_interval": {"type": "float", "min": 0.5, "max": 120.0},
	"sc_cannon_ramp": {"type": "float", "min": 0.05, "max": 10.0},
	"sc_cannon_max_tier": {"type": "int", "min": 1, "max": 4},
	"sc_special_chance": {"type": "float", "min": 0.0, "max": 100.0},
	"sc_chopper": {"type": "int", "min": 0, "max": 1},
	"sc_weapons": {"type": "int", "min": 1, "max": 8},
	"mp_killcam_time": {"type": "float", "min": 0.0, "max": 30.0},
}
