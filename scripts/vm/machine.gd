class_name DosMachine
extends RefCounted

# A small PC for MUSEUM's DOS programs: BIOS/DOS services implemented natively; the CPU, VGA,
# timer, sound and PIC live in the native X86Core (reached through CoreView).
# Drive C: is the original game folder (read-only); files the game writes go to user://dos/.
#
# BIOS interrupt vectors point at stubs in segment F000: "F1 nn CF" (F1 = trap to native
# service nn, then IRET), so programs that hook a vector and chain to the old one still work.

const BIOS_SEG := 0xF000
const PSP_SIZE := 0x100
const TOP_SEG := 0x9FFF

var cpu: CoreView
var game_dir := "res://assets/original/"
var write_dir := "user://dos/"
var log_unhandled := {}
var video_mode := 3

# input
var mouse_x := 160
var mouse_y := 100
var mouse_buttons := 0
var mouse_visible := 0
var mouse_min_x := 0
var mouse_max_x := 639
var mouse_min_y := 0
var mouse_max_y := 199
var keys: Array[int] = []

# DOS state
var files := {}
var next_handle := 5
var dta_seg := 0
var dta_off := 0x80
var psp_seg := 0
var exit_code := 0
var terminated := false
var mcb_free_seg := 0
var find_state := {}
# EXEC: stack of parent contexts
var exec_stack: Array = []
var trace_dos := false


func _init(a_cpu: CoreView) -> void:
	cpu = a_cpu
	DirAccess.make_dir_recursive_absolute(write_dir)
	_install_bios()


func _install_bios() -> void:
	for n in 256:
		var off := n * 4
		cpu.core.poke8(BIOS_SEG * 16 + off, 0xF1)
		cpu.core.poke8(BIOS_SEG * 16 + off + 1, n)
		cpu.core.poke8(BIOS_SEG * 16 + off + 2, 0xCF)
		cpu.ww(0, n * 4, off)
		cpu.ww(0, n * 4 + 2, BIOS_SEG)
	# Mouse event trampoline at F000:E000: save registers, load the event (native E0), far-call
	# the program's handler (pointer at F000:E020), restore, IRET.
	var tramp := [0x60, 0x1E, 0x06, 0xF1, 0xE0, 0x2E, 0xFF, 0x1E, 0x20, 0xE0, 0x07, 0x1F, 0x61, 0xCF]
	for i in tramp.size():
		cpu.core.poke8(BIOS_SEG * 16 + 0xE000 + i, tramp[i])
	# BIOS data area: equipment, memory size, video
	cpu.ww(0x40, 0x10, 0x0021)
	cpu.ww(0x40, 0x13, 640)
	cpu.wb(0x40, 0x49, 3)
	cpu.ww(0x40, 0x4A, 80)
	cpu.ww(0x40, 0x63, 0x3D4)
	cpu.wb(0x40, 0x84, 24)


# ---- interrupts ---------------------------------------------------------------------------

func set_cf(on: bool) -> void:
	# flags image pushed by the INT is at SS:SP+4 (IP, CS, FLAGS)
	var addr := cpu.r[4] + 4
	var f := cpu.rw(cpu.s[2], addr)
	f = (f | 1) if on else (f & ~1)
	cpu.ww(cpu.s[2], addr, f)


func set_zf(on: bool) -> void:
	var addr := cpu.r[4] + 4
	var f := cpu.rw(cpu.s[2], addr)
	f = (f | 0x40) if on else (f & ~0x40)
	cpu.ww(cpu.s[2], addr, f)


func native(n: int) -> void:
	match n:
		0x09, 0x1C, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x70, 0x74, 0x1B, 0x23, 0x24:
			pass
		0x10: _int10()
		0x11: cpu.r[0] = cpu.rw(0x40, 0x10)
		0x12: cpu.r[0] = 640
		0x15: set_cf(true)
		0x16: _int16()
		0x1A: _int1a()
		0x20: _terminate(0)
		0x21: _int21()
		0x2F: _int2f()
		0x33: _int33()
		0x67: cpu.set_r8(4, 0x80)
		0xE0: _mouse_event_regs()
		_:
			if not log_unhandled.has("int%02X" % n):
				log_unhandled["int%02X" % n] = true
				print("dos: unhandled INT %02X AX=%04X" % [n, cpu.r[0]])


func screen_indices() -> PackedByteArray:
	return cpu.core.screen()


func palette_rgba() -> PackedByteArray:
	return cpu.core.palette()


func elapsed_seconds() -> float:
	return cpu.core.get_time()


# ---- BIOS services ------------------------------------------------------------------------

func _int10() -> void:
	var ah := cpu.get_r8(4)
	match ah:
		0x00:
			video_mode = cpu.get_r8(0) & 0x7F
			if video_mode == 0x13:
				cpu.core.vga_mode13(cpu.get_r8(0) & 0x80 == 0)
		0x0F:
			cpu.set_r8(0, video_mode)
			cpu.set_r8(4, 40 if video_mode == 0x13 else 80)
			cpu.set_r8(7, 0)
		0x10:
			var al := cpu.get_r8(0)
			if al == 0x12:
				var first := cpu.r[3]
				var count := cpu.r[1]
				for i in count * 3:
					cpu.core.dac_set(first * 3 + i, cpu.rb(cpu.s[0], cpu.r[2] + i))
			elif al == 0x10:
				var c := cpu.r[3]
				cpu.core.dac_set(c * 3, cpu.get_r8(6))
				cpu.core.dac_set(c * 3 + 1, cpu.get_r8(5))
				cpu.core.dac_set(c * 3 + 2, cpu.get_r8(1))
			elif al == 0x17:
				var first := cpu.r[3]
				var count := cpu.r[1]
				for i in count * 3:
					cpu.wb(cpu.s[0], cpu.r[2] + i, cpu.core.dac_get(first * 3 + i))
		0x1A:
			cpu.set_r8(0, 0x1A)
			cpu.set_r8(3, 0x08)
		0x12:
			if cpu.get_r8(3) == 0x10:
				cpu.set_r8(7, 0)
				cpu.set_r8(3, 3)
		_:
			pass


func _int16() -> void:
	var ah := cpu.get_r8(4) & 0xEF
	match ah:
		0x00:
			if keys.is_empty():
				# No key yet: rewind to re-execute the INT until one arrives.
				_rewind_int()
				return
			cpu.r[0] = keys.pop_front()
		0x01:
			if keys.is_empty():
				set_zf(true)
			else:
				cpu.r[0] = keys[0]
				set_zf(false)
		0x02:
			cpu.set_r8(0, 0)


func _rewind_int() -> void:
	# The stub's IRET would return after the INT instruction; back the saved IP up by 2 so the
	# program asks again, and let time pass meanwhile.
	var ret_ip := cpu.rw(cpu.s[2], cpu.r[4])
	cpu.ww(cpu.s[2], cpu.r[4], (ret_ip - 2) & 0xFFFF)
	cpu.halted = true


func _int1a() -> void:
	if cpu.get_r8(4) == 0:
		cpu.r[2] = cpu.rw(0x40, 0x6C)
		cpu.r[1] = cpu.rw(0x40, 0x6E)
		cpu.set_r8(0, 0)
	elif cpu.get_r8(4) == 2:
		var t := Time.get_time_dict_from_system()
		cpu.set_r8(5, _bcd(t.hour))
		cpu.set_r8(1, _bcd(t.minute))
		cpu.set_r8(6, _bcd(t.second))
		set_cf(false)
	elif cpu.get_r8(4) == 4:
		var d := Time.get_date_dict_from_system()
		cpu.set_r8(5, _bcd(d.year / 100))
		cpu.set_r8(1, _bcd(d.year % 100))
		cpu.set_r8(6, _bcd(d.month))
		cpu.set_r8(2, _bcd(d.day))
		set_cf(false)


func _bcd(v: int) -> int:
	return ((v / 10) << 4) | (v % 10)


func _int2f() -> void:
	# No XMS, no multiplex services.
	if cpu.r[0] == 0x4300:
		cpu.set_r8(0, 0)


# ---- mouse (INT 33h) ----------------------------------------------------------------------

var mouse_calls := {}
var mouse_handler_mask := 0
var mouse_pending := 0
var mouse_waiting := false
var mickey_x := 0
var mickey_y := 0
var mickey_read_x := 0
var mickey_read_y := 0
var last_mouse := Vector3i(160, 100, 0)


var mickey_frac := Vector2.ZERO


# Called by the front end with the game-space position (320x200) and button bits. `raw` is the
# unclamped motion in game pixels when known (captured mouse): the game moves its cursor from
# the mickey counts and clamps it itself, so motion must keep counting at the screen edges.
func mouse_update(x: int, y: int, buttons: int, raw := Vector2.ZERO) -> void:
	var events := 0
	var motion := raw if raw != Vector2.ZERO else Vector2(x - last_mouse.x, y - last_mouse.y)
	if motion != Vector2.ZERO:
		events |= 1
		mickey_frac += motion * 2.0
		var whole := Vector2i(int(mickey_frac.x), int(mickey_frac.y))
		mickey_x += whole.x
		mickey_y += whole.y
		mickey_frac -= Vector2(whole)
	var changed := buttons ^ last_mouse.z
	if changed & 1:
		events |= 2 if buttons & 1 else 4
	if changed & 2:
		events |= 8 if buttons & 2 else 16
	mouse_x = x
	mouse_y = y
	mouse_buttons = buttons
	last_mouse = Vector3i(x, y, buttons)
	mouse_pending |= events


# Runs the program's INT 33h/0Ch event handler when an event is pending (interrupt-style).
func service_mouse() -> void:
	if mouse_pending & mouse_handler_mask == 0 or mouse_waiting:
		return
	if cpu.core.enter_isr(BIOS_SEG, 0xE000):
		mouse_waiting = true


func _mouse_event_regs() -> void:
	cpu.r[0] = mouse_pending & mouse_handler_mask
	mouse_pending = 0
	mouse_waiting = false
	cpu.r[3] = mouse_buttons
	cpu.r[1] = clampi(mouse_x * 2, mouse_min_x, mouse_max_x)
	cpu.r[2] = clampi(mouse_y, mouse_min_y, mouse_max_y)
	cpu.r[6] = mickey_x & 0xFFFF
	cpu.r[7] = mickey_y & 0xFFFF


func _int33() -> void:
	if trace_dos and not mouse_calls.has(cpu.r[0]):
		mouse_calls[cpu.r[0]] = true
		print("int33 AX=%04X BX=%04X CX=%04X DX=%04X ES=%04X" % [cpu.r[0], cpu.r[3], cpu.r[1], cpu.r[2], cpu.s[0]])
	match cpu.r[0]:
		0x00:
			# reset: also forgets the event handler, as a real mouse driver does
			cpu.r[0] = 0xFFFF
			cpu.r[3] = 2
			mouse_visible = 0
			mouse_handler_mask = 0
			mouse_pending = 0
		0x01: mouse_visible += 1
		0x02: mouse_visible -= 1
		0x03:
			cpu.r[3] = mouse_buttons
			cpu.r[1] = clampi(mouse_x * 2, mouse_min_x, mouse_max_x)
			cpu.r[2] = clampi(mouse_y, mouse_min_y, mouse_max_y)
		0x04:
			mouse_x = cpu.r[1] / 2
			mouse_y = cpu.r[2]
		0x07:
			mouse_min_x = mini(cpu.r[1], cpu.r[2])
			mouse_max_x = maxi(cpu.r[1], cpu.r[2])
		0x08:
			mouse_min_y = mini(cpu.r[1], cpu.r[2])
			mouse_max_y = maxi(cpu.r[1], cpu.r[2])
		0x05, 0x06:
			cpu.r[3] = 0
			cpu.r[1] = mouse_x * 2
			cpu.r[2] = mouse_y
			cpu.r[0] = mouse_buttons
		0x0B:
			cpu.r[1] = (mickey_x - mickey_read_x) & 0xFFFF
			cpu.r[2] = (mickey_y - mickey_read_y) & 0xFFFF
			mickey_read_x = mickey_x
			mickey_read_y = mickey_y
		0x0C:
			mouse_handler_mask = cpu.r[1]
			cpu.core.poke16(BIOS_SEG * 16 + 0xE020, cpu.r[2])
			cpu.core.poke16(BIOS_SEG * 16 + 0xE022, cpu.s[0])
		_:
			pass


# ---- DOS ----------------------------------------------------------------------------------

func _dos_path(seg: int, off: int) -> String:
	var name := ""
	while true:
		var c := cpu.rb(seg, off)
		if c == 0:
			break
		name += char(c)
		off += 1
	name = name.replace("\\", "/")
	if name.length() >= 2 and name[1] == ":":
		name = name.substr(2)
	while name.begins_with("/"):
		name = name.substr(1)
	while name.begins_with("./"):
		name = name.substr(2)
	return name.to_upper()


# Original files: assets/original/ in the editor; exported builds carry byte-identical copies as
# assets/game/<NAME>.dat (assets/original is .gdignore'd, and Godot would read MUSEUM.RES as one
# of its own .res files).
const EXPORT_DIR := "res://assets/game/"


func _find_file(name: String) -> String:
	var w := write_dir + name
	if FileAccess.file_exists(w):
		return w
	var g := game_dir + name
	if FileAccess.file_exists(g):
		return g
	var e := EXPORT_DIR + name + ".dat"
	if FileAccess.file_exists(e):
		return e
	return ""


func _int21() -> void:
	var ah := cpu.get_r8(4)
	if trace_dos:
		var extra := ""
		if ah in [0x3D, 0x3C, 0x41, 0x43, 0x4B, 0x4E]:
			extra = _dos_path(cpu.s[3], cpu.r[2])
		print("int21 AH=%02X AL=%02X BX=%04X CX=%04X %s" % [ah, cpu.get_r8(0), cpu.r[3], cpu.r[1], extra])
	match ah:
		0x02:
			pass
		0x06, 0x07, 0x08:
			if cpu.core.key_count() == 0:
				if ah == 0x06:
					set_zf(true)
					cpu.set_r8(0, 0)
				else:
					_rewind_int()
				return
			set_zf(false)
			cpu.set_r8(0, cpu.core.pop_key() & 0xFF)
		0x09:
			pass
		0x0B:
			cpu.set_r8(0, 0 if cpu.core.key_count() == 0 else 0xFF)
		0x0C:
			cpu.core.clear_keys()
		0x0E:
			cpu.set_r8(0, 3)
		0x19:
			cpu.set_r8(0, 2)
		0x1A:
			dta_seg = cpu.s[3]
			dta_off = cpu.r[2]
		0x25:
			var n := cpu.get_r8(0)
			cpu.ww(0, n * 4, cpu.r[2])
			cpu.ww(0, n * 4 + 2, cpu.s[3])
		0x2A:
			var d := Time.get_date_dict_from_system()
			cpu.r[1] = d.year
			cpu.set_r8(6, d.month)
			cpu.set_r8(2, d.day)
			cpu.set_r8(0, d.weekday)
		0x2C:
			var t := Time.get_time_dict_from_system()
			cpu.set_r8(5, t.hour)
			cpu.set_r8(1, t.minute)
			cpu.set_r8(6, t.second)
			cpu.set_r8(2, int(fmod(elapsed_seconds(), 1.0) * 100))
		0x2F:
			cpu.s[0] = dta_seg
			cpu.r[3] = dta_off
		0x30:
			cpu.r[0] = 0x0005
			cpu.r[3] = 0
		0x33:
			cpu.set_r8(2, 0)
		0x35:
			var n := cpu.get_r8(0)
			cpu.r[3] = cpu.rw(0, n * 4)
			cpu.s[0] = cpu.rw(0, n * 4 + 2)
		0x36:
			cpu.r[0] = 64
			cpu.r[3] = 0x4000
			cpu.r[1] = 512
			cpu.r[2] = 0x8000
		0x3B:
			set_cf(false)
		0x3C:
			_create()
		0x3D:
			_open()
		0x3E:
			files.erase(cpu.r[3])
			set_cf(false)
		0x3F:
			_read()
		0x40:
			_write()
		0x41:
			var name := _dos_path(cpu.s[3], cpu.r[2])
			if FileAccess.file_exists(write_dir + name):
				DirAccess.remove_absolute(write_dir + name)
			set_cf(false)
		0x42:
			_seek()
		0x43:
			var name := _dos_path(cpu.s[3], cpu.r[2])
			if _find_file(name) == "":
				cpu.r[0] = 2
				set_cf(true)
			else:
				cpu.r[1] = 0x20
				set_cf(false)
		0x44:
			_ioctl()
		0x47:
			cpu.wb(cpu.s[3], cpu.r[6], 0)
			set_cf(false)
		0x48:
			_alloc()
		0x49:
			_free()
		0x4A:
			_resize()
		0x4B:
			_exec()
		0x4C:
			_terminate(cpu.get_r8(0))
		0x4D:
			cpu.r[0] = exit_code & 0xFF
		0x4E:
			_find_first()
		0x4F:
			_find_next()
		0x50:
			psp_seg = cpu.r[3]
		0x51, 0x62:
			cpu.r[3] = psp_seg
		0x57:
			cpu.r[1] = 0
			cpu.r[2] = 0x2100
			set_cf(false)
		0x58:
			cpu.r[0] = 0
			set_cf(false)
		0x59:
			cpu.r[0] = 0
		_:
			if not log_unhandled.has("21-%02X" % ah):
				log_unhandled["21-%02X" % ah] = true
				print("dos: unhandled INT 21 AH=%02X" % ah)
			set_cf(true)


func _open() -> void:
	var name := _dos_path(cpu.s[3], cpu.r[2])
	var path := _find_file(name)
	if path == "":
		cpu.r[0] = 2
		set_cf(true)
		return
	var data := FileAccess.get_file_as_bytes(path)
	var h := next_handle
	next_handle += 1
	files[h] = {"name": name, "data": data, "pos": 0, "dirty": false}
	cpu.r[0] = h
	set_cf(false)


func _create() -> void:
	var name := _dos_path(cpu.s[3], cpu.r[2])
	var h := next_handle
	next_handle += 1
	files[h] = {"name": name, "data": PackedByteArray(), "pos": 0, "dirty": true}
	_flush(h)
	cpu.r[0] = h
	set_cf(false)


func _read() -> void:
	var h := cpu.r[3]
	if h == 0:
		cpu.r[0] = 0
		set_cf(false)
		return
	if not files.has(h):
		cpu.r[0] = 6
		set_cf(true)
		return
	var f: Dictionary = files[h]
	var data: PackedByteArray = f.data
	var n := mini(cpu.r[1], data.size() - f.pos)
	n = maxi(n, 0)
	var seg := cpu.s[3]
	var off := cpu.r[2]
	if off + n <= 0x10000:
		# one block copy instead of a call per byte
		cpu.core.load((seg << 4) + off, data.slice(f.pos, f.pos + n))
	else:
		for i in n:
			cpu.wb(seg, off + i, data[f.pos + i])
	f.pos += n
	cpu.r[0] = n
	set_cf(false)


func _write() -> void:
	var h := cpu.r[3]
	var n := cpu.r[1]
	if h <= 4:
		cpu.r[0] = n
		set_cf(false)
		return
	if not files.has(h):
		cpu.r[0] = 6
		set_cf(true)
		return
	var f: Dictionary = files[h]
	var data: PackedByteArray = f.data
	if f.pos + n > data.size():
		data.resize(f.pos + n)
	var src := cpu.r[2]
	if src + n <= 0x10000:
		var block: PackedByteArray = cpu.core.read((cpu.s[3] << 4) + src, n)
		for i in n:
			data[f.pos + i] = block[i]
	else:
		for i in n:
			data[f.pos + i] = cpu.rb(cpu.s[3], cpu.r[2] + i)
	f.data = data
	f.pos += n
	f.dirty = true
	_flush(h)
	cpu.r[0] = n
	set_cf(false)


func _flush(h: int) -> void:
	var f: Dictionary = files[h]
	var fa := FileAccess.open(write_dir + f.name, FileAccess.WRITE)
	if fa:
		fa.store_buffer(f.data)
		fa.close()


func _seek() -> void:
	var h := cpu.r[3]
	if not files.has(h):
		cpu.r[0] = 6
		set_cf(true)
		return
	var f: Dictionary = files[h]
	var off := (cpu.r[1] << 16) | cpu.r[2]
	if off & 0x80000000:
		off -= 0x100000000
	match cpu.get_r8(0):
		0: f.pos = off
		1: f.pos += off
		2: f.pos = f.data.size() + off
	f.pos = maxi(f.pos, 0)
	cpu.r[0] = f.pos & 0xFFFF
	cpu.r[2] = (f.pos >> 16) & 0xFFFF
	set_cf(false)


func _ioctl() -> void:
	var al := cpu.get_r8(0)
	match al:
		0x00:
			var h := cpu.r[3]
			cpu.r[2] = 0x80D3 if h <= 4 else 0x0002
			set_cf(false)
		0x08:
			cpu.r[0] = 1
			set_cf(false)
		0x09:
			cpu.r[2] = 0
			set_cf(false)
		_:
			cpu.r[0] = 1
			set_cf(true)


# Memory: a list of allocated blocks [segment of data, paragraphs], kept sorted; free space is
# everything between blocks below TOP_SEG. A program's own block starts at its PSP.
var blocks: Array = []
var mem_base := 0x0060


func _block_index(seg: int) -> int:
	for i in blocks.size():
		if blocks[i][0] == seg:
			return i
	return -1


# Free runs between blocks, as [start, size].
func _free_runs() -> Array:
	var runs := []
	var cur := mem_base
	var sorted := blocks.duplicate()
	sorted.sort_custom(func(a, b): return a[0] < b[0])
	for b in sorted:
		if b[0] > cur:
			runs.append([cur, b[0] - cur])
		cur = maxi(cur, b[0] + b[1])
	if TOP_SEG > cur:
		runs.append([cur, TOP_SEG - cur])
	return runs


func _alloc() -> void:
	var paras := cpu.r[3]
	if trace_dos:
		print("dos: alloc %04X paras" % paras)
	var largest := 0
	for run in _free_runs():
		largest = maxi(largest, run[1])
		if run[1] >= paras:
			blocks.append([run[0], paras])
			cpu.r[0] = run[0]
			set_cf(false)
			return
	cpu.r[0] = 8
	cpu.r[3] = largest
	set_cf(true)


func _free() -> void:
	var i := _block_index(cpu.s[0])
	if i >= 0:
		blocks.remove_at(i)
	set_cf(false)


func _resize() -> void:
	var seg := cpu.s[0]
	var paras := cpu.r[3]
	var i := _block_index(seg)
	if i < 0:
		cpu.r[0] = 9
		set_cf(true)
		return
	# room up to the next block (or the top of memory)
	var limit := TOP_SEG
	for b in blocks:
		if b[0] > seg and b[0] < limit:
			limit = b[0]
	if seg + paras > limit:
		cpu.r[3] = limit - seg
		cpu.r[0] = 8
		set_cf(true)
		return
	blocks[i][1] = paras
	set_cf(false)


func _find_first() -> void:
	var name := _dos_path(cpu.s[3], cpu.r[2])
	find_state = {"pattern": name, "done": false}
	_find_next()


func _find_next() -> void:
	if find_state.is_empty() or find_state.done:
		cpu.r[0] = 18
		set_cf(true)
		return
	find_state.done = true
	var name: String = find_state.pattern
	if name.contains("*") or name.contains("?"):
		cpu.r[0] = 18
		set_cf(true)
		return
	var path := _find_file(name)
	if path == "":
		cpu.r[0] = 2
		set_cf(true)
		return
	var size := FileAccess.get_file_as_bytes(path).size()
	var base := dta_off
	cpu.wb(dta_seg, base + 0x15, 0x20)
	cpu.ww(dta_seg, base + 0x16, 0)
	cpu.ww(dta_seg, base + 0x18, 0x2100)
	cpu.ww(dta_seg, base + 0x1A, size & 0xFFFF)
	cpu.ww(dta_seg, base + 0x1C, size >> 16)
	var fname := name.get_file()
	for i in 13:
		cpu.wb(dta_seg, base + 0x1E + i, fname.unicode_at(i) if i < fname.length() else 0)
	set_cf(false)


# ---- program loading ----------------------------------------------------------------------

# Environment block: variables, an empty string, a count word of 1, then the program's full
# path (overlay managers open their own EXE through it).
func _make_env(seg: int, prog: String) -> void:
	var bytes := PackedByteArray()
	for c in "PATH=C:" + char(92):
		bytes.append(c.unicode_at(0))
	bytes.append(0)
	for c in "COMSPEC=C:" + char(92) + "COMMAND.COM":
		bytes.append(c.unicode_at(0))
	bytes.append(0)
	bytes.append(0)
	bytes.append(1)
	bytes.append(0)
	for c in ("C:" + char(92) + prog.to_upper()):
		bytes.append(c.unicode_at(0))
	bytes.append(0)
	for i in bytes.size():
		cpu.wb(seg, i, bytes[i])


# The command tail is raw bytes: launchers end it with a NUL that DOS passes through unchanged
# (a String would turn that byte into U+FFFD and corrupt the program's arguments).
func _make_psp(seg: int, cmdline: Variant, parent: int) -> void:
	for i in PSP_SIZE:
		cpu.wb(seg, i, 0)
	cpu.wb(seg, 0, 0xCD)
	cpu.wb(seg, 1, 0x20)
	cpu.ww(seg, 2, TOP_SEG)
	cpu.ww(seg, 0x16, parent)
	cpu.ww(seg, 0x2C, 0)
	var tail: PackedByteArray = cmdline if cmdline is PackedByteArray else str(cmdline).to_ascii_buffer()
	tail = tail.slice(0, 126)
	cpu.wb(seg, 0x80, tail.size())
	for i in tail.size():
		cpu.wb(seg, 0x81 + i, tail[i])
	cpu.wb(seg, 0x81 + tail.size(), 0x0D)


# Free paragraphs from `seg` to the next block or the top of memory.
func _room_at(seg: int) -> int:
	var limit := TOP_SEG
	for b in blocks:
		if b[0] > seg and b[0] < limit:
			limit = b[0]
	return limit - seg


# Loads a .COM or MZ program at load_seg (its PSP); sets CS:IP and SS:SP. Returns false on error.
func load_program(name: String, cmdline: Variant, load_seg: int, parent: int) -> bool:
	var path := _find_file(name.to_upper())
	if path == "":
		return false
	var data := FileAccess.get_file_as_bytes(path)
	# environment in its own 16-paragraph block just below the program
	var env_seg := load_seg - 0x10
	blocks.append([env_seg, 0x10])
	_make_env(env_seg, name)
	_make_psp(load_seg, cmdline, parent)
	cpu.ww(load_seg, 0x2C, env_seg)
	psp_seg = load_seg
	dta_seg = load_seg
	dta_off = 0x80
	if data.size() >= 2 and data[0] == 0x4D and data[1] == 0x5A:
		var cblp := data.decode_u16(2)
		var cp := data.decode_u16(4)
		var nreloc := data.decode_u16(6)
		var hdr := data.decode_u16(8)
		var minalloc := data.decode_u16(0x0A)
		var img_end := (cp - 1) * 512 + (cblp if cblp != 0 else 512)
		img_end = mini(img_end, data.size())
		var image_seg := load_seg + 0x10
		var start := hdr * 16
		cpu.core.load(image_seg * 16, data.slice(start, img_end))
		var rel_off := data.decode_u16(0x18)
		for k in nreloc:
			var ro := data.decode_u16(rel_off + k * 4)
			var rs := data.decode_u16(rel_off + k * 4 + 2)
			var v := cpu.rw(image_seg + rs, ro)
			cpu.ww(image_seg + rs, ro, (v + image_seg) & 0xFFFF)
		cpu.s[2] = (data.decode_u16(0x0E) + image_seg) & 0xFFFF
		cpu.r[4] = data.decode_u16(0x10)
		cpu.s[1] = (data.decode_u16(0x16) + image_seg) & 0xFFFF
		cpu.ip = data.decode_u16(0x14)
		var maxalloc := data.decode_u16(0x0C)
		var need := 0x10 + ((img_end - start + 15) >> 4) + minalloc
		var want := mini(0x10 + ((img_end - start + 15) >> 4) + maxalloc, 0xFFFF)
		var room := _room_at(load_seg)
		blocks.append([load_seg, clampi(want, need, room)])
		mcb_free_seg = image_seg + ((img_end - start + 15) >> 4) + minalloc
	else:
		cpu.core.load(load_seg * 16 + 0x100, data)
		cpu.s[1] = load_seg
		cpu.s[2] = load_seg
		cpu.r[4] = 0xFFFE
		cpu.ww(load_seg, 0xFFFE, 0)
		cpu.ip = 0x100
		blocks.append([load_seg, _room_at(load_seg)])
		mcb_free_seg = TOP_SEG
	cpu.s[0] = load_seg
	cpu.s[3] = load_seg
	cpu.r[0] = 0
	cpu.r[3] = 0
	return true


func _exec() -> void:
	if cpu.get_r8(0) != 0:
		cpu.r[0] = 1
		set_cf(true)
		return
	var name := _dos_path(cpu.s[3], cpu.r[2])
	var pb_seg := cpu.s[0]
	var pb_off := cpu.r[3]
	var tail_off := cpu.rw(pb_seg, pb_off + 2)
	var tail_seg := cpu.rw(pb_seg, pb_off + 4)
	var n := cpu.rb(tail_seg, tail_off)
	var cmd := PackedByteArray()
	var shown := ""
	for i in n:
		var c := cpu.rb(tail_seg, tail_off + 1 + i)
		cmd.append(c)
		shown += char(c) if c >= 32 and c < 127 else "."
	# Save the parent context; the IRET frame is on the parent's stack. The interrupt table is
	# saved too and put back when the child exits, so hooks a child leaves behind (its sound
	# driver's timer handler) can't point into memory the next program overwrites.
	exec_stack.push_back({
		"r": cpu.r.duplicate(), "s": cpu.s.duplicate(), "ip": cpu.ip, "flags": cpu.flags,
		"psp": psp_seg, "free": mcb_free_seg, "dta_seg": dta_seg, "dta_off": dta_off,
		"blocks": blocks.duplicate(true), "ivt": cpu.core.read(0, 0x400),
		"mouse_mask": mouse_handler_mask, "mouse_handler": cpu.core.read(BIOS_SEG * 16 + 0xE020, 4),
	})
	# The child starts with no mouse handler: the parent's points into the parent's own code.
	mouse_handler_mask = 0
	mouse_pending = 0
	var child_seg := -1
	var best := 0
	for run in _free_runs():
		if run[1] > best:
			best = run[1]
			child_seg = run[0] + 0x10
	print("dos: exec %s '%s' at %04X" % [name, shown, child_seg])
	if trace_dos:
		print("dos: blocks ", blocks)
	if not load_program(name, cmd, child_seg, psp_seg):
		var ctx: Dictionary = exec_stack.pop_back()
		cpu.r = ctx.r
		cpu.s = ctx.s
		cpu.ip = ctx.ip
		blocks = ctx.blocks
		cpu.core.load(0, ctx.ivt)
		mouse_handler_mask = ctx.mouse_mask
		cpu.core.load(BIOS_SEG * 16 + 0xE020, ctx.mouse_handler)
		cpu.r[0] = 2
		set_cf(true)
		return


func _terminate(code: int) -> void:
	exit_code = code
	files.clear()
	if exec_stack.is_empty():
		terminated = true
		cpu.halted = true
		print("dos: program exited with %d" % code)
		return
	var ctx: Dictionary = exec_stack.pop_back()
	cpu.r = ctx.r
	cpu.s = ctx.s
	cpu.ip = ctx.ip
	cpu.flags = ctx.flags
	psp_seg = ctx.psp
	mcb_free_seg = ctx.free
	blocks = ctx.blocks
	cpu.core.load(0, ctx.ivt)
	# Drop the child's mouse handler (its code is gone) and give the parent back its own.
	mouse_handler_mask = ctx.mouse_mask
	cpu.core.load(BIOS_SEG * 16 + 0xE020, ctx.mouse_handler)
	mouse_pending = 0
	mouse_waiting = false
	dta_seg = ctx.dta_seg
	dta_off = ctx.dta_off
	# back in the parent's INT 21 stub (F1 21 CF): clear CF in its IRET frame
	set_cf(false)
	print("dos: child exited with %d" % code)


# ---- original GDScript VGA and timer (superseded by the native X86Core) -------------------
# Kept from the first version of the machine, when the CPU ran in GDScript (cpu.gd); the native
# core now owns VGA, PIT, retrace and IRQ0. Not called by the game.

const PIT_HZ := 1193182.0

var planes: Array[PackedByteArray] = []
var latch := PackedByteArray([0, 0, 0, 0])
var seq_index := 0
var seq := PackedByteArray()
var gc_index := 0
var gc := PackedByteArray()
var crtc_index := 0
var crtc := PackedByteArray()
var dac := PackedByteArray()
var dac_write := 0
var dac_read := 0
var dac_component := 0
var attr_flip := false
var instr_per_second := 1000000.0
var pit_divisor := 65536
var pit_accum := 0.0
var pit_write_lsb := true
var pit_latch := 0
var vsync_period := 1.0 / 70.086
var retrace_polls := 0
var last_retrace := false
var emu_time := 0.0
var bios_ticks_frac := 0.0


func _init_gdscript_vga() -> void:
	for i in 4:
		var p := PackedByteArray()
		p.resize(0x10000)
		planes.append(p)
	seq.resize(8)
	gc.resize(16)
	crtc.resize(32)
	dac.resize(768)
	seq[2] = 0x0F
	seq[4] = 0x0E
	gc[8] = 0xFF
	crtc[0x13] = 40


func interrupt(_n: int) -> bool:
	return false


# Advances emulated time by `instructions`; raises IRQ0 at the PIT rate.
func tick(instructions: int) -> void:
	advance(instructions / instr_per_second)


func advance(seconds: float) -> void:
	emu_time += seconds
	pit_accum += seconds * PIT_HZ
	var div := float(pit_divisor if pit_divisor > 0 else 65536)
	if pit_accum >= div:
		pit_accum -= div
		if pit_accum > div * 4:
			pit_accum = 0.0
		if cpu.flags & 0x0200:
			cpu.halted = false
			cpu.do_interrupt(8)


func _int08() -> void:
	# BIOS tick count at 18.2 Hz regardless of the PIT rate a program sets.
	bios_ticks_frac += float(pit_divisor if pit_divisor > 0 else 65536) / 65536.0
	while bios_ticks_frac >= 1.0:
		bios_ticks_frac -= 1.0
		var t := cpu.rw(0x40, 0x6C) | (cpu.rw(0x40, 0x6E) << 16)
		t += 1
		cpu.ww(0x40, 0x6C, t & 0xFFFF)
		cpu.ww(0x40, 0x6E, (t >> 16) & 0xFFFF)
		_chain_int1c()


func _chain_int1c() -> void:
	var seg := cpu.rw(0, 0x1C * 4 + 2)
	if seg != BIOS_SEG:
		cpu.do_interrupt(0x1C)


func in_port(port: int, _size: int) -> int:
	port &= 0xFFFF
	match port:
		0x3DA:
			# Status: bit 3 = vertical retrace (first 5% of each 70 Hz frame), bit 0 = not
			# displaying. A poll alternates sides of the edge, so busy-wait loops end at once
			# while emulated time moves to the edge they wait for.
			attr_flip = false
			var t := fmod(emu_time, vsync_period)
			var in_retrace := t < vsync_period * 0.05
			if retrace_polls > 0 and last_retrace == in_retrace:
				if in_retrace:
					advance(vsync_period * 0.05 - t + 1e-7)
				else:
					advance(vsync_period - t + 1e-7)
				in_retrace = not in_retrace
			retrace_polls += 1
			last_retrace = in_retrace
			return 0x09 if in_retrace else 0x00
		0x3C9:
			var v := dac[dac_read * 3 + dac_component]
			dac_component += 1
			if dac_component == 3:
				dac_component = 0
				dac_read = (dac_read + 1) & 0xFF
			return v
		0x3C5: return seq[seq_index & 7]
		0x3CF: return gc[gc_index & 15]
		0x3D5: return crtc[crtc_index & 31]
		0x3C4: return seq_index
		0x3CE: return gc_index
		0x3D4: return crtc_index
		0x60: return 0
		0x61: return 0
		0x40: return pit_latch & 0xFF
		0x201: return 0xFF
		0x388: return 0xFF
	return 0xFF


func out_port(port: int, value: int, size: int) -> void:
	port &= 0xFFFF
	if size == 2:
		out_port(port, value & 0xFF, 1)
		out_port(port + 1, (value >> 8) & 0xFF, 1)
		return
	match port:
		0x3C4: seq_index = value
		0x3C5: seq[seq_index & 7] = value
		0x3CE: gc_index = value
		0x3CF: gc[gc_index & 15] = value
		0x3D4: crtc_index = value
		0x3D5: crtc[crtc_index & 31] = value
		0x3C7:
			dac_read = value
			dac_component = 0
		0x3C8:
			dac_write = value
			dac_component = 0
		0x3C9:
			dac[dac_write * 3 + dac_component] = value & 0x3F
			dac_component += 1
			if dac_component == 3:
				dac_component = 0
				dac_write = (dac_write + 1) & 0xFF
		0x43:
			pit_write_lsb = true
		0x40:
			if pit_write_lsb:
				pit_latch = value
				pit_write_lsb = false
			else:
				pit_divisor = pit_latch | (value << 8)
				if pit_divisor == 0:
					pit_divisor = 65536
				pit_write_lsb = true


func _chain4() -> bool:
	return (seq[4] & 0x08) != 0


func vga_write(addr: int, v: int) -> void:
	var off := addr - 0xA0000
	if _chain4():
		planes[off & 3][off >> 2] = v
		return
	var mask := seq[2] & 0x0F
	var mode := gc[5] & 3
	for p in 4:
		if mask & (1 << p):
			if mode == 1:
				planes[p][off] = latch[p]
			else:
				var bm := gc[8]
				planes[p][off] = (v & bm) | (latch[p] & ~bm & 0xFF)


func vga_read(addr: int) -> int:
	var off := addr - 0xA0000
	if _chain4():
		return planes[off & 3][off >> 2]
	for p in 4:
		latch[p] = planes[p][off]
	return planes[gc[4] & 3][off]


# 320x200 index image of what the GDScript VGA shows.
func gdscript_screen_indices() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(64000)
	var start := (crtc[0x0C] << 8) | crtc[0x0D]
	var pitch := crtc[0x13] * 2
	if pitch == 0:
		pitch = 80
	var i := 0
	if _chain4():
		start = 0
	for y in 200:
		var row := start + y * pitch
		for x in 320:
			out[i] = planes[x & 3][(row + (x >> 2)) & 0xFFFF]
			i += 1
	return out


# 256 x RGBA palette from the GDScript DAC.
func gdscript_palette_rgba() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(1024)
	for c in 256:
		for k in 3:
			var v := dac[c * 3 + k]
			out[c * 4 + k] = (v << 2) | (v >> 4)
		out[c * 4 + 3] = 255
	return out
