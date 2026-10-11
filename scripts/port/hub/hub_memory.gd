class_name HubMemory
extends RefCounted

# The hub engine's memory, emulated as one linear buffer holding MUSEUMG.OVL's unpacked load
# image (segment 0 = image start, relocations not applied). Far pointers stored in the image's
# data use image segments, so segment * 16 + offset addresses this buffer directly.
#   data segment (DS)        3241
#   object/event pool (BSS)  2FC9   (objects at :0006, 0x4C each; 5ECC subs :0F48, 32 each;
#                                    600E subs :15F2, 14 each; events :1808, 16 groups x 4 x 16)
#   room/scene lists         2A7A
# Code addresses in handler tables are image segments too (07EA, 17C4); runtime = +0x1000.

const DS := 0x3241
const POOL := 0x2FC9
const LOAD_SEGMENT := 0x1000

var mem := PackedByteArray()


func _init(image: PackedByteArray) -> void:
	mem = image.duplicate()
	# The data segment and its BSS run past the end of the file image.
	var need := (DS + 0x1000) * 16
	if mem.size() < need:
		mem.resize(need)


static func lin(seg: int, off: int) -> int:
	return seg * 16 + (off & 0xFFFF)


func u8(seg: int, off: int) -> int:
	return mem[lin(seg, off)]


func s8(seg: int, off: int) -> int:
	var v := mem[lin(seg, off)]
	return v - 256 if v >= 128 else v


func u16(seg: int, off: int) -> int:
	return mem.decode_u16(lin(seg, off))


func s16(seg: int, off: int) -> int:
	return mem.decode_s16(lin(seg, off))


func u32(seg: int, off: int) -> int:
	return mem.decode_u32(lin(seg, off))


func w8(seg: int, off: int, v: int) -> void:
	mem[lin(seg, off)] = v & 0xFF


func w16(seg: int, off: int, v: int) -> void:
	mem.encode_u16(lin(seg, off), v & 0xFFFF)


func w32(seg: int, off: int, v: int) -> void:
	mem.encode_u32(lin(seg, off), v & 0xFFFFFFFF)


# A far pointer stored at seg:off, as [offset, segment].
func far(seg: int, off: int) -> Array[int]:
	return [u16(seg, off), u16(seg, off + 2)]


# "SEG:OFF" runtime name of a stored code pointer, as handlers are keyed (e.g. "17EA:57D4").
static func code_name(ptr: Array[int]) -> String:
	return "%04X:%04X" % [ptr[1] + LOAD_SEGMENT, ptr[0]]
