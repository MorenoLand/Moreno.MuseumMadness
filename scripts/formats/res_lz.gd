class_name ResLz
extends RefCounted


static func decode_block(src: PackedByteArray, out_len: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(out_len)
	var o := 0
	var p := 0
	var buf := 0
	var cnt := 0
	while o < out_len:
		if cnt < 24:
			buf |= (src[p] | src[p + 1] << 8 | src[p + 2] << 16) << cnt
			p += 3
			cnt += 24
		var flag := buf & 1
		buf >>= 1
		cnt -= 1
		if flag:
			out[o] = buf & 0xFF
			o += 1
			buf >>= 8
			cnt -= 8
			continue
		var wide := buf & 1
		buf >>= 1
		cnt -= 1
		var dist_bits := 13 if wide else 10
		var dist := buf & ((1 << dist_bits) - 1)
		buf >>= dist_bits
		cnt -= dist_bits
		var n := 2
		while true:
			if cnt < 1:
				buf |= src[p] << cnt
				p += 1
				cnt += 8
			var stop := buf & 1
			buf >>= 1
			cnt -= 1
			if stop:
				break
			n += 1
		while cnt < n:
			buf |= src[p] << cnt
			p += 1
			cnt += 8
		var length := (buf & ((1 << n) - 1)) + (1 << n) - 2
		buf >>= n
		cnt -= n
		var s := o - dist - 1
		if s < 0 or o + length > out_len:
			push_error("Corrupt LZ block at output %d" % o)
			return out
		for i in length:
			out[o] = out[s + i]
			o += 1
	return out
