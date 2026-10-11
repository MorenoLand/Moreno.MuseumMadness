class_name ResArchive
extends RefCounted

const COMPRESSED := 0x8000

var entries: Array[Dictionary] = []
var _by_id := {}
var _res: FileAccess


func open(dir_path: String) -> String:
	var ndx := FileAccess.get_file_as_bytes(dir_path.path_join("MUSEUM.NDX"))
	if ndx.is_empty():
		return "Cannot read MUSEUM.NDX: %s" % error_string(FileAccess.get_open_error())
	_res = FileAccess.open(dir_path.path_join("MUSEUM.RES"), FileAccess.READ)
	if _res == null:
		return "Cannot read MUSEUM.RES: %s" % error_string(FileAccess.get_open_error())
	entries.clear()
	_by_id.clear()
	for i in ndx.size() / 16:
		var p := i * 16
		var type := ndx.decode_u16(p + 2)
		var e := {
			"id": ndx.decode_u16(p),
			"type": type & 0x7FFF,
			"compressed": (type & COMPRESSED) != 0,
			"offset": ndx.decode_u32(p + 4),
			"stored": ndx.decode_u32(p + 8),
			"size": ndx.decode_u32(p + 12),
		}
		entries.append(e)
		_by_id[e.id] = e
	return ""


func find(id: int) -> Dictionary:
	return _by_id.get(id, {})


func read(e: Dictionary) -> PackedByteArray:
	return read_part(e, 0, e.size)


func read_part(e: Dictionary, stored_offset: int, length: int) -> PackedByteArray:
	_res.seek(e.offset + stored_offset)
	if not e.compressed:
		return _res.get_buffer(length)
	var out := PackedByteArray()
	while out.size() < length:
		var unpacked := _res.get_32()
		var packed := _res.get_32()
		var src := _res.get_buffer(packed)
		src.append_array([0, 0, 0, 0])
		out.append_array(ResLz.decode_block(src, unpacked))
	return out
