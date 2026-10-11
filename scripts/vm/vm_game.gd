extends Control

# Runs the original MUSEUM programs on the native X86Core (via CoreView/DosMachine) and shows the
# VGA output. Emulated time follows real time: each frame runs instructions until the machine's
# clock catches up (busy waits on the retrace skip ahead inside the core).

const SCREEN_WIDTH := 320
const SCREEN_HEIGHT := 200
const FRAME_BUDGET_MS := 14
const MAX_LAG := 0.1
const INSTRUCTIONS_PER_SECOND := 3000000.0
const AUDIO_BACKLOG_FRAMES := 4410

var core: X86Core
var cpu: CoreView
var machine: DosMachine
var picture: TextureRect
var dac: ShaderMaterial
var started := false
var audio: AudioStreamPlayer
var audio_playback: AudioStreamGeneratorPlayback
# Emulated time the machine should have reached: advances with real time only, so jumps the core
# makes (skipping retrace waits) are absorbed instead of piling up and speeding the game up.
var emu_target := 0.0


func _ready() -> void:
	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color.BLACK
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	dac = ShaderMaterial.new()
	dac.shader = load("res://shaders/dac.gdshader")
	dac.set_shader_parameter("brightness", 64)
	picture = TextureRect.new()
	picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.material = dac
	add_child(picture)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	get_window().focus_exited.connect(_release_mouse)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 44100
	gen.buffer_length = 0.25
	audio = AudioStreamPlayer.new()
	audio.stream = gen
	add_child(audio)
	audio.play()
	audio_playback = audio.get_stream_playback()
	start()


func start() -> void:
	core = X86Core.new()
	# DOSBox-X reference speed: 3000 cycles/ms, about 3 million instructions per second.
	core.set_ips(INSTRUCTIONS_PER_SECOND)
	cpu = CoreView.new(core)
	machine = DosMachine.new(cpu)
	started = machine.load_program("MUSEUM.COM", "", 0x0100, 0)
	cpu.flush()


func _process(delta: float) -> void:
	if not started:
		return
	if machine.terminated:
		# The player quit the game in MUSEUM.COM.
		get_tree().quit()
		return
	emu_target += minf(delta, MAX_LAG)
	# if the machine falls more than MAX_LAG behind, drop the backlog rather than race through it
	emu_target = minf(emu_target, core.get_time() + MAX_LAG)
	if core.get_time() < emu_target:
		run_for(emu_target - core.get_time(), FRAME_BUDGET_MS)
	present()
	feed_audio()


# Sound from the emulated OPL3 and Sound Blaster, generated along emulated time.
func feed_audio() -> void:
	if audio_playback == null:
		core.take_audio(core.audio_available())
		return
	var n := mini(audio_playback.get_frames_available(), core.audio_available())
	if n > 0:
		audio_playback.push_buffer(core.take_audio(n))
	# Keep latency bounded: drop any backlog beyond a tenth of a second.
	var backlog := core.audio_available() - AUDIO_BACKLOG_FRAMES
	if backlog > 0:
		core.take_audio(backlog)


# Runs the machine for `seconds` of emulated time, at most `budget_ms` of real time.
func run_for(seconds: float, budget_ms: int) -> void:
	var target := core.get_time() + seconds
	var t0 := Time.get_ticks_msec()
	while core.get_time() < target and not machine.terminated:
		machine.service_mouse()
		var status := core.run(minf(target, core.get_time() + 0.01), 200000)
		if status == X86Core.TRAP:
			cpu.pull()
			machine.native(core.get_trap())
			cpu.flush()
			if cpu.halted:
				# a blocking read (keyboard): let time pass until input arrives
				cpu.halted = false
				core.advance(1.0 / 200.0)
		elif status == X86Core.HALTED:
			core.advance(1.0 / 1000.0)
		elif status == X86Core.FAULT:
			push_error("vm: " + core.fault_text())
			machine.terminated = true
		if Time.get_ticks_msec() - t0 > budget_ms:
			break


func present() -> void:
	var idx := ImageTexture.create_from_image(
		Image.create_from_data(SCREEN_WIDTH, SCREEN_HEIGHT, false, Image.FORMAT_R8, machine.screen_indices()))
	picture.texture = idx
	dac.set_shader_parameter("indices", idx)
	dac.set_shader_parameter("palette", ImageTexture.create_from_image(
		Image.create_from_data(256, 1, false, Image.FORMAT_RGBA8, machine.palette_rgba())))


# The game draws its own cursor and moves it from relative motion (INT 33h mickeys) clamped to
# its own limits, so an absolute host pointer drifts away from it at the edges. Like DOSBox, the
# mouse is captured while the game has focus: host motion moves a virtual pointer in game space.
# Ctrl or Alt (or Ctrl+F10, or leaving the window) releases it; a click captures it again.
var pointer := Vector2(160, 100)


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not started:
		return
	# Ctrl or Alt on its own releases the mouse (the game never reads them as keys: the BIOS
	# reports no keystroke for a bare modifier); Ctrl+F10 does too, as in DOSBox.
	if event is InputEventKey and event.pressed and not event.echo and (
			event.keycode == KEY_CTRL or event.keycode == KEY_ALT
			or (event.keycode == KEY_F10 and event.ctrl_pressed)):
		_release_mouse()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and not _captured():
		# first click only takes the mouse; it is not passed to the game
		pointer = Vector2(_game_point(get_local_mouse_position()))
		machine.mouse_update(int(pointer.x), int(pointer.y), machine.mouse_buttons)
		_capture_mouse()
		get_viewport().set_input_as_handled()
		return
	if not _captured():
		# not captured: follow the host pointer directly (absolute) so the game still responds
		if event is InputEventMouseMotion:
			var p := _game_point(get_local_mouse_position())
			pointer = Vector2(p)
			machine.mouse_update(p.x, p.y, machine.mouse_buttons)
		return
	if event is InputEventMouseMotion:
		# relative motion arrives in viewport units (the 320x200 stretched viewport); map to game pixels
		var d: Vector2 = event.relative * Vector2(float(SCREEN_WIDTH) / size.x, float(SCREEN_HEIGHT) / size.y)
		pointer = (pointer + d).clamp(Vector2.ZERO, Vector2(SCREEN_WIDTH - 1, SCREEN_HEIGHT - 1))
		machine.mouse_update(int(pointer.x), int(pointer.y), machine.mouse_buttons, d)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var bit := 1 if event.button_index == MOUSE_BUTTON_LEFT else (2 if event.button_index == MOUSE_BUTTON_RIGHT else 0)
		if bit:
			var buttons: int = machine.mouse_buttons
			buttons = (buttons | bit) if event.pressed else (buttons & ~bit)
			machine.mouse_update(int(pointer.x), int(pointer.y), buttons)
		get_viewport().set_input_as_handled()


func _game_point(pos: Vector2) -> Vector2i:
	return Vector2i(clampi(int(pos.x * SCREEN_WIDTH / size.x), 0, SCREEN_WIDTH - 1),
		clampi(int(pos.y * SCREEN_HEIGHT / size.y), 0, SCREEN_HEIGHT - 1))


func _unhandled_key_input(event: InputEvent) -> void:
	if not started or not event is InputEventKey or not event.pressed:
		return
	var code := _bios_key(event)
	if code != 0:
		machine.keys.append(code)


# BIOS scan code << 8 | ASCII for the keys the game reads.
func _bios_key(e: InputEventKey) -> int:
	match e.keycode:
		KEY_ESCAPE: return 0x011B
		KEY_ENTER, KEY_KP_ENTER: return 0x1C0D
		KEY_SPACE: return 0x3920
		KEY_BACKSPACE: return 0x0E08
		KEY_TAB: return 0x0F09
		KEY_UP: return 0x4800
		KEY_DOWN: return 0x5000
		KEY_LEFT: return 0x4B00
		KEY_RIGHT: return 0x4D00
		KEY_F1: return 0x3B00
	if e.unicode > 0 and e.unicode < 128:
		return e.unicode
	return 0
