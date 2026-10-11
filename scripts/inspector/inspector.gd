extends Control

const ORIGINAL_DIR := "res://assets/original/"
const DECODED_DIR := "res://assets/decoded/"
const HEAD_SIZE := 64

var files: Array[Dictionary] = []
var archive: ResArchive
var mono: SystemFont
var status: Label

var file_list: ItemList
var file_hex: TextEdit

var res_list: ItemList
var res_hex: TextEdit
var res_play: Button
var res_export: Button
var res_data := PackedByteArray()
var res_entry := {}
var player: AudioStreamPlayer

var group_pick: OptionButton
var image_list: ItemList
var pal_spin: SpinBox
var auto_pal: CheckBox
var image_view: TextureRect
var image_info: Label
var groups: Array[int] = []
var bank: ImageBank
var pixels := PackedByteArray()
var current_image := {}


func _ready() -> void:
	mono = SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Courier New", "monospace"])
	player = AudioStreamPlayer.new()
	add_child(player)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	add_child(root)
	var bar := HBoxContainer.new()
	root.add_child(bar)
	bar.add_child(_button("Refresh", refresh))
	status = Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)
	tabs.add_child(_build_files_tab())
	tabs.add_child(_build_resources_tab())
	tabs.add_child(_build_images_tab())

	refresh()


func _build_files_tab() -> Control:
	var split := HSplitContainer.new()
	split.name = "Files"
	file_list = _list(320)
	file_list.item_selected.connect(_on_file_selected)
	split.add_child(file_list)
	file_hex = _text_view()
	split.add_child(file_hex)
	return split


func _build_resources_tab() -> Control:
	var split := HSplitContainer.new()
	split.name = "Resources"
	res_list = _list(360)
	res_list.item_selected.connect(_on_resource_selected)
	split.add_child(res_list)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var tools := HBoxContainer.new()
	right.add_child(tools)
	res_play = _button("Play WAV", _on_play)
	tools.add_child(res_play)
	res_export = _button("Export to assets/decoded", _on_export_resource)
	tools.add_child(res_export)
	res_hex = _text_view()
	res_hex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(res_hex)
	return split


func _build_images_tab() -> Control:
	var split := HSplitContainer.new()
	split.name = "Images"
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 300
	split.add_child(left)
	group_pick = OptionButton.new()
	group_pick.item_selected.connect(_on_group_selected)
	left.add_child(group_pick)
	image_list = _list(0)
	image_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	image_list.item_selected.connect(_on_image_selected)
	left.add_child(image_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var tools := HBoxContainer.new()
	right.add_child(tools)
	tools.add_child(_label("Palette"))
	pal_spin = SpinBox.new()
	pal_spin.value_changed.connect(func(_v): _show_image())
	tools.add_child(pal_spin)
	auto_pal = CheckBox.new()
	auto_pal.text = "Auto (heuristic)"
	auto_pal.button_pressed = true
	auto_pal.toggled.connect(func(_v): _on_image_selected(image_list.get_selected_items()[0] if image_list.is_anything_selected() else -1))
	tools.add_child(auto_pal)
	tools.add_child(_button("Export PNG", _on_export_image))
	image_info = _label("")
	tools.add_child(image_info)
	image_view = TextureRect.new()
	image_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	image_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	right.add_child(image_view)
	return split


func refresh() -> void:
	file_list.clear()
	file_hex.text = ""
	var result := scan_files(ORIGINAL_DIR)
	files = result.files
	for f in files:
		file_list.add_item("%-14s %10d bytes" % [f.name, f.size])
	if result.error != "":
		status.text = result.error
		return

	res_list.clear()
	group_pick.clear()
	image_list.clear()
	archive = ResArchive.new()
	var err := archive.open(ORIGINAL_DIR)
	if err != "":
		status.text = "%d files. %s" % [files.size(), err]
		return
	for e in archive.entries:
		res_list.add_item("%5d  type %d%s  %8d bytes" % [e.id, e.type, "z" if e.compressed else " ", e.size])
	groups = ImageBank.groups(archive)
	for g in groups:
		group_pick.add_item("Group %02d" % g)
	status.text = "%d files, %d resources, %d image groups" % [files.size(), archive.entries.size(), groups.size()]
	if not groups.is_empty():
		_on_group_selected(0)


func _on_file_selected(index: int) -> void:
	var f: Dictionary = files[index]
	var head := read_head(f.path, HEAD_SIZE)
	if head.error != "":
		file_hex.text = ""
		status.text = "%s: %s" % [f.name, head.error]
		return
	file_hex.text = "%s  (%d bytes, showing first %d)\n\n%s" % [f.name, f.size, head.bytes.size(), hex_dump(head.bytes)]
	status.text = f.path


func _on_resource_selected(index: int) -> void:
	res_entry = archive.entries[index]
	res_data = archive.read(res_entry)
	var kind := describe(res_data)
	res_play.disabled = not RiffWav.is_wav(res_data)
	res_hex.text = "id %d  type %d  %s  stored %d  unpacked %d  offset 0x%X\n%s\n\n%s" % [
		res_entry.id, res_entry.type, "compressed" if res_entry.compressed else "raw",
		res_entry.stored, res_entry.size, res_entry.offset, kind,
		hex_dump(res_data.slice(0, 256))]
	status.text = "Decoded resource %d (%d bytes)" % [res_entry.id, res_data.size()]


func _on_play() -> void:
	var stream := RiffWav.to_stream(res_data)
	if stream == null:
		status.text = "Not a RIFF WAVE resource"
		return
	player.stream = stream
	player.play()


func _on_export_resource() -> void:
	if res_entry.is_empty():
		return
	var ext: String = {"RIFF WAVE": "wav", "MIDI": "mid"}.get(describe(res_data), "bin")
	_write(DECODED_DIR.path_join("res/%05d_t%d.%s" % [res_entry.id, res_entry.type, ext]), res_data)


func _on_group_selected(index: int) -> void:
	bank = ImageBank.new(archive, groups[index])
	pal_spin.max_value = maxi(bank.palettes.size() - 1, 0)
	image_list.clear()
	for i in bank.images.size():
		var img := bank.images[i]
		image_list.add_item("%3d  %3dx%-3d  flags %04X" % [i, img.width, img.height, img.flags])
	image_view.texture = null
	status.text = "Group %02d: %d images, %d palettes" % [bank.group, bank.images.size(), bank.palettes.size()]


func _on_image_selected(index: int) -> void:
	if index < 0:
		return
	current_image = bank.images[index]
	pixels = bank.pixels(current_image)
	if auto_pal.button_pressed and not bank.palettes.is_empty():
		pal_spin.set_value_no_signal(ImageBank.best_palette(pixels, current_image.width, current_image.height, bank.palettes))
	_show_image()


func _show_image() -> void:
	if current_image.is_empty() or bank.palettes.is_empty():
		return
	var img := ImageBank.to_image(pixels, current_image.width, current_image.height, bank.palettes[int(pal_spin.value)])
	image_view.texture = ImageTexture.create_from_image(img)
	image_info.text = "%dx%d, palette %d of %d" % [current_image.width, current_image.height, int(pal_spin.value), bank.palettes.size()]


func _on_export_image() -> void:
	if image_view.texture == null:
		return
	var path := DECODED_DIR.path_join("images/g%02d_%03d_p%02d.png" % [bank.group, bank.images.find(current_image), int(pal_spin.value)])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var err := image_view.texture.get_image().save_png(path)
	status.text = "Saved %s" % path if err == OK else "Save failed: %s" % error_string(err)


func _write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status.text = "Write failed: %s" % error_string(FileAccess.get_open_error())
		return
	f.store_buffer(data)
	status.text = "Saved %s" % path


func _button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(callback)
	return b


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _list(width: int) -> ItemList:
	var l := ItemList.new()
	l.custom_minimum_size.x = width
	l.add_theme_font_override("font", mono)
	return l


func _text_view() -> TextEdit:
	var t := TextEdit.new()
	t.editable = false
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", mono)
	return t


static func describe(data: PackedByteArray) -> String:
	var magic := data.slice(0, 4).get_string_from_ascii()
	if RiffWav.is_wav(data):
		return "RIFF WAVE"
	if magic == "MThd":
		return "MIDI"
	if magic == "FONT":
		return "FONT"
	if data.size() >= 2 and data.slice(0, 2).get_string_from_ascii() == "BM":
		return "Image directory (BM records)"
	return "Unknown"


static func scan_files(dir_path: String) -> Dictionary:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return {"files": out, "error": "Cannot open %s: %s" % [dir_path, error_string(DirAccess.get_open_error())]}
	var names := dir.get_files()
	names.sort()
	for n in names:
		if n.begins_with(".") or n.ends_with(".import"):
			continue
		var path := dir_path.path_join(n)
		var fa := FileAccess.open(path, FileAccess.READ)
		var size := fa.get_length() if fa else -1
		out.append({"name": n, "path": path, "size": size})
	return {"files": out, "error": ""}


static func read_head(path: String, count: int) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return {"bytes": PackedByteArray(), "error": "Read failed: %s" % error_string(FileAccess.get_open_error())}
	var bytes := fa.get_buffer(mini(count, fa.get_length()))
	if fa.get_error() != OK and fa.get_error() != ERR_FILE_EOF:
		return {"bytes": bytes, "error": "Read failed: %s" % error_string(fa.get_error())}
	return {"bytes": bytes, "error": ""}


static func hex_dump(bytes: PackedByteArray) -> String:
	var lines := PackedStringArray()
	for row in range(0, bytes.size(), 16):
		var hex := ""
		var ascii := ""
		for i in 16:
			if row + i < bytes.size():
				var b := bytes[row + i]
				hex += "%02X " % b
				ascii += char(b) if b >= 0x20 and b < 0x7F else "."
			else:
				hex += "   "
			if i == 7:
				hex += " "
		lines.append("%08X  %s %s" % [row, hex, ascii])
	return "\n".join(lines)
