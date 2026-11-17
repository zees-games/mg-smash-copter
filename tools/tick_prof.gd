extends "soak.gd"

## Server tick profile on the soak harness: the same game, map and stand-ins as tools/soak.gd, with each tick's
## game step timed in microseconds (the soak's own checks stay outside the timer). The first `--warm N` ticks
## are left out. `--script-top N` (Godot started with -d) adds the N GDScript functions with the most total and
## the most self time per tick. Run: godot [-d] --headless --path . res://tools/tick_prof.tscn -- --bots 24
## --minutes 1 [--script-top 30]. Prints one TICKTOTAL line (mean, p50, p99 us per tick) and TICKFUNC lines.

var _prof_warm := 640
var _prof_top := 0
var _prof_ticks := 0
var _prof_us := PackedFloat64Array()
var _prof_scripts: DotProfilerScripts = null


func _ready() -> void:
	_prof_warm = int(_arg("warm", str(_prof_warm)))
	_prof_top = int(_arg("script-top", "0"))
	super()


func _step(delta: float) -> void:
	_prof_ticks += 1
	if _prof_ticks == _prof_warm and _prof_top > 0:
		_prof_scripts = DotProfilerScripts.new()
		var started := _prof_scripts.start()
		if not started.ok:
			printerr("TICKPROF ", started.error.message)
			_prof_scripts = null
	var t0 := Time.get_ticks_usec()
	super(delta)
	if _prof_ticks > _prof_warm:
		_prof_us.append(Time.get_ticks_usec() - t0)


func _exit_tree() -> void:
	var a := _prof_us.duplicate()
	a.sort()
	var mean := 0.0
	for v in a:
		mean += v
	mean /= maxf(a.size(), 1.0)
	var at := func(p: float) -> float: return a[mini(int(p * a.size()), a.size() - 1)] if a.size() > 0 else 0.0
	print("TICKTOTAL ticks=%d mean_us=%.1f p50_us=%.1f p99_us=%.1f" % [a.size(), mean, at.call(0.5), at.call(0.99)])
	if _prof_scripts == null:
		return
	var rep := _prof_scripts.stop(100000, a.size())
	var rows: Array = rep.get("functions", [])
	for f: Dictionary in rows.slice(0, _prof_top):
		print("TICKFUNC self_us=%.1f total_us=%.1f calls=%.2f %s::%s:%d" % [f.self_ms * 1000.0, f.total_ms * 1000.0,
			f.calls_per_frame, str(f.script).get_file(), f.function, f.line])
	rows.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.total_ms > y.total_ms)
	for f: Dictionary in rows.slice(0, _prof_top):
		print("TICKINCL total_us=%.1f self_us=%.1f calls=%.2f %s::%s:%d" % [f.total_ms * 1000.0, f.self_ms * 1000.0,
			f.calls_per_frame, str(f.script).get_file(), f.function, f.line])
