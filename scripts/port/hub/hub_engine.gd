class_name HubEngine
extends RefCounted

# Reimplementation of MUSEUMG.OVL's object system (hub, outside, maze, Main Hall), working on
# the emulated memory in HubMemory so handlers keep the original field offsets.
# Sources: raw disassembly of the unpacked engine (addresses below are runtime segments).
#   1000:5AB4 / 5AFC  load a 44-byte source list (FF-terminated)
#   1000:5C06         create one object from a source record
#   1000:5ECC / 600E  create its hit sub-objects (32 / 14 bytes)
#   1000:62C2         per-frame object pass (A handlers, movement, sub-object passes + events)
#   1000:6C92         animation step and draw
#   1000:74C2 / 7364  event slot allocation / post
#   1000:71D8 / 71C2  deliver pending events to the current object's B handler / clear them

const OBJ_BASE := 0x0006
const OBJ_SIZE := 0x4C
const OBJ_MAX := 0x32
const SUB5_BASE := 0x0F48
const SUB5_SIZE := 0x20
const SUB6_BASE := 0x15F2
const SUB6_SIZE := 0x0E
const EVENT_BASE := 0x1808

var m: HubMemory
# Handler implementations keyed by runtime address ("17EA:57D4"); each takes (engine).
var handlers := {}
var missing := {}


func _init(image: PackedByteArray) -> void:
	m = HubMemory.new(image)


# ---- current object / sub-object (globals in the pool segment) --------------------------

func cur() -> int:
	return m.u16(HubMemory.POOL, 0x1F92)


func set_cur(off: int) -> void:
	m.w16(HubMemory.POOL, 0x1F92, off)
	m.w16(HubMemory.POOL, 0x1F94, HubMemory.POOL)


func obj_offset(idx: int) -> int:
	return OBJ_BASE + idx * OBJ_SIZE


func object_count() -> int:
	return m.u16(HubMemory.POOL, 0x0004)


# Object field access on the current object.
func o8(field: int) -> int:
	return m.u8(HubMemory.POOL, cur() + field)


func o16(field: int) -> int:
	return m.u16(HubMemory.POOL, cur() + field)


func os16(field: int) -> int:
	return m.s16(HubMemory.POOL, cur() + field)


func ow8(field: int, v: int) -> void:
	m.w8(HubMemory.POOL, cur() + field, v)


func ow16(field: int, v: int) -> void:
	m.w16(HubMemory.POOL, cur() + field, v)


# ---- handler dispatch --------------------------------------------------------------------

func call_code(ptr: Array[int]) -> void:
	var key := HubMemory.code_name(ptr)
	if handlers.has(key):
		handlers[key].call(self)
	elif not missing.has(key):
		missing[key] = true
		push_warning("hub: handler %s not ported" % key)


# ---- allocation (1000:6084, 60D2, 6120) -------------------------------------------------

func _alloc(count_off: int, head_off: int, tail_off: int, list_off: int, limit: int) -> int:
	if m.u16(HubMemory.POOL, head_off) == m.u16(HubMemory.POOL, tail_off):
		var n := m.u16(HubMemory.POOL, count_off)
		if n >= limit:
			return -1
		m.w16(HubMemory.POOL, count_off, n + 1)
		return n
	var head := m.u16(HubMemory.POOL, head_off)
	var idx := m.u16(HubMemory.POOL, list_off + head * 2)
	head += 1
	if head >= 0x32:
		head = 0
	m.w16(HubMemory.POOL, head_off, head)
	return idx


func alloc_object() -> int:
	return _alloc(0x0004, 0x0EDE, 0x0EE0, 0x0EE2, OBJ_MAX)


func alloc_sub5() -> int:
	return _alloc(0x0F46, 0x1588, 0x158A, 0x158C, 0x32)


func alloc_sub6() -> int:
	return _alloc(0x15F0, 0x1796, 0x1798, 0x179A, 0x1E)


# ---- list loading (1000:5AFC) and object creation (1000:5C06) ---------------------------

func load_list(seg: int, off: int) -> void:
	while m.u8(seg, off) != 0xFF:
		create_object(seg, off)
		off += 44


func create_object(seg: int, src: int) -> int:
	var kind := m.u8(seg, src)
	var idx := -1
	var o := -1
	if kind >= 1 and kind <= 0xFE:
		idx = alloc_object()
		if idx < 0:
			return -1
		o = obj_offset(idx)
		m.w8(HubMemory.POOL, o, kind)
		m.w16(HubMemory.POOL, o + 0x06, m.u16(seg, src + 0x04))
		m.w16(HubMemory.POOL, o + 0x0C, m.u16(seg, src + 0x12))
		for i in 6:
			m.w16(HubMemory.POOL, o + 0x10 + 2 * i, m.u16(seg, src + 0x06 + 2 * i))
		m.w16(HubMemory.POOL, o + 0x30, m.u16(seg, src + 0x26))
		m.w16(HubMemory.POOL, o + 0x3C, m.u16(seg, src + 0x28))
		m.w16(HubMemory.POOL, o + 0x3E, m.u16(seg, src + 0x2A))
		var a_table := m.far(HubMemory.POOL, 0x17DA)
		var b_table := m.far(HubMemory.POOL, 0x17DE)
		m.w16(HubMemory.POOL, o + 0x02, m.u16(a_table[1], a_table[0] + kind * 4))
		m.w16(HubMemory.POOL, o + 0x04, m.u16(a_table[1], a_table[0] + kind * 4 + 2))
		m.w16(HubMemory.POOL, o + 0x08, m.u16(b_table[1], b_table[0] + kind * 4))
		m.w16(HubMemory.POOL, o + 0x0A, m.u16(b_table[1], b_table[0] + kind * 4 + 2))
		m.w16(HubMemory.POOL, o + 0x28, 0xFFFF)
		m.w16(HubMemory.POOL, o + 0x2A, 0xFFFF)
		for f in [0x1C, 0x1E, 0x20, 0x22, 0x24, 0x26]:
			m.w16(HubMemory.POOL, o + f, 0)
		m.w16(HubMemory.POOL, o + 0x2E, m.u16(seg, src + 0x24))
		m.w16(HubMemory.POOL, o + 0x0E, 0)
		m.w16(HubMemory.POOL, o + 0x32, 0xFFFF)
		for f in [0x40, 0x42, 0x44, 0x46, 0x48, 0x4A]:
			m.w16(HubMemory.POOL, o + f, 0)
	if m.u8(seg, src + 0x13) & 0x80:
		var s5 := create_sub5(seg, src)
		if s5 >= 0 and o >= 0 and m.u8(HubMemory.POOL, o + 0x0D) & 0x80:
			m.w16(HubMemory.POOL, o + 0x28, s5 * SUB5_SIZE)
	if m.u8(seg, src + 0x13) & 0x08:
		var s6 := create_sub6(seg, src)
		if s6 >= 0 and o >= 0 and m.u8(HubMemory.POOL, o + 0x0D) & 0x08:
			m.w16(HubMemory.POOL, o + 0x2A, s6 * SUB6_SIZE)
	if o >= 0:
		var saved := cur()
		var saved_idx := m.u16(HubMemory.POOL, 0x1FBC)
		set_cur(o)
		m.w16(HubMemory.POOL, 0x1FBC, idx)
		var cb_table := m.far(HubMemory.POOL, 0x17D6)
		call_code(m.far(cb_table[1], cb_table[0] + kind * 4))
		set_cur(saved)
		m.w16(HubMemory.POOL, 0x1FBC, saved_idx)
	m.w16(0x3A79, 0x0002, 1)
	return o


func create_sub5(seg: int, src: int) -> int:
	var idx := alloc_sub5()
	if idx < 0:
		return -1
	var s := SUB5_BASE + idx * SUB5_SIZE
	var sub_kind := m.u8(seg, src + 1)
	m.w8(HubMemory.POOL, s, sub_kind)
	for i in 4:
		m.w16(HubMemory.POOL, s + 8 + 2 * i, m.u16(seg, src + 0x14 + 2 * i))
	m.w16(HubMemory.POOL, s + 2, 0)
	var a_table := m.far(HubMemory.POOL, 0x17E6)
	m.w16(HubMemory.POOL, s + 4, m.u16(a_table[1], a_table[0] + sub_kind * 4))
	m.w16(HubMemory.POOL, s + 6, m.u16(a_table[1], a_table[0] + sub_kind * 4 + 2))
	for f in [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1C, 0x1E]:
		m.w16(HubMemory.POOL, s + f, 0)
	if sub_kind >= 1 and sub_kind <= 0xFE:
		var saved := m.far(HubMemory.POOL, 0x1F84)
		var saved_idx := m.u16(HubMemory.POOL, 0x1FBA)
		m.w16(HubMemory.POOL, 0x1F84, s)
		m.w16(HubMemory.POOL, 0x1F86, HubMemory.POOL)
		m.w16(HubMemory.POOL, 0x1FBA, idx)
		var cb_table := m.far(HubMemory.POOL, 0x17E2)
		call_code(m.far(cb_table[1], cb_table[0] + sub_kind * 4))
		m.w16(HubMemory.POOL, 0x1F84, saved[0])
		m.w16(HubMemory.POOL, 0x1F86, saved[1])
		m.w16(HubMemory.POOL, 0x1FBA, saved_idx)
	return idx


func create_sub6(seg: int, src: int) -> int:
	var idx := alloc_sub6()
	if idx < 0:
		return -1
	var s := SUB6_BASE + idx * SUB6_SIZE
	var sub_kind := m.u8(seg, src + 2)
	m.w8(HubMemory.POOL, s, sub_kind)
	for i in 4:
		m.w16(HubMemory.POOL, s + 6 + 2 * i, m.u16(seg, src + 0x1C + 2 * i))
	var table := m.far(HubMemory.POOL, 0x17EA)
	m.w16(HubMemory.POOL, s + 2, m.u16(table[1], table[0] + sub_kind * 4))
	m.w16(HubMemory.POOL, s + 4, m.u16(table[1], table[0] + sub_kind * 4 + 2))
	return idx


# The hub loader (1000:5AB4) also copies the 12-word handler-table block (DS:067E) to
# pool 17D6..17ED before loading the list.
func load_hub_list(table_block: int, seg: int, off: int) -> void:
	for i in 12:
		m.w16(HubMemory.POOL, 0x17D6 + 2 * i, m.u16(HubMemory.DS, table_block + 2 * i))
	load_list(seg, off)


# ---- events (1000:74C2, 7364, 71D8, 71C2) -----------------------------------------------

func event_slot(group: int) -> int:
	var bit := 1 << group
	if m.u16(HubMemory.POOL, 0x17EE) & bit == 0:
		m.w8(HubMemory.POOL, 0x17F8 + group, 0)
		m.w16(HubMemory.POOL, 0x17EE, m.u16(HubMemory.POOL, 0x17EE) | bit)
	elif m.u8(HubMemory.POOL, 0x17F8 + group) >= 4:
		return -1
	var n := m.u8(HubMemory.POOL, 0x17F8 + group)
	m.w8(HubMemory.POOL, 0x17F8 + group, n + 1)
	return EVENT_BASE + (group * 4 + n) * 16


func post(group: int, type: int, payload: int) -> void:
	var e := event_slot(group)
	if e < 0:
		return
	m.w16(HubMemory.POOL, e, type)
	for f in [2, 4, 6, 8, 0x0C]:
		m.w16(HubMemory.POOL, e + f, 0)
	m.w16(HubMemory.POOL, e + 0x0A, payload)


func clear_events() -> void:
	m.w16(HubMemory.POOL, 0x17EE, 0)
	m.w16(HubMemory.POOL, 0x17F0, 0)


# Delivers every pending event whose group is in the current object's mask (+6) to its B
# handler; the event being handled is at the far pointer pool:1FCA. Clears events after.
func deliver_events() -> void:
	var pending := o16(0x06) & m.u16(HubMemory.POOL, 0x17EE)
	var group := 0
	while pending != 0:
		while pending & 1 == 0:
			pending >>= 1
			group += 1
		var count := m.u8(HubMemory.POOL, 0x17F8 + group)
		for n in count:
			m.w16(HubMemory.POOL, 0x1FCA, EVENT_BASE + group * 0x40 + n * 16)
			m.w16(HubMemory.POOL, 0x1FCC, HubMemory.POOL)
			call_code([o16(0x08), o16(0x0A)])
		pending &= ~1
	clear_events()


# Current event (inside a B handler).
func ev16(field: int) -> int:
	return m.u16(HubMemory.POOL, m.u16(HubMemory.POOL, 0x1FCA) + field)


# ---- per-frame object pass (1000:62C2) --------------------------------------------------

func frame_pass() -> void:
	m.w8(HubMemory.POOL, 0x0002, 0)
	for idx in object_count():
		set_cur(obj_offset(idx))
		m.w16(HubMemory.POOL, 0x1FBC, idx)
		if o8(0) == 0:
			continue
		call_code([o16(0x02), o16(0x04)])
		if o8(0x0C) & 0x80 and o16(0x0E) != 1:
			_move()
	m.w8(HubMemory.POOL, 0x0002, 1)
	clear_events()
	for idx in object_count():
		set_cur(obj_offset(idx))
		m.w16(HubMemory.POOL, 0x1FBC, idx)
		if o8(0x0D) & 0x40:
			_sub5_pass()
			deliver_events()
	m.w8(HubMemory.POOL, 0x0002, 2)
	clear_events()
	for idx in object_count():
		set_cur(obj_offset(idx))
		m.w16(HubMemory.POOL, 0x1FBC, idx)
		if o8(0x0D) & 0x04:
			_sub6_pass()
			deliver_events()


# 1000:6798: position (+0x10..+0x1A, 32-bit x/y/z) += velocity (+0x1C..+0x26).
func _move() -> void:
	for k in 3:
		var p := m.u32(HubMemory.POOL, cur() + 0x10 + 4 * k)
		var v := m.u32(HubMemory.POOL, cur() + 0x1C + 4 * k)
		m.w32(HubMemory.POOL, cur() + 0x10 + 4 * k, p + v)


# 1000:645E: the current object's 5ECC sub (if obj+0x0D bit 0x80) then all 5ECC subs from
# the next one, calling each live sub's A handler (sub+4).
func _sub5_pass() -> void:
	var s := SUB5_BASE
	var i := 0
	m.w16(HubMemory.POOL, 0x1FBA, 0)
	if o8(0x0D) & 0x80:
		var si := 0
		while os16(0x28) > si:
			_call_sub5(s, i)
			s += SUB5_SIZE
			i += 1
			si += SUB5_SIZE
		i += 1
		s += SUB5_SIZE
	while i < m.u16(HubMemory.POOL, 0x0F46):
		_call_sub5(s, i)
		s += SUB5_SIZE
		i += 1


func _call_sub5(s: int, i: int) -> void:
	m.w16(HubMemory.POOL, 0x1F84, s)
	m.w16(HubMemory.POOL, 0x1F86, HubMemory.POOL)
	m.w16(HubMemory.POOL, 0x1FBA, i)
	if m.u8(HubMemory.POOL, s) != 0:
		call_code([m.u16(HubMemory.POOL, s + 4), m.u16(HubMemory.POOL, s + 6)])


# 1000:6534: the same walk over 600E subs (stride 14, A handler at sub+2).
func _sub6_pass() -> void:
	var s := SUB6_BASE
	var i := 0
	m.w16(HubMemory.POOL, 0x1F96, 0)
	if o8(0x0D) & 0x08:
		var si := 0
		while os16(0x2A) > si:
			_call_sub6(s, i)
			s += SUB6_SIZE
			i += 1
			si += SUB6_SIZE
		i += 1
		s += SUB6_SIZE
	while i < m.u16(HubMemory.POOL, 0x15F0):
		_call_sub6(s, i)
		s += SUB6_SIZE
		i += 1


func _call_sub6(s: int, i: int) -> void:
	m.w16(HubMemory.POOL, 0x1F78, s)
	m.w16(HubMemory.POOL, 0x1F7A, HubMemory.POOL)
	m.w16(HubMemory.POOL, 0x1F96, i)
	if m.u8(HubMemory.POOL, s) != 0:
		call_code([m.u16(HubMemory.POOL, s + 2), m.u16(HubMemory.POOL, s + 4)])


# ---- animation (1000:6C92 step; setters 7028/707A/70CA/7118 and relative forms) --------

func anim_step(frame_count: int) -> void:
	var speed := os16(0x36)
	if speed == 0:
		return
	var pos := os16(0x34) + speed
	var span := frame_count << 8
	if pos >= span:
		while pos >= span:
			pos -= span
			if o8(0x38) == 0:
				continue
			ow8(0x38, o8(0x38) - 1)
			if o8(0x38) == 0:
				pos = 0
				ow16(0x36, 0)
				break
	elif pos < 0:
		while pos < 0:
			pos += span
			if o8(0x38) == 0:
				continue
			ow8(0x38, o8(0x38) - 1)
			if o8(0x38) == 0:
				pos = (frame_count - 1) << 8
				ow16(0x36, 0)
				break
	ow16(0x34, pos)


func set_anim(state: int, anim: int, loops: int, speed: int, flags: int) -> void:
	ow16(0x0E, state)
	ow16(0x32, anim)
	ow8(0x38, loops)
	ow16(0x36, speed)
	ow16(0x3A, flags)
	ow16(0x34, 0)


func set_anim_rel(state: int, n: int, loops: int, speed: int, flags: int) -> void:
	set_anim(state, (n + o16(0x30)) if n >= 0 else 0xFFFF, loops, speed, flags)
