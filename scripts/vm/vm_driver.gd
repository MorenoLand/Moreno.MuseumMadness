extends SceneTree

# Headless player for the VM: reads commands from a script file and saves screenshots.
# Commands (one per line): wait SECONDS | key NAME | click X Y | rclick X Y | move X Y |
# shot NAME | until_change SECONDS (wait until the screen changes, max SECONDS) | save_state
# Usage: redot --headless --script res://scripts/vm/vm_driver.gd -- <commands.txt> <outdir>

var core: X86Core
var cpu: CoreView
var m: DosMachine
var outdir := ""
var trap_counts := {}
var bench_t0 := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cmds := FileAccess.get_file_as_string(args[0]).split("\n")
	outdir = args[1]
	core = X86Core.new()
	core.set_ips(3000000.0)
	cpu = CoreView.new(core)
	m = DosMachine.new(cpu)
	m.trace_dos = OS.get_environment("VM_TRACE") == "1"
	var prog := args[2] if args.size() > 2 else "MUSEUM.COM"
	var tail := (" " + args[3]) if args.size() > 3 else ""
	m.load_program(prog, tail, 0x0100, 0)
	if prog != "MUSEUM.COM":
		# An exhibit normally inherits the hub's VGA state (measured at the door): chain-4 off,
		# CRTC offset A0h (a 1280-pixel virtual screen), byte mode.
		core.vga_mode13(true)
		core.vga_set_reg(0, 4, 0x06)
		core.vga_set_reg(2, 0x13, 0xA0)
		core.vga_set_reg(2, 0x14, 0x00)
		core.vga_set_reg(2, 0x17, 0xE3)
	cpu.flush()
	for line in cmds:
		var p := line.strip_edges().split(" ", false)
		if p.is_empty() or p[0].begins_with("#"):
			continue
		match p[0]:
			"wait": run(float(p[1]))
			"key":
				core.push_key(_key(p[1]))
				run(0.3)
			"move":
				m.mouse_update(int(p[1]), int(p[2]), 0)
				run(0.2)
			"click", "rclick":
				m.mouse_update(int(p[1]), int(p[2]), 0)
				run(0.15)
				m.mouse_update(int(p[1]), int(p[2]), 1 if p[0] == "click" else 2)
				run(0.15)
				m.mouse_update(int(p[1]), int(p[2]), 0)
				run(0.3)
			"down":
				m.mouse_update(int(p[1]), int(p[2]), 1)
				run(0.2)
			"drag":
				m.mouse_update(int(p[1]), int(p[2]), 1)
				run(0.2)
			"up":
				m.mouse_update(int(p[1]), int(p[2]), 0)
				run(0.3)
			"terminate":
				# ends the running child program with an exit code, as if it had quit
				cpu.pull()
				m._terminate(int(p[1]))
				cpu.flush()
				run(0.2)
			"wiggle":
				for i in int(p[1]):
					m.mouse_update(100 + (i % 2) * 50, 100, 0)
					run(0.1)
			"shot": shot(p[1])
			"regs":
				var t := "seq:"
				for i in 5:
					t += " %02X" % core.vga_reg(0, i)
				t += " gc:"
				for i in 9:
					t += " %02X" % core.vga_reg(1, i)
				t += " crtc:"
				for i in 25:
					t += " %02X" % core.vga_reg(2, i)
				print(t)
			"until_change":
				var before := core.screen()
				var limit := core.get_time() + float(p[1])
				while core.get_time() < limit:
					run(0.5)
					if core.screen() != before:
						break
		if m.terminated:
			print("program terminated")
			break
	print("done at t=%.1f real %d ms" % [core.get_time(), Time.get_ticks_msec() - bench_t0])
	if OS.get_environment("VM_TRAPS") == "1":
		print("traps: ", trap_counts)
	quit()


func _key(name: String) -> int:
	match name:
		"esc": return 0x011B
		"enter": return 0x1C0D
		"space": return 0x3920
		"y": return 0x1579
		"n": return 0x316E
	return name.unicode_at(0)


func run(seconds: float) -> void:
	var target := core.get_time() + seconds
	while core.get_time() < target and not m.terminated:
		m.service_mouse()
		var st := core.run(minf(target, core.get_time() + 0.01), 2000000)
		if st == X86Core.TRAP:
			var tn := core.get_trap()
			var key := "%02X" % tn
			if tn == 0x21 or tn == 0x16 or tn == 0x33 or tn == 0x10:
				key += "/%02X" % (core.get_reg(0) >> 8 if tn != 0x33 else core.get_reg(0))
			trap_counts[key] = trap_counts.get(key, 0) + 1
			cpu.pull()
			m.native(core.get_trap())
			cpu.flush()
			if cpu.halted:
				cpu.halted = false
				core.advance(0.005)
		elif st == X86Core.HALTED:
			core.advance(0.001)
		elif st == X86Core.FAULT:
			print("FAULT ", core.fault_text())
			m.terminated = true
		core.take_audio(core.audio_available())


func shot(name: String) -> void:
	var idx := core.screen()
	var pal := core.palette()
	var rgb := PackedByteArray()
	rgb.resize(64000 * 3)
	for i in 64000:
		var c := idx[i] * 4
		rgb[i * 3] = pal[c]
		rgb[i * 3 + 1] = pal[c + 1]
		rgb[i * 3 + 2] = pal[c + 2]
	Image.create_from_data(320, 200, false, Image.FORMAT_RGB8, rgb).save_png(outdir + "/" + name + ".png")
	print("shot %s at t=%.1f" % [name, core.get_time()])
