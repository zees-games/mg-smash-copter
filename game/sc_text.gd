extends RefCounted

## Every fixed sentence the HUD shows, looked up in dot-locale (`locales/<language>/hud.json`).
##
## One translator per process, built on first use from `--locale-language` and friends. A build with no catalogue still reads English: [method t] returns the fallback when the key is unknown, so a missing file is never a blank label.

const ScPaths := preload("sc_paths.gd")

static var _locale: DotLocale = null


## The sentence for [param key] in the player's language, else [param fallback] with its {name} placeholders filled.
static func t(key: String, fallback: String, args: Dictionary = {}) -> String:
	if _locale == null:
		_locale = _build()

	if _locale == null or not _locale.has(key):
		return _fill(fallback, args)

	return _locale.t(key, args)


## Drops the translator so the next lookup rebuilds it (a check changes the language).
static func reset() -> void:
	_locale = null


static func _build() -> DotLocale:
	var cfg := DotLocaleConfig.new()
	cfg.directory = ScPaths.rebase("res://locales")
	var layered := cfg.load_layered()

	if not layered.ok:
		cfg = DotLocaleConfig.new()
		cfg.directory = ScPaths.rebase("res://locales")

	var made := cfg.make()
	return made.value as DotLocale if made.ok else null


static func _fill(text: String, args: Dictionary) -> String:
	var out := text

	for k in args:
		out = out.replace("{%s}" % str(k), str(args[k]))

	return out
