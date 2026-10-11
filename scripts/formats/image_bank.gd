class_name ImageBank
extends RefCounted

var group: int
var images: Array[Dictionary] = []
var palettes: Array[PackedByteArray] = []
var _archive: ResArchive


static func groups(archive: ResArchive) -> Array[int]:
	var out: Array[int] = []
	for e in archive.entries:
		if e.type == 2 and e.id % 1000 == 2 and not archive.find(e.id - 1).is_empty():
			out.append(e.id / 1000)
	return out


func _init(archive: ResArchive, group_id: int) -> void:
	_archive = archive
	group = group_id
	var bm := archive.read(archive.find(group * 1000 + 2))
	for p in range(0, bm.size() - 15, 16):
		images.append({
			"size": bm.decode_u32(p + 2),
			"offset": bm.decode_u32(p + 6),
			"flags": bm.decode_u16(p + 10),
			"width": bm.decode_u16(p + 12),
			"height": bm.decode_u16(p + 14),
		})
	var data := archive.read(archive.find(group * 1000))
	var end := data.size()
	while end >= 1024:
		var block := data.slice(end - 1024, end)
		var is_palette := true
		for i in range(3, 1024, 4):
			if block[i] != 0:
				is_palette = false
				break
		if not is_palette:
			break
		palettes.push_front(block)
		end -= 1024


func pixels(img: Dictionary) -> PackedByteArray:
	return _archive.read_part(_archive.find(group * 1000 + 1), img.offset, img.size)


static func to_image(px: PackedByteArray, w: int, h: int, pal: PackedByteArray) -> Image:
	var rgb := PackedByteArray()
	rgb.resize(w * h * 3)
	for i in w * h:
		var c := px[i] * 4
		for k in 3:
			var v := pal[c + k] >> 2
			rgb[i * 3 + k] = (v << 2) | (v >> 4)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb)


static func best_palette(px: PackedByteArray, w: int, h: int, pals: Array[PackedByteArray]) -> int:
	var best := 0
	var best_score := -1
	for k in pals.size():
		var pal := pals[k]
		var score := 0
		for y in range(0, h, 4):
			for x in range(0, w - 1, 2):
				var a := px[y * w + x] * 4
				var b := px[y * w + x + 1] * 4
				score += absi(pal[a] - pal[b]) + absi(pal[a + 1] - pal[b + 1]) + absi(pal[a + 2] - pal[b + 2])
		if best_score < 0 or score < best_score:
			best_score = score
			best = k
	return best
