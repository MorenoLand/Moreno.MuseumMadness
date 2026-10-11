class_name ResFont
extends RefCounted

const FIRST_CHAR := 0x20
const CHAR_COUNT := 95


static func decode(d: PackedByteArray) -> Dictionary:
	var width := d.decode_u16(16)
	var height := d.decode_u16(18)
	var starts: Array[int] = []
	for i in CHAR_COUNT + 1:
		starts.append(d.decode_u16(20 + 2 * i))
	var ink := d[404]
	var p := 405
	var rows: Array[PackedByteArray] = []
	for r in height:
		p += 1
		var row := PackedByteArray()
		row.resize(width)
		row.fill(1)
		var got := 0
		var x := 0
		while got < width:
			var n := d[p]
			p += 1
			if n == 0:
				p += 1
				break
			got += n * 8
			for k in n:
				var b := d[p]
				p += 1
				for bit in 8:
					if x < width:
						row[x] = ink if ((b >> (7 - bit)) & 1) else 1
					x += 1
		rows.append(row)
	return {"width": width, "height": height, "starts": starts, "ink": ink, "rows": rows}


static func advance(font: Dictionary, ch: String) -> int:
	var i := ch.unicode_at(0) - FIRST_CHAR
	if i < 0 or i >= CHAR_COUNT:
		return 0
	return font.starts[i + 1] - font.starts[i]


static func wrap(text: String, font: Dictionary, width: int, indent: int) -> Array[String]:
	var lines: Array[String] = []
	var cur := ""
	var curw := 0
	for word in text.split(" "):
		var ww := 0
		for ch in word:
			ww += advance(font, ch)
		var sp := advance(font, " ") if cur != "" else 0
		if cur != "" and indent + curw + sp + ww > width:
			lines.append(cur)
			cur = word
			curw = ww
		else:
			cur = word if cur == "" else cur + " " + word
			curw += sp + ww
	if cur != "":
		lines.append(cur)
	return lines


# colour < 0 draws with the font's own ink index; otherwise with the given palette index.
static func draw(px: PackedByteArray, stride: int, font: Dictionary, lines: Array[String], x0: int, y0: int, colour: int = -1) -> void:
	var h: int = font.height
	var ink: int = font.ink
	var out: int = ink if colour < 0 else colour
	for li in lines.size():
		var pen := x0
		for ch in lines[li]:
			var i := ch.unicode_at(0) - FIRST_CHAR
			if i < 0 or i >= CHAR_COUNT:
				continue
			var gx: int = font.starts[i]
			var cw: int = font.starts[i + 1] - gx
			for r in h:
				var row: PackedByteArray = font.rows[r]
				for c in cw:
					if row[gx + c] == ink:
						var yy := y0 + li * h + r
						var xx := pen + c
						if xx >= 0 and xx < stride and yy >= 0 and yy * stride + xx < px.size():
							px[yy * stride + xx] = out
			pen += cw
