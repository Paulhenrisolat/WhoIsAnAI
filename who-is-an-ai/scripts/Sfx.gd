extends Node
## Autoload "Sfx": simple sound manager. Loads clips from assets/audio and
## plays them by short name. One looping ambience bed + pooled one-shot players.
##
## ============================================================================
## HOW TO ADD OR CHANGE A SOUND  (edit only the SOUNDS dictionary below)
## ============================================================================
## 1. Drop your audio file (.ogg / .wav / .mp3 / .flac) into assets/audio/.
## 2. Add a line to SOUNDS:
##        "my_name": { "path": "res://assets/audio/my_file.ogg", "vol": 0.0 },
##    - "vol" is in decibels, optional (default 0). Negative = quieter.
## 3. Play it anywhere with:  Sfx.play("my_name")
##    (you can still override volume at the call site: Sfx.play("my_name", -8.0))
## To change a sound, just point its "path" to a different file. To remove one,
## delete its line. That's it - no other code to touch.
## ============================================================================
const SOUNDS := {
	"click":       { "path": "res://assets/audio/click.ogg",       "vol": 0.0 },
	"hover":       { "path": "res://assets/audio/hover.wav",       "vol": -4.0 },
	"select":      { "path": "res://assets/audio/select.wav",      "vol": 0.0 },
	"open_chat":   { "path": "res://assets/audio/open_chat.ogg",   "vol": 0.0 },
	"close_chat":  { "path": "res://assets/audio/close_chat.ogg",  "vol": 0.0 },
	"correct":     { "path": "res://assets/audio/correct.ogg",     "vol": 0.0 },
	"wrong":       { "path": "res://assets/audio/wrong.wav",       "vol": 0.0 },
	"eject":       { "path": "res://assets/audio/eject.mp3",       "vol": 1.0 },
	"intro":       { "path": "res://assets/audio/intro.flac",      "vol": -2.0 },
	"match_found": { "path": "res://assets/audio/match_found.ogg", "vol": -3.0 },
	"joined":      { "path": "res://assets/audio/joined.wav",      "vol": 0.0 },
	"gameover":    { "path": "res://assets/audio/gameover.ogg",    "vol": 0.0 },
	"footstep1":    { "path": "res://assets/audio/footstep1.wav",    "vol": -8.0 },
	"footstep2":    { "path": "res://assets/audio/footstep2.wav",    "vol": -8.0 },
	"footstep3":    { "path": "res://assets/audio/footstep3.wav",    "vol": -8.0 },
}
const AMBIENCE := "res://assets/audio/ambience.ogg"
const POOL_SIZE := 8

var _streams := {}            # name -> AudioStream
var _vols := {}               # name -> default volume (dB)
var _pool: Array = []         # reusable AudioStreamPlayer nodes
var _pool_idx := 0
var _ambience_player: AudioStreamPlayer

const BGM := "res://assets/audio/GalacticDrift.mp3"
var _bgm_player: AudioStreamPlayer

func _ready() -> void:
	for n in SOUNDS:
		var info: Dictionary = SOUNDS[n]
		var path: String = info.get("path", "")
		if ResourceLoader.exists(path):
			_streams[n] = load(path)
			_vols[n] = float(info.get("vol", 0.0))
		else:
			push_warning("Sfx: missing clip %s" % path)
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_ambience_player = AudioStreamPlayer.new()
	_ambience_player.bus = "Master"
	_ambience_player.volume_db = -12.0
	add_child(_ambience_player)
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = "Master"
	_bgm_player.volume_db = -15.0   # ajuste le volume de la musique ici
	add_child(_bgm_player)

## Play a one-shot sound. If volume_db is left at NAN, the clip's default
## volume from the SOUNDS table is used; pass a number to override it.
func play(clip_name: String, volume_db: float = NAN) -> void:
	if not _streams.has(clip_name):
		return
	var p: AudioStreamPlayer = _pool[_pool_idx]
	_pool_idx = (_pool_idx + 1) % POOL_SIZE
	p.stream = _streams[clip_name]
	p.volume_db = _vols.get(clip_name, 0.0) if is_nan(volume_db) else volume_db
	p.play()


func start_ambience() -> void:
	if _ambience_player.playing or not ResourceLoader.exists(AMBIENCE):
		return
	var stream := load(AMBIENCE)
	# Loop the ambience bed if the import didn't already.
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_ambience_player.stream = stream
	_ambience_player.play()


func stop_ambience() -> void:
	_ambience_player.stop()


func start_bgm() -> void:
	if _bgm_player.playing or not ResourceLoader.exists(BGM):
		return
	var stream = load(BGM)
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	_bgm_player.stream = stream
	_bgm_player.play()
