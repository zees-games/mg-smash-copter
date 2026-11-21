extends SceneTree

const ScAudio := preload("../game/sc_audio.gd")

## Asks whether this game actually makes a noise, on a machine that has a sound card.
##
## [b]Every assertion in `headless_run` about this game's audio passes on a machine that
## cannot make one.[/b] A headless run has no audio device, so [GSAudioManager] correctly
## builds a [GSAudioSinkNull] and the suite asserts against the real manager recording
## instead of playing — which proves the catalogue, the stand-ins, the culling and the
## creak's hysteresis, and cannot prove a speaker moves. This is the audio half of what
## `tools/shot.sh` is for the picture.
##
## [b]It asks `is_playing`, not "did I get a handle"[/b], which is the lesson another game
## in this family's first probe paid for: a handle for a voice that never sounded reads as a
## sound. And it runs in `_process`, because during `_initialize` the root viewport is not
## live and an [AudioStreamPlayer] under it refuses to play.

## One of each kind that matters here: the warning from the middle of the map, the creak
## under your feet, a flat sound that is about you rather than a place, and a shot.
const PROBES: Array[StringName] = [
	ScAudio.CANNON_FIRE, ScAudio.PLATFORM_CREAK, ScAudio.YOU_ARE_OUT, ScAudio.WEAPON_SHOT,
]

## Frames to let the tree come up before asking anything.
const SETTLE := 2

var _audio: ScAudio = null
var _frame := 0
var _failed := 0

## The exit code, once there is one; see [method _finish].
var _code := -1

## Frames left before quitting, once there is a code.
var _draining := 0


func _initialize() -> void:
	GSLog.set_level(GSLog.Level.WARN)
	print("driver:  %s" % AudioServer.get_driver_name())


func _process(_delta: float) -> bool:
	_frame += 1

	if _frame < SETTLE:
		return false

	if _code >= 0:
		return _finish()

	if not GSAudioSink.device_present():
		print("")
		print("No audio device. Run this through tools/audio_probe.sh, which uses xvfb-run;")
		print("--headless gives a Dummy driver and this probe cannot say anything.")
		quit(2)
		return true

	if _audio == null:
		return _build()

	return _sound()


func _build() -> bool:
	var audio := ScAudio.new()
	audio.name = "AudioProbe"
	root.add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		print("the audio did not set up: %s" % ready_now.error.message)
		quit(1)
		return true

	_audio = audio

	var sink := audio.manager.sink as GSAudioSinkGodot

	print("sink:    %s" % audio.manager.sink.sink_name())

	if sink == null:
		print("")
		print("The device is present and the manager still built a null sink.")
		quit(1)
		return true

	print("bank:    %d entries over %d ids" % [
		sink.bank.size(), audio.manager.catalogue.ids().size()
	])
	print("files:   %d of the catalogue's paths do not exist" % [
		audio.manager.catalogue.missing_files().size()
	])
	print("")

	# Not the next frame: a voice has to be given a moment to start before `is_playing`
	# means anything.
	return false


func _sound() -> bool:
	var sink := _audio.manager.sink as GSAudioSinkGodot

	for id in PROBES:
		# Through the MANAGER, not the sink: the limits, the culling and the mixer are the
		# part a stand-in has to survive.
		var handle := _audio.manager.play_at(id, Vector3(2.0, 0.0, 0.0))
		var sounding := handle != 0 and sink.is_playing(handle)

		print("  %-18s %s" % [String(id), "sounding" if sounding else "SILENT"])

		if not sounding:
			_failed += 1

	print("")

	if _failed > 0:
		print("RESULT: %d of %d made no sound." % [_failed, PROBES.size()])
		_code = 1
	else:
		print("RESULT: all %d sounded, from %d synthesised stand-ins." % [
			PROBES.size(), sink.bank.size()
		])
		_code = 0

	# Taken down, and then a few frames for the mixer to let go, before quitting — so the
	# probe's own exit says nothing a reader has to discount. Quitting with a voice still
	# sounding leaves its stream and its playback held by the audio server, and the engine
	# reports both as leaked.
	_audio.manager.stop_all()
	root.remove_child(_audio)
	_audio.free()
	_audio = null
	_draining = 10
	return false


func _finish() -> bool:
	_draining -= 1

	if _draining > 0:
		return false

	quit(_code)
	return true
