extends Control

# F1 save menu: exports the game's saves (everything it wrote to user://dos/) as one .zip, or
# imports such a .zip and restarts the game so it picks them up.
# Desktop uses the native file dialogs; the web build downloads the zip and imports through the
# browser's file picker.

signal closed
signal imported

const SAVE_DIR := "user://dos/"
const ZIP_NAME := "museum-madness-saves.zip"
const FONT_SIZE := 8

var status: Label
var web_import_pending := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0, 0, 0, 0.6)
	add_child(shade)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(170, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Saved games"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", FONT_SIZE + 2)
	box.add_child(title)

	_button(box, "Export saves", _export)
	_button(box, "Import saves", _import)
	if not OS.has_feature("web"):
		_button(box, "Open save folder", _open_folder)
	_button(box, "Back to the game  (F1)", _close)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(170, 0)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", FONT_SIZE)
	box.add_child(status)
	panel.reset_size()
	panel.position = (Vector2(320, 200) - panel.size) / 2


func _button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	b.pressed.connect(action)
	parent.add_child(b)


func _close() -> void:
	closed.emit()


func _save_files() -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	return DirAccess.get_files_at(SAVE_DIR)


# ---- export -------------------------------------------------------------------------------

func _export() -> void:
	var files := _save_files()
	if files.is_empty():
		status.text = "No saves yet."
		return
	var tmp := "user://" + ZIP_NAME
	var zip := ZIPPacker.new()
	if zip.open(tmp) != OK:
		status.text = "Couldn't create the zip."
		return
	for name in files:
		zip.start_file(name)
		zip.write_file(FileAccess.get_file_as_bytes(SAVE_DIR + name))
		zip.close_file()
	zip.close()
	var data := FileAccess.get_file_as_bytes(tmp)
	DirAccess.remove_absolute(tmp)
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(data, ZIP_NAME, "application/zip")
		status.text = "Downloaded %d file(s)." % files.size()
		return
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show("Export saves", OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS),
			ZIP_NAME, false, DisplayServer.FILE_DIALOG_MODE_SAVE_FILE, PackedStringArray(["*.zip"]),
			func(ok: bool, paths: PackedStringArray, _filter: int) -> void:
				if ok and not paths.is_empty():
					_write_export(paths[0], data, files.size()))
	else:
		_write_export(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join(ZIP_NAME), data, files.size())


func _write_export(path: String, data: PackedByteArray, count: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status.text = "Couldn't write %s." % path.get_file()
		return
	f.store_buffer(data)
	f.close()
	status.text = "Saved %d file(s) to %s." % [count, path.get_file()]


# ---- import -------------------------------------------------------------------------------

func _import() -> void:
	if OS.has_feature("web"):
		web_import_pending = true
		JavaScriptBridge.eval("""
			window._mmImport = null;
			var input = document.createElement('input');
			input.type = 'file';
			input.accept = '.zip';
			input.onchange = function () {
				var file = input.files[0];
				if (!file) { window._mmImport = ''; return; }
				var reader = new FileReader();
				reader.onload = function () {
					var bytes = new Uint8Array(reader.result);
					var text = '';
					for (var i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
					window._mmImport = btoa(text);
				};
				reader.readAsArrayBuffer(file);
			};
			input.click();
		""", true)
		status.text = "Choose a saves .zip..."
		return
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show("Import saves", OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS),
			"", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, PackedStringArray(["*.zip"]),
			func(ok: bool, paths: PackedStringArray, _filter: int) -> void:
				if ok and not paths.is_empty():
					_import_zip(FileAccess.get_file_as_bytes(paths[0])))
	else:
		status.text = "No file dialog here: copy saves into the save folder instead."


func _process(_delta: float) -> void:
	if not web_import_pending:
		return
	var result = JavaScriptBridge.eval("window._mmImport", true)
	if result == null:
		return
	web_import_pending = false
	if str(result) == "":
		status.text = ""
		return
	_import_zip(Marshalls.base64_to_raw(str(result)))


func _import_zip(data: PackedByteArray) -> void:
	var tmp := "user://import.zip"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	var zip := ZIPReader.new()
	if zip.open(tmp) != OK:
		status.text = "That isn't a saves zip."
		DirAccess.remove_absolute(tmp)
		return
	var names := zip.get_files()
	var count := 0
	for name in names:
		if name.ends_with("/"):
			continue
		var out := FileAccess.open(SAVE_DIR + name.get_file().to_upper(), FileAccess.WRITE)
		if out:
			out.store_buffer(zip.read_file(name))
			out.close()
			count += 1
	zip.close()
	DirAccess.remove_absolute(tmp)
	if count == 0:
		status.text = "The zip was empty."
		return
	status.text = "Imported %d file(s)." % count
	imported.emit()


# ---- folder -------------------------------------------------------------------------------

func _open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(SAVE_DIR))
