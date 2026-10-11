class_name RiffWav
extends RefCounted


static func is_wav(data: PackedByteArray) -> bool:
	return data.size() >= 12 and data.slice(0, 4).get_string_from_ascii() == "RIFF" and data.slice(8, 12).get_string_from_ascii() == "WAVE"


static func to_stream(data: PackedByteArray) -> AudioStreamWAV:
	if not is_wav(data):
		return null
	var stream := AudioStreamWAV.new()
	var p := 12
	while p + 8 <= data.size():
		var tag := data.slice(p, p + 4).get_string_from_ascii()
		var size := data.decode_u32(p + 4)
		if tag == "fmt ":
			stream.stereo = data.decode_u16(p + 10) == 2
			stream.mix_rate = data.decode_u32(p + 12)
			stream.format = AudioStreamWAV.FORMAT_16_BITS if data.decode_u16(p + 22) == 16 else AudioStreamWAV.FORMAT_8_BITS
		elif tag == "data":
			var pcm := data.slice(p + 8, p + 8 + size)
			if stream.format == AudioStreamWAV.FORMAT_8_BITS:
				for i in pcm.size():
					pcm[i] ^= 0x80
			stream.data = pcm
		p += 8 + size + (size & 1)
	return stream
