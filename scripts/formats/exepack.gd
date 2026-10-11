class_name Exepack
extends RefCounted

# Unpacks a Microsoft EXEPACK-compressed MZ program (MUSEUMG.OVL) and returns its load image:
# byte (segment * 16 + offset) of the result is what the program sees at segment:offset when
# loaded at segment 0 (relocations are not applied). Returns an empty array on failure.
static func load_image(data: PackedByteArray) -> PackedByteArray:
	if data.size() < 0x20 or data[0] != 0x4D or data[1] != 0x5A:
		return PackedByteArray()
	var cblp := data.decode_u16(2)
	var cp := data.decode_u16(4)
	var hdr := data.decode_u16(8)
	var cs := data.decode_u16(0x16)
	var img_end := (cp - 1) * 512 + (cblp if cblp != 0 else 512)
	var img := data.slice(hdr * 16, img_end)
	var eh := cs * 16
	var dest_len: int
	var skip := 1
	if img[eh + 14] == 0x52 and img[eh + 15] == 0x42:
		dest_len = img.decode_u16(eh + 12)
	elif img[eh + 16] == 0x52 and img[eh + 17] == 0x42:
		dest_len = img.decode_u16(eh + 12)
		skip = img.decode_u16(eh + 14)
	else:
		return PackedByteArray()
	var comp_len := cs * 16 - (skip - 1) * 16
	var buf := PackedByteArray()
	buf.resize(maxi(dest_len * 16, comp_len))
	for i in comp_len:
		buf[i] = img[i]
	var src := comp_len
	var dst := dest_len * 16
	while src > 0 and buf[src - 1] == 0xFF:
		src -= 1
	while true:
		var op := buf[src - 1]
		var count := buf.decode_u16(src - 3)
		src -= 3
		if op & 0xFE == 0xB0:
			var fill := buf[src - 1]
			src -= 1
			dst -= count
			for i in count:
				buf[dst + i] = fill
		elif op & 0xFE == 0xB2:
			src -= count
			dst -= count
			for i in range(count - 1, -1, -1):
				buf[dst + i] = buf[src + i]
		else:
			return PackedByteArray()
		if op & 1:
			break
	return buf.slice(0, dest_len * 16)
