extends Control

# Start-up as measured from the original (DOSBox-X, one capture per second, no input):
# MECC splash, then the title, then Mick's room and the robot, then the museum front.
# Holds are the measured times on screen, not computed from text length.

const GROUP := 28
const FONT := 32000
const SPLASH_IMAGE := 8
const SPLASH_PALETTE := 34
const SPLASH_HOLD := 10.0
const TITLE_IMAGE := 7
const TITLE_PALETTE := 11
const TITLE_PIECES := [[360, 15, 11], [413, 110, 162], [415, 129, 162], [191, 167, 175]]
const TITLE_HOLD := 5.0
const MONITOR_IMAGE := 6
const MONITOR_PALETTE := 9
const MONITOR_BLACK := 1
const MONITOR_SCREEN := Rect2i(90, 25, 186, 122)
const MONITOR_TEXT_POS := Vector2i(92, 25)
const MONITOR_WIDTH := 180
const ROBOT_LAYERS := [[422, 117, 26, 2], [423, 153, 43, 2], [424, 151, 42, 82]]
const ROBOT_HOLD := 2.0
const MICK_IMAGE := 5
const MICK_PALETTE := 8
const TEXT_X := 2
const TEXT_Y := 147
const TEXT_WIDTH := 318
const TEXT_INDENT := 2
# Door close-up (matched to the original's capture, 97% of sampled pixels): image 12, palette 13.
const FRONT_PALETTE := 13
# Scene pictures are animations from group 28's table (resource 28000, see _load_anims).
# Backgrounds are drawn with object origin (24,12); the kid's animations with origin (0,0).
const BG_ORIGIN := Vector2i(24, 12)
const KID_ORIGIN := Vector2i(0, 0)
# Exterior: anim 8 (image 9, flipped) + anim 20 (kid standing at 81,137); palettes come from the frames.
const OUTSIDE_BG := 8
const OUTSIDE_KID := 20
# Terrace walk: anim 12 (image 11) + anim 21 (32 frames, kid climbing), palette 14.
const WALK_BG := 12
const WALK_KID := 21
# Door: anim 13 (image 12) + anim 23 frame 0 (kid at the door, image 30 at 109,82), palette 13.
const DOOR_BG := 13
const DOOR_KID := 23
# Credits (credits_re.md, matched 100% against three runs): background anim 6 (image 7) with
# palette 11; pages are anims 108-113 drawn at origin (0,12), hard cuts between pages.
# Holds measured from a 0.4 s capture: title ~6 s, then 2.8, 2.9, 3.0, 2.4, 2.9, 4.0 s.
const CREDITS_BG := 6
const CREDITS_ORIGIN := Vector2i(0, 12)
const CREDITS_TITLE_HOLD := 6.0
const CREDITS_PAGES := [[108, 2.8], [109, 2.9], [110, 3.0], [111, 2.4], [112, 2.9], [113, 4.0]]
const DOOR_RECT := Rect2i(110, 75, 99, 84)
const DOOR_LOCKED_LINES := [28136, 28137, 28138]
var door_tries := 0
# Start-up beats in the original's order, measured from a capture with no input.
# [record id (0 = none), page, kind, hold seconds]
# kinds: "mick" = Mick's room with text, "robot" = monitor with text, "kiosk" = monitor with no text,
# "bedroom" = Mick's room without text, "front" = museum front with text.
const BEATS := [
	[0, 0, "bedroom", 3.0],
	[28154, 0, "mick", 36.0],
	[28154, 1, "mick", 26.0],
	[0, 0, "kiosk", 10.0],
	[28155, 0, "mick", 24.0],
	[28155, 1, "mick", 14.0],
	[28156, 0, "robot", 38.0],
	[28157, 0, "mick", 20.0],
	[28158, 0, "robot", 42.0],
	[28159, 0, "mick", 22.0],
	[28160, 0, "robot", 14.0],
	[28161, 0, "mick", 24.0],
	[28161, 1, "mick", 14.0],
	[28162, 0, "robot", 36.0],
	[28163, 0, "mick", 24.0],
	[0, 0, "bedroom", 28.0],
	[0, 0, "credits", 0.0],
	[0, 0, "outside", 2.0],
	[28131, 0, "kid", 28.0],
	[28131, 1, "kid", 28.0],
	[28131, 2, "kid", 30.0],
	[0, 0, "walk", 0.0],
]
const FRONT_DOOR_RECORD := 28132
# The kid's own talk: his portrait on the left, text on the right in the larger font (32003).
const KID_IMAGE := 10
const KID_PALETTE := 18
const KID_FONT := 32003
const KID_PORTRAIT_Y := 23
const KID_TEXT_X := 166
const KID_TEXT_Y := 62
const KID_TEXT_WIDTH := 150
# The museum-front subtitle: text on the picture, over a dark translucent band (measured from the original).
const FRONT_TEXT_X := 56
const FRONT_TEXT_Y := 162
const FRONT_TEXT_WIDTH := 250
const SCREEN_WIDTH := 320
const SCREEN_HEIGHT := 200
const MUSIC_FILE := "res://assets/decoded/song_loop.wav"
# Full DAC brightness; the original fades in 65 steps, one per retrace.
const FULL_BRIGHTNESS := 64
# Main Hall (group 0): picture N002 record 88, palette 0 of the N000 tail.
const HUB_GROUP := 0
const HUB_IMAGE := 88
const HUB_PALETTE := 0
const HUB_BAND_X1 := [77, 111, 146, 182, 218]
const HUB_BAND_X2 := [99, 133, 168, 204, 240]
const HUB_Y1 := 33
const HUB_Y2 := 41
const HUB_ROW_STEP := 10
const HUB_ROOTS := "GTSANW"

var archive: ResArchive
var bank: ImageBank
var hub_bank: ImageBank
var font: Dictionary
var busy := true
var hub_hover := -1
var picture: TextureRect
var dac: ShaderMaterial
var music: AudioStreamPlayer
var step := 0
var skip_hold := false
var kid_font: Dictionary
var band: ColorRect
var subtitle: TextureRect
# The original's mouse pointer: group 0 image 70 (10x17 arrow, tip at the image's top-left),
# drawn with the scene's palette (talk_panel_re.md). Shown only where the game takes input.
const CURSOR_IMAGE := 70
var cursor: TextureRect
var cursor_pal := PackedByteArray()


func _ready() -> void:
	archive = ResArchive.new()
	var err := archive.open("res://assets/original/")
	if err != "":
		push_error(err)
		return
	bank = ImageBank.new(archive, GROUP)
	_load_anims()
	hub_bank = ImageBank.new(archive, HUB_GROUP)
	font = ResFont.decode(archive.read(archive.find(FONT)))
	kid_font = ResFont.decode(archive.read(archive.find(KID_FONT)))

	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color.BLACK
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	dac = ShaderMaterial.new()
	dac.shader = load("res://shaders/dac.gdshader")
	dac.set_shader_parameter("brightness", 0)

	picture = TextureRect.new()
	picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.material = dac
	add_child(picture)

	band = ColorRect.new()
	band.anchor_left = 0.0
	band.anchor_right = 1.0
	band.anchor_top = 145.0 / SCREEN_HEIGHT
	band.anchor_bottom = 1.0
	band.color = Color(0, 0, 0, 0.55)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.visible = false
	add_child(band)

	# Subtitles are drawn on their own layer above the band, in white, so they stay readable.
	subtitle = TextureRect.new()
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	subtitle.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	subtitle.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle.visible = false
	add_child(subtitle)

	cursor = TextureRect.new()
	cursor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cursor.visible = false
	add_child(cursor)

	_start_music()
	_play_start_up()


# Sends 8-bit palette indices and a 256-entry palette (R,G,B,0) to the DAC shader.
func _present(px: PackedByteArray, palette: int) -> void:
	_present_with(px, bank.palettes[palette])


func _present_with(px: PackedByteArray, pal: PackedByteArray) -> void:
	if pal != cursor_pal:
		cursor_pal = pal
		_build_cursor()
	var indices := ImageTexture.create_from_image(
		Image.create_from_data(SCREEN_WIDTH, SCREEN_HEIGHT, false, Image.FORMAT_R8, px))
	picture.texture = indices
	dac.set_shader_parameter("indices", indices)
	dac.set_shader_parameter("palette", ImageTexture.create_from_image(
		Image.create_from_data(256, 1, false, Image.FORMAT_RGBA8, pal)))


func _set_brightness(level: int) -> void:
	dac.set_shader_parameter("brightness", level)


func _fade_out() -> void:
	for level in range(FULL_BRIGHTNESS, -1, -1):
		_set_brightness(level)
		await get_tree().process_frame


func _fade_in() -> void:
	for level in range(0, FULL_BRIGHTNESS + 1):
		_set_brightness(level)
		await get_tree().process_frame


# Waits for a hold, or until the player clicks (the port lets a click skip the rest of a hold).
func _hold(seconds: float) -> void:
	var waited := 0.0
	skip_hold = false
	while waited < seconds and not skip_hold:
		await get_tree().process_frame
		waited += get_process_delta_time()
	skip_hold = false


func _start_music() -> void:
	var stream := AudioStreamWAV.load_from_file(MUSIC_FILE)
	if stream == null:
		push_error("missing " + MUSIC_FILE)
		return
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = stream.data.size() / 2
	music = AudioStreamPlayer.new()
	music.stream = stream
	add_child(music)
	music.play()


func _splash_pixels() -> PackedByteArray:
	return bank.pixels(bank.images[SPLASH_IMAGE])


func _title_pixels() -> PackedByteArray:
	var img: Dictionary = bank.images[TITLE_IMAGE]
	var px: PackedByteArray = bank.pixels(img).duplicate()
	for piece in TITLE_PIECES:
		var part: Dictionary = bank.images[piece[0]]
		var src := bank.pixels(part)
		for y in part.height:
			for x in part.width:
				var v := src[y * part.width + x]
				if v != 0:
					px[(piece[2] + y) * SCREEN_WIDTH + piece[1] + x] = v
	return px


func _talk_pixels(text: String) -> PackedByteArray:
	var img: Dictionary = bank.images[MICK_IMAGE]
	var px: PackedByteArray = bank.pixels(img).duplicate()
	var lines := ResFont.wrap(text, font, TEXT_WIDTH, TEXT_INDENT)
	ResFont.draw(px, SCREEN_WIDTH, font, lines, TEXT_X, TEXT_Y)
	return px


func _robot_pixels() -> PackedByteArray:
	var px: PackedByteArray = bank.pixels(bank.images[MONITOR_IMAGE]).duplicate()
	for layer in ROBOT_LAYERS:
		var part: Dictionary = bank.images[layer[0]]
		var src := bank.pixels(part)
		for y in part.height:
			for x in part.width:
				var v := src[y * part.width + x]
				if v != layer[3]:
					px[(layer[2] + y) * SCREEN_WIDTH + layer[1] + x] = v
	return px


func _monitor_pixels(text: String) -> PackedByteArray:
	var px: PackedByteArray = bank.pixels(bank.images[MONITOR_IMAGE]).duplicate()
	for y in range(MONITOR_SCREEN.position.y, MONITOR_SCREEN.end.y):
		for x in range(MONITOR_SCREEN.position.x, MONITOR_SCREEN.end.x):
			px[y * SCREEN_WIDTH + x] = MONITOR_BLACK
	var lines := ResFont.wrap(text, font, MONITOR_WIDTH, 0)
	ResFont.draw(px, SCREEN_WIDTH, font, lines, MONITOR_TEXT_POS.x, MONITOR_TEXT_POS.y)
	return px


func _record_text(id: int, page: int) -> String:
	var entries := Dialogue.entries(archive.read(archive.find(id)))
	return entries[page].text


# The start-up sequence, as the original plays it. Only the front door waits for a click.
func _play_start_up() -> void:
	busy = true
	await _hold(4.0)
	_present(_splash_pixels(), SPLASH_PALETTE)
	await _fade_in()
	await _hold(SPLASH_HOLD)
	await _fade_out()

	_present(_title_pixels(), TITLE_PALETTE)
	await _fade_in()
	await _hold(TITLE_HOLD)
	await _fade_out()

	for beat in BEATS:
		var text := "" if beat[0] == 0 else _record_text(beat[0], beat[1])
		match beat[2]:
			"mick":
				_present(_talk_pixels(text), MICK_PALETTE)
			"bedroom":
				_present(bank.pixels(bank.images[MICK_IMAGE]), MICK_PALETTE)
			"kiosk":
				_present(_monitor_pixels(""), MONITOR_PALETTE)
			"kid":
				_present(_kid_pixels(text), KID_PALETTE)
			"outside":
				await _outside(beat[3])
				continue
			"walk":
				await _walk()
				continue
			"credits":
				await _credits()
				continue
			"robot":
				_present(_robot_pixels(), MONITOR_PALETTE)
				await _fade_in()
				await _hold(ROBOT_HOLD)
				await _fade_out()
				_present(_monitor_pixels(text), MONITOR_PALETTE)
		await _fade_in()
		await _hold(beat[3])
		await _fade_out()

	_present(_door_pixels(_record_text(FRONT_DOOR_RECORD, 0)), FRONT_PALETTE)
	await _fade_in()
	step = 5
	_set_cursor_visible(true)
	busy = false
	get_window().title = "Museum Madness - museum front (click the door)"


func _kid_pixels(text: String) -> PackedByteArray:
	var px := PackedByteArray()
	px.resize(SCREEN_WIDTH * SCREEN_HEIGHT)
	px.fill(0)
	var img: Dictionary = bank.images[KID_IMAGE]
	var src := bank.pixels(img)
	for y in img.height:
		for x in img.width:
			px[(KID_PORTRAIT_Y + y) * SCREEN_WIDTH + x] = src[y * img.width + x]
	var lines := ResFont.wrap(text, kid_font, KID_TEXT_WIDTH, 0)
	ResFont.draw(px, SCREEN_WIDTH, kid_font, lines, KID_TEXT_X, KID_TEXT_Y)
	return px


# Group 28's animation table (start of resource 28000): u16 count, then count u16 offsets to
# animations; an animation is u16 frame count + u16 frame offsets; a frame is u16 sprite count,
# u16 absolute offset of the frame's palette block in the same resource (palette index =
# (offset - first palette offset) / 1024), then sprites [image u16, dx s16, dy s16, flags u16].
# Flag 0x4000 mirrors the sprite horizontally (engine 17EA:E5D4 family).
const FLIP_X := 0x4000
# Animation speed: the engine adds obj+0x36 (8.8 fixed point, 0x100 = one frame) per game frame
# (1000:6C92). The game frame has no clock (no timer or retrace wait in the main loop), so the
# rate is the original's loop rate on the reference machine (DOSBox-X 3000 cycles/ms).
# Measured on the reference run (capture every ~0.25 s): frames 3 -> 25 in 2.2 s = 10 fps; the walk
# stops on frame 27 (frames 28-31 are never shown) and holds about 1 s before the fade.
const WALK_FPS := 10.0
const WALK_LAST := 27
const WALK_END_HOLD := 1.0
var anims: Array = []
var anim_palettes: Array = []


func _load_anims() -> void:
	var data := archive.read(archive.find(GROUP * 1000))
	var palette_base := data.size() - bank.palettes.size() * 1024
	var count := data.decode_u16(0)
	for a in count:
		var ao := data.decode_u16(2 + 2 * a)
		var frames: Array = []
		var pals: Array[int] = []
		for f in data.decode_u16(ao):
			var fo := data.decode_u16(ao + 2 + 2 * f)
			pals.append((data.decode_u16(fo + 2) - palette_base) / 1024)
			var sprites: Array = []
			for k in data.decode_u16(fo):
				var q := fo + 4 + 8 * k
				sprites.append([data.decode_u16(q), data.decode_s16(q + 2), data.decode_s16(q + 4), data.decode_u16(q + 6)])
			frames.append(sprites)
		anims.append(frames)
		anim_palettes.append(pals)


# The palette a frame names in the data.
func _anim_palette(a: int, f: int = 0) -> int:
	var pals: Array = anim_palettes[a]
	return pals[f % pals.size()]


# Draws animation frames onto a 320x200 index buffer. layers: [[anim, frame, origin], ...]
func _compose(layers: Array) -> PackedByteArray:
	var px := PackedByteArray()
	px.resize(SCREEN_WIDTH * SCREEN_HEIGHT)
	for layer in layers:
		var frames: Array = anims[layer[0]]
		var origin: Vector2i = layer[2]
		for s in frames[layer[1] % frames.size()]:
			var spr: Dictionary = bank.images[s[0]]
			var src := bank.pixels(spr)
			var flip: bool = (s[3] & FLIP_X) != 0
			for y in spr.height:
				var dy: int = origin.y + s[2] + y
				if dy < 0 or dy >= SCREEN_HEIGHT:
					continue
				for x in spr.width:
					var v: int = src[y * spr.width + (spr.width - 1 - x if flip else x)]
					var dx: int = origin.x + s[1] + x
					if v != 0 and dx >= 0 and dx < SCREEN_WIDTH:
						px[dy * SCREEN_WIDTH + dx] = v
	return px


func _credits() -> void:
	_present(_title_pixels(), TITLE_PALETTE)
	await _fade_in()
	await _hold(CREDITS_TITLE_HOLD)
	for page in CREDITS_PAGES:
		_present(_compose([[CREDITS_BG, 0, BG_ORIGIN], [page[0], 0, CREDITS_ORIGIN]]), _anim_palette(page[0]))
		await _hold(page[1])
	await _fade_out()


func _outside(hold: float) -> void:
	_present(_compose([[OUTSIDE_BG, 0, BG_ORIGIN], [OUTSIDE_KID, 0, KID_ORIGIN]]), _anim_palette(OUTSIDE_BG))
	await _fade_in()
	await _hold(hold)
	await _fade_out()


func _walk() -> void:
	_present(_compose([[WALK_BG, 0, BG_ORIGIN], [WALK_KID, 0, KID_ORIGIN]]), _anim_palette(WALK_BG))
	await _fade_in()
	for k in range(1, WALK_LAST + 1):
		if skip_hold:
			break
		_present(_compose([[WALK_BG, 0, BG_ORIGIN], [WALK_KID, k, KID_ORIGIN]]), _anim_palette(WALK_BG))
		await _hold(1.0 / WALK_FPS)
	_present(_compose([[WALK_BG, 0, BG_ORIGIN], [WALK_KID, WALK_LAST, KID_ORIGIN]]), _anim_palette(WALK_BG))
	await _hold(WALK_END_HOLD)
	skip_hold = false
	await _fade_out()


# Door close-up with the kid at the door and the original's talk panel (talk_panel_re.md):
# panel rows 144-199 in palette 13's green ramp (48-59), portrait group 0 image 47 at (5,153),
# text in font 32000, colour 95, at (56,162), line pitch 10. The panel's shade rule is not decoded
# (it is not a function of the background index); it is approximated by source luminance.
const PANEL_TOP := 144
const PANEL_RAMP := 48
const PANEL_RAMP_TOP := 52
const PANEL_INK := 95
const PORTRAIT_IMAGE := 47
const PORTRAIT_POS := Vector2i(5, 153)


func _door_pixels(text: String) -> PackedByteArray:
	var px := _compose([[DOOR_BG, 0, BG_ORIGIN], [DOOR_KID, 0, KID_ORIGIN]])
	var pal: PackedByteArray = bank.palettes[FRONT_PALETTE]
	for y in range(PANEL_TOP, SCREEN_HEIGHT):
		for x in SCREEN_WIDTH:
			var c: int = px[y * SCREEN_WIDTH + x] * 4
			var lum: int = (pal[c] * 30 + pal[c + 1] * 59 + pal[c + 2] * 11) / 100
			px[y * SCREEN_WIDTH + x] = mini(PANEL_RAMP + ((lum * 5) >> 8), PANEL_RAMP_TOP)
	var img: Dictionary = hub_bank.images[PORTRAIT_IMAGE]
	var src := hub_bank.pixels(img)
	for y in img.height:
		for x in img.width:
			var v: int = src[y * img.width + x]
			if v != 0:
				px[(PORTRAIT_POS.y + y) * SCREEN_WIDTH + PORTRAIT_POS.x + x] = v
	if text != "":
		var lines := ResFont.wrap(text, font, FRONT_TEXT_WIDTH, 0)
		ResFont.draw(px, SCREEN_WIDTH, font, lines, FRONT_TEXT_X, FRONT_TEXT_Y, PANEL_INK)
	return px


# White subtitle text on the overlay layer (game coordinates, 320x200).
func _show_subtitle(text: String) -> void:
	if text == "":
		subtitle.visible = false
		return
	var ink := PackedByteArray()
	ink.resize(SCREEN_WIDTH * SCREEN_HEIGHT)
	var lines := ResFont.wrap(text, font, FRONT_TEXT_WIDTH, 0)
	ResFont.draw(ink, SCREEN_WIDTH, font, lines, FRONT_TEXT_X, FRONT_TEXT_Y)
	var img := Image.create(SCREEN_WIDTH, SCREEN_HEIGHT, false, Image.FORMAT_RGBA8)
	for i in ink.size():
		if ink[i] != 0:
			img.set_pixel(i % SCREEN_WIDTH, i / SCREEN_WIDTH, Color.WHITE)
	subtitle.texture = ImageTexture.create_from_image(img)
	subtitle.visible = true


func _enter_hub() -> void:
	busy = true
	await _fade_out()
	step = 4
	_present_with(hub_bank.pixels(hub_bank.images[HUB_IMAGE]), hub_bank.palettes[HUB_PALETTE])
	await _fade_in()
	busy = false
	get_window().title = "Museum Madness - Main Hall (point at an exhibit)"


# Exhibit under a game-space point (320 x 200), or -1.
func _hub_hit(pt: Vector2i) -> int:
	for g in 5:
		for c in 5:
			var rect := Rect2i(HUB_BAND_X1[g], HUB_Y1 + HUB_ROW_STEP * c,
				HUB_BAND_X2[g] - HUB_BAND_X1[g], HUB_Y2 - HUB_Y1)
			if rect.has_point(pt):
				return 5 * g + c
	return -1


func _hub_point(event_pos: Vector2) -> Vector2i:
	var size := picture.size
	return Vector2i(int(event_pos.x * SCREEN_WIDTH / size.x), int(event_pos.y * SCREEN_HEIGHT / size.y))


func _exhibit_name(k: int) -> String:
	var scene := k + 1
	var letter := HUB_ROOTS[(scene - 1) / 5 + 1]
	return "exhibit %d (MUSEUM%s.OVL, -g%d)" % [scene, letter, (scene - 1) % 5]


# Palette colours through the DAC rule at full brightness; index 0 is transparent.
func _build_cursor() -> void:
	var img: Dictionary = hub_bank.images[CURSOR_IMAGE]
	var src := hub_bank.pixels(img)
	var out := Image.create(img.width, img.height, false, Image.FORMAT_RGBA8)
	for y in img.height:
		for x in img.width:
			var v: int = src[y * img.width + x]
			if v == 0:
				continue
			var rgb: Array[int] = []
			for k in 3:
				var v6: int = (cursor_pal[v * 4 + k] * FULL_BRIGHTNESS) >> 8
				rgb.append((v6 << 2) | (v6 >> 4))
			out.set_pixel(x, y, Color8(rgb[0], rgb[1], rgb[2]))
	cursor.texture = ImageTexture.create_from_image(out)


func _set_cursor_visible(on: bool) -> void:
	cursor.visible = on
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if on else Input.MOUSE_MODE_VISIBLE


func _process(_delta: float) -> void:
	if cursor == null or not cursor.visible or cursor.texture == null:
		return
	var scale_v := size / Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	var game_pt := Vector2(_hub_point(get_local_mouse_position()))
	cursor.position = game_pt * scale_v
	cursor.size = Vector2(cursor.texture.get_size()) * scale_v


func _gui_input(event: InputEvent) -> void:
	var clicked: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) or event.is_action_pressed("ui_accept")
	if busy:
		if clicked:
			skip_hold = true
		return
	if step == 5 and clicked:
		# Door scene (room 31). A click on the door area (room object 3, rect 110,75 99x84)
		# while it is locked cycles 28136, 28137, then 28138 for every later click
		# (DS:1D3C counter, engine 17EA:5962-5991). Entry needs the outside interaction
		# (light from the pack, the symbols), which is still being decoded.
		var pt := _hub_point(get_local_mouse_position())
		if DOOR_RECT.has_point(pt):
			_present(_door_pixels(_record_text(DOOR_LOCKED_LINES[door_tries], 0)), FRONT_PALETTE)
			door_tries = mini(door_tries + 1, DOOR_LOCKED_LINES.size() - 1)
		return
	if step == 4:
		if event is InputEventMouseMotion:
			var k := _hub_hit(_hub_point(get_local_mouse_position()))
			if k != hub_hover:
				hub_hover = k
				get_window().title = "Museum Madness - Main Hall: " + (_exhibit_name(k) if k >= 0 else "point at an exhibit")
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var hit := _hub_hit(_hub_point(get_local_mouse_position()))
			if hit >= 0:
				get_window().title = "Museum Madness - " + _exhibit_name(hit) + " selected (scene content not ported yet)"
