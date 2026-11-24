extends Node
## A panel-owned transport; only listens to project audio and never writes content.

signal position_changed(value: float)
signal transport_changed()

const WAVE_BUCKETS := 2048
const AudioDecls := preload("res://src/content/audio_decl.gd")

var clock
var waveform := PackedVector2Array()
var length := 0.0
var error := ""
var active := false
var _player := AudioStreamPlayer.new()
var _source := ""
var _clock_key := ""
var _origin := 0.0
var _start_usec := 0

func _ready() -> void:
	add_child(_player)
	_player.finished.connect(_on_finished)
	set_process(false)

func configure(project: String, audio: Dictionary, next_clock) -> void:
	var rel := AudioDecls.preview_relative_path(str(audio.get("previewPath", audio.get("path", ""))))
	var signature := JSON.stringify([project, rel])
	var clock_key := JSON.stringify([next_clock.timebase, next_clock.fps,
		next_clock.beat_offset, next_clock.tempo, next_clock.is_ready()])
	if signature != _source or clock_key != _clock_key:
		stop()
	clock = next_clock
	_clock_key = clock_key
	if _source == signature:
		return
	_source = signature
	waveform = PackedVector2Array()
	length = 0.0
	error = ""
	_player.stream = null
	if project == "" or rel == "":
		error = "试听需要项目内的 WAV、OGG 或 MP3 源文件。"
		return
	var file := project.path_join(rel)
	if not FileAccess.file_exists(file):
		error = "参考音频文件未找到：%s" % rel
		return
	match rel.get_extension().to_lower():
		"wav":
			_player.stream = AudioStreamWAV.load_from_file(file)
		"ogg":
			_player.stream = AudioStreamOggVorbis.load_from_file(file)
		"mp3":
			_player.stream = AudioStreamMP3.load_from_file(file)
	if _player.stream == null or _player.stream.get_length() <= 0.0:
		error = "无法试听该文件：%s" % rel
		_player.stream = null
		return
	length = _player.stream.get_length()
	if _player.stream is AudioStreamWAV:
		waveform = _pcm_envelope(_player.stream)

func is_available() -> bool:
	return length > 0.0 and clock != null and clock.is_ready()

func play_from(value: float) -> bool:
	if not is_available():
		return false
	var second := float(clock.seconds_at(value))
	if not is_finite(second) or second >= length:
		return false
	_origin = second
	_start_usec = Time.get_ticks_usec()
	if second >= 0:
		_player.play(second)
	else:
		_player.stop()
	active = true
	set_process(true)
	transport_changed.emit()
	return true

func seek(value: float) -> void:
	if active and not play_from(value):
		stop()

func stop() -> void:
	_player.stop()
	_halt()

func _halt() -> void:
	if active:
		active = false
		set_process(false)
		transport_changed.emit()

func _on_finished() -> void:
	if not active:
		return
	_halt()
	position_changed.emit(maxf(0.0, float(clock.value_at(length))))

func _process(_delta: float) -> void:
	if not active:
		return
	var second := _origin + float(Time.get_ticks_usec() - _start_usec) / 1000000.0
	if _player.playing:
		second = _player.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
		second = maxf(second, _origin)
	elif _origin < 0.0 and second >= 0.0:
		_origin = 0.0
		_player.play()
		second = 0.0
	position_changed.emit(maxf(0.0, float(clock.value_at(minf(second, length)))))

## Decode a bounded overview for uncompressed WAV, combining both channels.
static func _pcm_envelope(stream: AudioStreamWAV) -> PackedVector2Array:
	var result := PackedVector2Array()
	var bytes_per_sample := 1 if stream.format == AudioStreamWAV.FORMAT_8_BITS else (
		2 if stream.format == AudioStreamWAV.FORMAT_16_BITS else 0)
	if bytes_per_sample == 0:
		return result
	var data := stream.data
	var channels := 2 if stream.stereo else 1
	var stride := bytes_per_sample * channels
	var frames := floori(float(data.size()) / float(stride))
	var buckets := mini(frames, WAVE_BUCKETS)
	for i in buckets:
		var first := floori(float(i) * frames / buckets)
		var last := floori(float(i + 1) * frames / buckets)
		var low := 1.0
		var high := -1.0
		# Bounded sample count even when the source is several minutes long.
		var sample_step := maxi(1, floori(float(last - first) / 96.0))
		for frame in range(first, last, sample_step):
			for ch in channels:
				var offset := frame * stride + ch * bytes_per_sample
				var sample := float(data.decode_s8(offset)) / 128.0 if bytes_per_sample == 1 \
					else float(data.decode_s16(offset)) / 32768.0
				low = minf(low, sample)
				high = maxf(high, sample)
		result.append(Vector2(low, high))
	return result
