class_name X86Cpu
extends RefCounted

# Real-mode 8086/80186 interpreter (the instruction set MUSEUM's programs use: no 386 opcodes).
# Memory is a flat 1 MB + 64 KB byte array; I/O ports and interrupts go to `machine`, which
# implements in_port(port, size), out_port(port, value, size) and interrupt(n) -> bool
# (true = handled natively, false = dispatch through the interrupt vector table).
# The game now runs on the native X86Core (native/src/x86core.cpp); this GDScript version is the
# reference it was ported from.

const MEM_SIZE := 0x110000
const CF := 0x0001
const PF := 0x0004
const AF := 0x0010
const ZF := 0x0040
const SF := 0x0080
const TF := 0x0100
const IF_ := 0x0200
const DF := 0x0400
const OF := 0x0800

var mem := PackedByteArray()
var machine: Object
# registers: 0 AX, 1 CX, 2 DX, 3 BX, 4 SP, 5 BP, 6 SI, 7 DI (x86 encoding order)
var r := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
# segment registers: 0 ES, 1 CS, 2 SS, 3 DS
var s := PackedInt32Array([0, 0, 0, 0])
var ip := 0
var flags := 0x0002
var halted := false
var cycles := 0

# per-instruction decode state
var _seg_override := -1
var _rep := 0
var _modrm_mod := 0
var _modrm_reg := 0
var _modrm_rm := 0
var _ea := 0
var _ea_seg := 0

var parity := PackedByteArray()


func _init() -> void:
	mem.resize(MEM_SIZE)
	parity.resize(256)
	for i in 256:
		var b := i
		var c := 0
		while b:
			c += b & 1
			b >>= 1
		parity[i] = 1 if c % 2 == 0 else 0


# ---- memory -----------------------------------------------------------------------------

func rb(seg: int, off: int) -> int:
	return mem[((seg << 4) + (off & 0xFFFF)) & 0xFFFFF]


func rw(seg: int, off: int) -> int:
	var a := ((seg << 4) + (off & 0xFFFF)) & 0xFFFFF
	if (off & 0xFFFF) == 0xFFFF:
		return mem[a] | (mem[((seg << 4)) & 0xFFFFF] << 8)
	return mem[a] | (mem[a + 1] << 8)


func wb(seg: int, off: int, v: int) -> void:
	var a := ((seg << 4) + (off & 0xFFFF)) & 0xFFFFF
	if a >= 0xA0000 and a < 0xC0000:
		machine.vga_write(a, v & 0xFF)
		return
	mem[a] = v & 0xFF


func ww(seg: int, off: int, v: int) -> void:
	wb(seg, off, v)
	wb(seg, (off + 1) & 0xFFFF, v >> 8)


func rb_vga(seg: int, off: int) -> int:
	var a := ((seg << 4) + (off & 0xFFFF)) & 0xFFFFF
	if a >= 0xA0000 and a < 0xC0000:
		return machine.vga_read(a)
	return mem[a]


# ---- registers ----------------------------------------------------------------------------

func get_r8(i: int) -> int:
	if i < 4:
		return r[i] & 0xFF
	return (r[i - 4] >> 8) & 0xFF


func set_r8(i: int, v: int) -> void:
	if i < 4:
		r[i] = (r[i] & 0xFF00) | (v & 0xFF)
	else:
		r[i - 4] = (r[i - 4] & 0x00FF) | ((v & 0xFF) << 8)


func push(v: int) -> void:
	r[4] = (r[4] - 2) & 0xFFFF
	ww(s[2], r[4], v)


func pop() -> int:
	var v := rw(s[2], r[4])
	r[4] = (r[4] + 2) & 0xFFFF
	return v


func fetch8() -> int:
	var v := mem[((s[1] << 4) + ip) & 0xFFFFF]
	ip = (ip + 1) & 0xFFFF
	return v


func fetch16() -> int:
	var v := fetch8()
	return v | (fetch8() << 8)


func fetchs8() -> int:
	var v := fetch8()
	return v - 256 if v >= 128 else v


# ---- ModRM --------------------------------------------------------------------------------

func _decode_modrm() -> void:
	var b := fetch8()
	_modrm_mod = b >> 6
	_modrm_reg = (b >> 3) & 7
	_modrm_rm = b & 7
	if _modrm_mod == 3:
		return
	var off := 0
	var default_seg := 3
	match _modrm_rm:
		0: off = r[3] + r[6]
		1: off = r[3] + r[7]
		2:
			off = r[5] + r[6]
			default_seg = 2
		3:
			off = r[5] + r[7]
			default_seg = 2
		4: off = r[6]
		5: off = r[7]
		6:
			if _modrm_mod == 0:
				off = fetch16()
			else:
				off = r[5]
				default_seg = 2
		7: off = r[3]
	if _modrm_mod == 1:
		off += fetchs8()
	elif _modrm_mod == 2:
		off += fetch16()
	_ea = off & 0xFFFF
	_ea_seg = s[_seg_override] if _seg_override >= 0 else s[default_seg]


func rm8() -> int:
	if _modrm_mod == 3:
		return get_r8(_modrm_rm)
	return rb_vga(_ea_seg, _ea)


func rm16() -> int:
	if _modrm_mod == 3:
		return r[_modrm_rm]
	return rb_vga(_ea_seg, _ea) | (rb_vga(_ea_seg, (_ea + 1) & 0xFFFF) << 8)


func set_rm8(v: int) -> void:
	if _modrm_mod == 3:
		set_r8(_modrm_rm, v)
	else:
		wb(_ea_seg, _ea, v)


func set_rm16(v: int) -> void:
	if _modrm_mod == 3:
		r[_modrm_rm] = v & 0xFFFF
	else:
		ww(_ea_seg, _ea, v)


func data_seg() -> int:
	return s[_seg_override] if _seg_override >= 0 else s[3]


# ---- flags --------------------------------------------------------------------------------

func _szp(v: int, w: bool) -> void:
	flags &= ~(SF | ZF | PF)
	if w:
		v &= 0xFFFF
		if v & 0x8000:
			flags |= SF
	else:
		v &= 0xFF
		if v & 0x80:
			flags |= SF
	if v == 0:
		flags |= ZF
	if parity[v & 0xFF]:
		flags |= PF


func _setf(bit: int, on: bool) -> void:
	if on:
		flags |= bit
	else:
		flags &= ~bit


func alu(op: int, a: int, b: int, w: bool) -> int:
	var mask := 0xFFFF if w else 0xFF
	var sign := 0x8000 if w else 0x80
	var res := 0
	match op:
		0, 2: # ADD, ADC
			var c := (flags & CF) if op == 2 else 0
			res = a + b + c
			_setf(CF, res > mask)
			_setf(OF, ((a ^ res) & (b ^ res) & sign) != 0)
			_setf(AF, ((a ^ b ^ res) & 0x10) != 0)
		1, 4, 6: # OR, AND, XOR
			if op == 1:
				res = a | b
			elif op == 4:
				res = a & b
			else:
				res = a ^ b
			flags &= ~(CF | OF | AF)
		3, 5, 7: # SBB, SUB, CMP
			var c := (flags & CF) if op == 3 else 0
			res = a - b - c
			_setf(CF, res < 0)
			_setf(OF, ((a ^ b) & (a ^ res) & sign) != 0)
			_setf(AF, ((a ^ b ^ res) & 0x10) != 0)
	res &= mask
	_szp(res, w)
	return res


func inc_dec(v: int, dec: bool, w: bool) -> int:
	var mask := 0xFFFF if w else 0xFF
	var sign := 0x8000 if w else 0x80
	var res := (v - 1 if dec else v + 1) & mask
	if dec:
		_setf(OF, v == sign)
		_setf(AF, (v & 0xF) == 0)
	else:
		_setf(OF, res == sign)
		_setf(AF, (res & 0xF) == 0)
	_szp(res, w)
	return res


func shift(op: int, v: int, count: int, w: bool) -> int:
	var bits := 16 if w else 8
	var mask := 0xFFFF if w else 0xFF
	var sign := 0x8000 if w else 0x80
	count &= 0x1F
	if count == 0:
		return v
	var res := v
	match op:
		0: # ROL
			for i in count:
				var c := (res & sign) != 0
				res = ((res << 1) | (1 if c else 0)) & mask
			_setf(CF, (res & 1) != 0)
			_setf(OF, ((res & sign) != 0) != ((flags & CF) != 0))
			return res
		1: # ROR
			for i in count:
				var c := res & 1
				res = (res >> 1) | (sign if c else 0)
			_setf(CF, (res & sign) != 0)
			_setf(OF, ((res ^ (res << 1)) & sign) != 0)
			return res
		2: # RCL
			for i in count:
				var c := 1 if (flags & CF) else 0
				_setf(CF, (res & sign) != 0)
				res = ((res << 1) | c) & mask
			_setf(OF, ((res & sign) != 0) != ((flags & CF) != 0))
			return res
		3: # RCR
			for i in count:
				var c := sign if (flags & CF) else 0
				_setf(CF, (res & 1) != 0)
				res = (res >> 1) | c
			_setf(OF, ((res ^ (res << 1)) & sign) != 0)
			return res
		4, 6: # SHL/SAL
			if count > bits:
				res = 0
				_setf(CF, false)
			else:
				_setf(CF, ((v << (count - 1)) & sign) != 0)
				res = (v << count) & mask
			_setf(OF, ((res & sign) != 0) != ((flags & CF) != 0))
		5: # SHR
			if count > bits:
				res = 0
				_setf(CF, false)
			else:
				_setf(CF, ((v >> (count - 1)) & 1) != 0)
				res = v >> count
			_setf(OF, (v & sign) != 0)
		7: # SAR
			var sv := v - (mask + 1) if (v & sign) else v
			if count >= bits:
				res = mask if sv < 0 else 0
				_setf(CF, sv < 0)
			else:
				_setf(CF, ((sv >> (count - 1)) & 1) != 0)
				res = (sv >> count) & mask
			_setf(OF, false)
	_szp(res, w)
	return res


func cond(c: int) -> bool:
	var res := false
	match c >> 1:
		0: res = (flags & OF) != 0
		1: res = (flags & CF) != 0
		2: res = (flags & ZF) != 0
		3: res = (flags & (CF | ZF)) != 0
		4: res = (flags & SF) != 0
		5: res = (flags & PF) != 0
		6: res = ((flags & SF) != 0) != ((flags & OF) != 0)
		7: res = ((flags & ZF) != 0) or (((flags & SF) != 0) != ((flags & OF) != 0))
	return res != bool(c & 1)


# ---- interrupts ---------------------------------------------------------------------------

func do_interrupt(n: int) -> void:
	if machine.interrupt(n):
		return
	push(flags)
	push(s[1])
	push(ip)
	flags &= ~(IF_ | TF)
	ip = rw(0, n * 4)
	s[1] = rw(0, n * 4 + 2)


# ---- execution ----------------------------------------------------------------------------

func run(count: int) -> int:
	var executed := 0
	while executed < count and not halted:
		step()
		executed += 1
	cycles += executed
	return executed


func step() -> void:
	_seg_override = -1
	_rep = 0
	var op := fetch8()
	while true:
		match op:
			0x26:
				_seg_override = 0
			0x2E:
				_seg_override = 1
			0x36:
				_seg_override = 2
			0x3E:
				_seg_override = 3
			0xF2, 0xF3:
				_rep = op
			0xF0:
				pass
			_:
				break
		op = fetch8()
	_exec(op)


func _exec(op: int) -> void:
	if op < 0x40 and (op & 7) < 6:
		var alu_op := op >> 3
		var w := (op & 1) != 0
		match op & 7:
			0, 1:
				_decode_modrm()
				var a := rm16() if w else rm8()
				var b := r[_modrm_reg] if w else get_r8(_modrm_reg)
				var res := alu(alu_op, a, b, w)
				if alu_op != 7:
					if w:
						set_rm16(res)
					else:
						set_rm8(res)
			2, 3:
				_decode_modrm()
				var a := r[_modrm_reg] if w else get_r8(_modrm_reg)
				var b := rm16() if w else rm8()
				var res := alu(alu_op, a, b, w)
				if alu_op != 7:
					if w:
						r[_modrm_reg] = res
					else:
						set_r8(_modrm_reg, res)
			4:
				var res := alu(alu_op, get_r8(0), fetch8(), false)
				if alu_op != 7:
					set_r8(0, res)
			5:
				var res := alu(alu_op, r[0], fetch16(), true)
				if alu_op != 7:
					r[0] = res
		return
	match op:
		0x06: push(s[0])
		0x07: s[0] = pop()
		0x0E: push(s[1])
		0x16: push(s[2])
		0x17: s[2] = pop()
		0x1E: push(s[3])
		0x1F: s[3] = pop()
		0x27: _daa()
		0x2F: _das()
		0x37: _aaa()
		0x3F: _aas()
		0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47:
			var c := flags & CF
			r[op & 7] = inc_dec(r[op & 7], false, true)
			flags = (flags & ~CF) | c
		0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F:
			var c := flags & CF
			r[op & 7] = inc_dec(r[op & 7], true, true)
			flags = (flags & ~CF) | c
		0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x57:
			push(r[op & 7])
		0x54:
			push(r[4])
		0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F:
			r[op & 7] = pop()
		0x60: # PUSHA
			var sp0 := r[4]
			for i in 8:
				push(sp0 if i == 4 else r[i])
		0x61: # POPA
			for i in range(7, -1, -1):
				var v := pop()
				if i != 4:
					r[i] = v
		0x62: # BOUND (no exception emulation)
			_decode_modrm()
		0x68: push(fetch16())
		0x69, 0x6B:
			_decode_modrm()
			var a := _sx16(rm16())
			var b := _sx16(fetch16()) if op == 0x69 else fetchs8()
			var res := a * b
			r[_modrm_reg] = res & 0xFFFF
			var ov := res < -32768 or res > 32767
			_setf(CF, ov)
			_setf(OF, ov)
		0x6A: push(fetchs8() & 0xFFFF)
		0x6C, 0x6D, 0x6E, 0x6F:
			_string_io(op)
		0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F:
			var d := fetchs8()
			if cond(op & 0xF):
				ip = (ip + d) & 0xFFFF
		0x80, 0x81, 0x82, 0x83:
			_decode_modrm()
			var w := op & 1 == 1
			var a := rm16() if w else rm8()
			var b := 0
			if op == 0x81:
				b = fetch16()
			elif op == 0x83:
				b = fetchs8() & 0xFFFF
			else:
				b = fetch8()
			var res := alu(_modrm_reg, a, b, w)
			if _modrm_reg != 7:
				if w:
					set_rm16(res)
				else:
					set_rm8(res)
		0x84:
			_decode_modrm()
			alu(4, rm8(), get_r8(_modrm_reg), false)
		0x85:
			_decode_modrm()
			alu(4, rm16(), r[_modrm_reg], true)
		0x86:
			_decode_modrm()
			var t := rm8()
			set_rm8(get_r8(_modrm_reg))
			set_r8(_modrm_reg, t)
		0x87:
			_decode_modrm()
			var t := rm16()
			set_rm16(r[_modrm_reg])
			r[_modrm_reg] = t
		0x88:
			_decode_modrm()
			set_rm8(get_r8(_modrm_reg))
		0x89:
			_decode_modrm()
			set_rm16(r[_modrm_reg])
		0x8A:
			_decode_modrm()
			set_r8(_modrm_reg, rm8())
		0x8B:
			_decode_modrm()
			r[_modrm_reg] = rm16()
		0x8C:
			_decode_modrm()
			set_rm16(s[_modrm_reg & 3])
		0x8D:
			_decode_modrm()
			r[_modrm_reg] = _ea
		0x8E:
			_decode_modrm()
			s[_modrm_reg & 3] = rm16()
		0x8F:
			_decode_modrm()
			set_rm16(pop())
		0x90: pass
		0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97:
			var t := r[0]
			r[0] = r[op & 7]
			r[op & 7] = t
		0x98: r[0] = (0xFF00 | (r[0] & 0xFF)) if (r[0] & 0x80) else (r[0] & 0xFF)
		0x99: r[2] = 0xFFFF if (r[0] & 0x8000) else 0
		0x9A:
			var off := fetch16()
			var seg := fetch16()
			push(s[1])
			push(ip)
			s[1] = seg
			ip = off
		0x9B: pass
		0x9C: push(flags | 0xF002)
		0x9D: flags = (pop() & 0x0FD5) | 0x0002
		0x9E: flags = (flags & 0xFF00) | (get_r8(4) & 0xD5) | 0x02
		0x9F: set_r8(4, flags & 0xFF)
		0xA0: set_r8(0, rb_vga(data_seg(), fetch16()))
		0xA1:
			var o := fetch16()
			r[0] = rb_vga(data_seg(), o) | (rb_vga(data_seg(), (o + 1) & 0xFFFF) << 8)
		0xA2: wb(data_seg(), fetch16(), get_r8(0))
		0xA3: ww(data_seg(), fetch16(), r[0])
		0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF:
			_string(op)
		0xA8: alu(4, get_r8(0), fetch8(), false)
		0xA9: alu(4, r[0], fetch16(), true)
		0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7:
			set_r8(op & 7, fetch8())
		0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF:
			r[op & 7] = fetch16()
		0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:
			_decode_modrm()
			var w := op & 1 == 1
			var count := 1
			if op <= 0xC1:
				count = fetch8()
			elif op >= 0xD2:
				count = get_r8(1)
			var res := shift(_modrm_reg, rm16() if w else rm8(), count, w)
			if w:
				set_rm16(res)
			else:
				set_rm8(res)
		0xC2:
			var n := fetch16()
			ip = pop()
			r[4] = (r[4] + n) & 0xFFFF
		0xC3: ip = pop()
		0xC4, 0xC5:
			_decode_modrm()
			r[_modrm_reg] = rw(_ea_seg, _ea)
			s[0 if op == 0xC4 else 3] = rw(_ea_seg, (_ea + 2) & 0xFFFF)
		0xC6:
			_decode_modrm()
			set_rm8(fetch8())
		0xC7:
			_decode_modrm()
			set_rm16(fetch16())
		0xC8: # ENTER
			var size := fetch16()
			var level := fetch8() & 0x1F
			push(r[5])
			var frame := r[4]
			if level > 0:
				for i in range(1, level):
					r[5] = (r[5] - 2) & 0xFFFF
					push(rw(s[2], r[5]))
				push(frame)
			r[5] = frame
			r[4] = (r[4] - size) & 0xFFFF
		0xC9: # LEAVE
			r[4] = r[5]
			r[5] = pop()
		0xCA:
			var n := fetch16()
			ip = pop()
			s[1] = pop()
			r[4] = (r[4] + n) & 0xFFFF
		0xCB:
			ip = pop()
			s[1] = pop()
		0xCC: do_interrupt(3)
		0xCD: do_interrupt(fetch8())
		0xCE:
			if flags & OF:
				do_interrupt(4)
		0xCF:
			ip = pop()
			s[1] = pop()
			flags = (pop() & 0x0FD5) | 0x0002
		0xD4: # AAM
			var base := fetch8()
			if base == 0:
				base = 10
			var al := get_r8(0)
			set_r8(4, al / base)
			set_r8(0, al % base)
			_szp(get_r8(0), false)
		0xD5: # AAD
			var base := fetch8()
			var v := (get_r8(4) * base + get_r8(0)) & 0xFF
			r[0] = v
			_szp(v, false)
		0xD6: set_r8(0, 0xFF if (flags & CF) else 0)
		0xD7: set_r8(0, rb(data_seg(), (r[3] + get_r8(0)) & 0xFFFF))
		0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF:
			_decode_modrm() # x87 not emulated (unused by the game logic)
		0xE0, 0xE1, 0xE2:
			var d := fetchs8()
			r[1] = (r[1] - 1) & 0xFFFF
			var z := (flags & ZF) != 0
			var take := r[1] != 0
			if op == 0xE0:
				take = take and not z
			elif op == 0xE1:
				take = take and z
			if take:
				ip = (ip + d) & 0xFFFF
		0xE3:
			var d := fetchs8()
			if r[1] == 0:
				ip = (ip + d) & 0xFFFF
		0xE4: set_r8(0, machine.in_port(fetch8(), 1))
		0xE5: r[0] = machine.in_port(fetch8(), 2) & 0xFFFF
		0xE6: machine.out_port(fetch8(), get_r8(0), 1)
		0xE7: machine.out_port(fetch8(), r[0], 2)
		0xE8:
			var d := fetch16()
			push(ip)
			ip = (ip + d) & 0xFFFF
		0xE9:
			var d := fetch16()
			ip = (ip + d) & 0xFFFF
		0xEA:
			var off := fetch16()
			s[1] = fetch16()
			ip = off
		0xEB:
			var d := fetchs8()
			ip = (ip + d) & 0xFFFF
		0xEC: set_r8(0, machine.in_port(r[2], 1))
		0xED: r[0] = machine.in_port(r[2], 2) & 0xFFFF
		0xEE: machine.out_port(r[2], get_r8(0), 1)
		0xEF: machine.out_port(r[2], r[0], 2)
		0xF1: machine.native(fetch8())
		0xF4: halted = true
		0xF5: flags ^= CF
		0xF6, 0xF7:
			_group3(op == 0xF7)
		0xF8: flags &= ~CF
		0xF9: flags |= CF
		0xFA: flags &= ~IF_
		0xFB: flags |= IF_
		0xFC: flags &= ~DF
		0xFD: flags |= DF
		0xFE:
			_decode_modrm()
			if _modrm_reg == 0 or _modrm_reg == 1:
				var c := flags & CF
				set_rm8(inc_dec(rm8(), _modrm_reg == 1, false))
				flags = (flags & ~CF) | c
		0xFF:
			_group5()
		_:
			push_error("x86: unknown opcode %02X at %04X:%04X" % [op, s[1], (ip - 1) & 0xFFFF])
			halted = true


func _sx16(v: int) -> int:
	return v - 0x10000 if v & 0x8000 else v


func _group3(w: bool) -> void:
	_decode_modrm()
	match _modrm_reg:
		0, 1:
			if w:
				alu(4, rm16(), fetch16(), true)
			else:
				alu(4, rm8(), fetch8(), false)
		2:
			if w:
				set_rm16(~rm16() & 0xFFFF)
			else:
				set_rm8(~rm8() & 0xFF)
		3:
			var v := rm16() if w else rm8()
			var res := alu(5, 0, v, w)
			_setf(CF, v != 0)
			if w:
				set_rm16(res)
			else:
				set_rm8(res)
		4: # MUL
			if w:
				var res := r[0] * rm16()
				r[0] = res & 0xFFFF
				r[2] = (res >> 16) & 0xFFFF
				_setf(CF, r[2] != 0)
				_setf(OF, r[2] != 0)
			else:
				var res := get_r8(0) * rm8()
				r[0] = res & 0xFFFF
				_setf(CF, (res & 0xFF00) != 0)
				_setf(OF, (res & 0xFF00) != 0)
		5: # IMUL
			if w:
				var res := _sx16(r[0]) * _sx16(rm16())
				r[0] = res & 0xFFFF
				r[2] = (res >> 16) & 0xFFFF
				var ov := res < -32768 or res > 32767
				_setf(CF, ov)
				_setf(OF, ov)
			else:
				var a := get_r8(0)
				var b := rm8()
				a = a - 256 if a >= 128 else a
				b = b - 256 if b >= 128 else b
				var res := a * b
				r[0] = res & 0xFFFF
				var ov := res < -128 or res > 127
				_setf(CF, ov)
				_setf(OF, ov)
		6: # DIV
			if w:
				var d := rm16()
				var n := (r[2] << 16) | r[0]
				if d == 0 or n / d > 0xFFFF:
					do_interrupt(0)
					return
				r[0] = n / d
				r[2] = n % d
			else:
				var d := rm8()
				var n := r[0]
				if d == 0 or n / d > 0xFF:
					do_interrupt(0)
					return
				set_r8(0, n / d)
				set_r8(4, n % d)
		7: # IDIV
			if w:
				var d := _sx16(rm16())
				var n := (r[2] << 16) | r[0]
				if n & 0x80000000:
					n -= 0x100000000
				if d == 0:
					do_interrupt(0)
					return
				var q := int(n / d)
				var m := n - q * d
				if q > 32767 or q < -32768:
					do_interrupt(0)
					return
				r[0] = q & 0xFFFF
				r[2] = m & 0xFFFF
			else:
				var d := rm8()
				d = d - 256 if d >= 128 else d
				var n := _sx16(r[0])
				if d == 0:
					do_interrupt(0)
					return
				var q := int(n / d)
				var m := n - q * d
				if q > 127 or q < -128:
					do_interrupt(0)
					return
				set_r8(0, q & 0xFF)
				set_r8(4, m & 0xFF)


func _group5() -> void:
	_decode_modrm()
	match _modrm_reg:
		0, 1:
			var c := flags & CF
			set_rm16(inc_dec(rm16(), _modrm_reg == 1, true))
			flags = (flags & ~CF) | c
		2:
			var t := rm16()
			push(ip)
			ip = t
		3:
			var off := rw(_ea_seg, _ea)
			var seg := rw(_ea_seg, (_ea + 2) & 0xFFFF)
			push(s[1])
			push(ip)
			s[1] = seg
			ip = off
		4:
			ip = rm16()
		5:
			var off := rw(_ea_seg, _ea)
			s[1] = rw(_ea_seg, (_ea + 2) & 0xFFFF)
			ip = off
		6:
			push(rm16())


func _string(op: int) -> void:
	var w := op & 1 == 1
	var step_n := 2 if w else 1
	if flags & DF:
		step_n = -step_n
	var src_seg := data_seg()
	var count := r[1] if _rep else 1
	if _rep and count == 0:
		return
	while count > 0:
		match op:
			0xA4:
				wb(s[0], r[7], rb_vga(src_seg, r[6]))
				r[6] = (r[6] + step_n) & 0xFFFF
				r[7] = (r[7] + step_n) & 0xFFFF
			0xA5:
				ww(s[0], r[7], rb_vga(src_seg, r[6]) | (rb_vga(src_seg, (r[6] + 1) & 0xFFFF) << 8))
				r[6] = (r[6] + step_n) & 0xFFFF
				r[7] = (r[7] + step_n) & 0xFFFF
			0xAA:
				wb(s[0], r[7], get_r8(0))
				r[7] = (r[7] + step_n) & 0xFFFF
			0xAB:
				ww(s[0], r[7], r[0])
				r[7] = (r[7] + step_n) & 0xFFFF
			0xAC:
				set_r8(0, rb_vga(src_seg, r[6]))
				r[6] = (r[6] + step_n) & 0xFFFF
			0xAD:
				r[0] = rb_vga(src_seg, r[6]) | (rb_vga(src_seg, (r[6] + 1) & 0xFFFF) << 8)
				r[6] = (r[6] + step_n) & 0xFFFF
			0xA6, 0xA7:
				var a := rw(src_seg, r[6]) if w else rb(src_seg, r[6])
				var b := rw(s[0], r[7]) if w else rb(s[0], r[7])
				alu(7, a, b, w)
				r[6] = (r[6] + step_n) & 0xFFFF
				r[7] = (r[7] + step_n) & 0xFFFF
			0xAE, 0xAF:
				var b := rw(s[0], r[7]) if w else rb(s[0], r[7])
				alu(7, r[0] if w else get_r8(0), b, w)
				r[7] = (r[7] + step_n) & 0xFFFF
		if not _rep:
			return
		count -= 1
		r[1] = count
		if op == 0xA6 or op == 0xA7 or op == 0xAE or op == 0xAF:
			var z := (flags & ZF) != 0
			if (_rep == 0xF3 and not z) or (_rep == 0xF2 and z):
				return


func _string_io(op: int) -> void:
	var w := op & 1 == 1
	var step_n := 2 if w else 1
	if flags & DF:
		step_n = -step_n
	var count := r[1] if _rep else 1
	while count > 0:
		if op <= 0x6D:
			var v: int = machine.in_port(r[2], 2 if w else 1)
			if w:
				ww(s[0], r[7], v)
			else:
				wb(s[0], r[7], v)
			r[7] = (r[7] + step_n) & 0xFFFF
		else:
			var v := rw(data_seg(), r[6]) if w else rb(data_seg(), r[6])
			machine.out_port(r[2], v, 2 if w else 1)
			r[6] = (r[6] + step_n) & 0xFFFF
		count -= 1
		if _rep:
			r[1] = count
		else:
			return


func _daa() -> void:
	var al := get_r8(0)
	var cf := (flags & CF) != 0
	if (al & 0xF) > 9 or (flags & AF):
		al += 6
		flags |= AF
	if al > 0x9F or cf:
		al += 0x60
		flags |= CF
	set_r8(0, al)
	_szp(al, false)


func _das() -> void:
	var al := get_r8(0)
	var cf := (flags & CF) != 0
	if (al & 0xF) > 9 or (flags & AF):
		al -= 6
		flags |= AF
	if al > 0x9F or cf:
		al -= 0x60
		flags |= CF
	set_r8(0, al & 0xFF)
	_szp(al, false)


func _aaa() -> void:
	if (get_r8(0) & 0xF) > 9 or (flags & AF):
		r[0] = (r[0] + 0x106) & 0xFFFF
		flags |= AF | CF
	else:
		flags &= ~(AF | CF)
	set_r8(0, get_r8(0) & 0xF)


func _aas() -> void:
	if (get_r8(0) & 0xF) > 9 or (flags & AF):
		r[0] = (r[0] - 6) & 0xFFFF
		set_r8(4, (get_r8(4) - 1) & 0xFF)
		flags |= AF | CF
	else:
		flags &= ~(AF | CF)
	set_r8(0, get_r8(0) & 0xF)
