class_name CoreView
extends RefCounted

# Register/memory view of the native X86Core with the same surface as X86Cpu, so DosMachine's
# service code can stay unchanged. pull() copies registers out before a service runs, flush()
# writes them back after.

var core: X86Core
var r := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
var s := PackedInt32Array([0, 0, 0, 0])
var ip := 0
var flags := 2
var halted := false
var cycles := 0


func _init(a_core: X86Core) -> void:
	core = a_core


func pull() -> void:
	for i in 8:
		r[i] = core.get_reg(i)
	for i in 4:
		s[i] = core.get_sreg(i)
	ip = core.get_ip()
	flags = core.get_flags()


func flush() -> void:
	for i in 8:
		core.set_reg(i, r[i])
	for i in 4:
		core.set_sreg(i, s[i])
	core.set_ip(ip)
	core.set_flags(flags)


func get_r8(i: int) -> int:
	return (r[i] & 0xFF) if i < 4 else ((r[i - 4] >> 8) & 0xFF)


func set_r8(i: int, v: int) -> void:
	if i < 4:
		r[i] = (r[i] & 0xFF00) | (v & 0xFF)
	else:
		r[i - 4] = (r[i - 4] & 0x00FF) | ((v & 0xFF) << 8)


func rb(seg: int, off: int) -> int:
	return core.peek8((seg << 4) + (off & 0xFFFF))


func rw(seg: int, off: int) -> int:
	return rb(seg, off) | (rb(seg, off + 1) << 8)


func wb(seg: int, off: int, v: int) -> void:
	core.poke8((seg << 4) + (off & 0xFFFF), v)


func ww(seg: int, off: int, v: int) -> void:
	wb(seg, off, v)
	wb(seg, off + 1, v >> 8)


func do_interrupt(n: int) -> void:
	flush()
	core.raise_interrupt(n)
	pull()
