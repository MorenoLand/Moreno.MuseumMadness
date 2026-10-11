// Real-mode 8086/80186 core for running MUSEUM's original DOS programs inside the Godot port.
// CPU, 1 MB memory, VGA (mode 13h and unchained Mode X planes, DAC), PIT/IRQ0 timing and the
// BIOS timer tick are here; all other BIOS/DOS services trap out to GDScript (DosMachine).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

extern "C" {
#include "thirdparty/opl3.h"
}

#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <cstdint>
#include <vector>

namespace godot {

class X86Core : public RefCounted {
	GDCLASS(X86Core, RefCounted)

public:
	enum Status { TIME_REACHED = 0, TRAP = 1, HALTED = 2, FAULT = 3, BUDGET = 4, BREAK = 5 };

	X86Core();

	// memory
	void load(int addr, const PackedByteArray &data);
	PackedByteArray read(int addr, int count) const;
	int peek8(int addr) const;
	int peek16(int addr) const;
	void poke8(int addr, int v);
	void poke16(int addr, int v);

	// registers: 0 AX 1 CX 2 DX 3 BX 4 SP 5 BP 6 SI 7 DI; segments 0 ES 1 CS 2 SS 3 DS
	int get_reg(int i) const { return r[i & 7]; }
	void set_reg(int i, int v) { r[i & 7] = v & 0xFFFF; }
	int get_sreg(int i) const { return s[i & 3]; }
	void set_sreg(int i, int v) { s[i & 3] = v & 0xFFFF; }
	int get_ip() const { return ip; }
	void set_ip(int v) { ip = v & 0xFFFF; }
	int get_flags() const { return flags; }
	void set_flags(int v) { flags = (v & 0x0FD5) | 2; }

	// execution: runs until emulated time reaches `until`, a trap, HLT or `budget` instructions
	int run(double until, int budget);
	int get_trap() const { return trap; }
	double get_time() const { return emu_time; }
	void advance(double seconds);
	void set_ips(double v) { ips = v; }
	int64_t get_executed() const { return executed; }
	void raise_interrupt(int n) { do_interrupt(n); }
	// Enters seg:off like a hardware interrupt (pushes FLAGS, CS, IP; clears IF) if interrupts are
	// enabled; returns false otherwise.
	bool enter_isr(int seg, int off) {
		if (!(flags & 0x0200)) return false;
		push(flags);
		push(s[1]);
		push(ip);
		flags &= ~0x0300;
		s[1] = seg;
		ip = off;
		return true;
	}

	// keyboard: BIOS keystrokes (scan << 8 | ascii). INT 16h is answered here, without leaving
	// the core: games poll it thousands of times per second.
	void push_key(int code) { keys.push_back(uint16_t(code)); }
	int key_count() const { return int(keys.size()); }
	int pop_key() { if (keys.empty()) return 0; int k = keys.front(); keys.erase(keys.begin()); return k; }
	void clear_keys() { keys.clear(); }

	// video
	void vga_mode13(bool clear);
	PackedByteArray screen() const;
	// true if VGA memory, display start or the DAC changed since the last call
	bool take_video_dirty() { bool d = video_dirty; video_dirty = false; return d; }
	PackedByteArray palette() const;
	int dac_get(int i) const { return dac[i % 768]; }
	void dac_set(int i, int v) { dac[i % 768] = v & 0x3F; video_dirty = true; }
	void vga_set_reg(int bank, int i, int v) { if (bank == 0) seq[i & 7] = v; else if (bank == 1) gc[i & 15] = v; else crtc[i & 31] = v; }
	int vga_reg(int bank, int i) const { return bank == 0 ? seq[i & 7] : bank == 1 ? gc[i & 15] : crtc[i & 31]; }

	// audio: stereo frames generated up to the current emulated time (OPL + Sound Blaster DSP)
	PackedVector2Array take_audio(int max_frames);
	int audio_available() const { return int(audio_count); }
	void set_audio_enabled(bool on) { audio_on = on; }
	int get_stat(int i) const { return (i == 0) ? stat_irq0 : (i == 1) ? stat_bios : (i == 2) ? pit_divisor : (i == 3) ? int(flags) : (i == 4) ? int(stat_ifoff / 1000) : (i == 5) ? int(stat_warp * 1000) : 0; }

	// unhandled-port log for debugging
	String fault_text() const { return fault; }
	void set_breakpoint(int seg, int off) { bp_lin = (seg >= 0) ? int((seg << 4) + off) : -1; }

protected:
	static void _bind_methods();

private:
	std::vector<uint8_t> mem;
	uint8_t planes[4][65536];
	uint8_t latch[4] = {0, 0, 0, 0};
	uint8_t seq[8], gc[16], crtc[32], dac[768];
	int seq_index = 0, gc_index = 0, crtc_index = 0;
	int dac_write = 0, dac_read = 0, dac_comp = 0;

	uint16_t r[8] = {0};
	uint16_t s[4] = {0};
	uint16_t ip = 0;
	uint16_t flags = 2;
	bool halted = false;
	int trap = -1;
	String fault;
	int bp_lin = -1;
	bool video_dirty = true;
	bool audio_on = true;
	std::vector<uint16_t> keys;
	void bios_int16();
	void set_return_flag(uint16_t bit, bool on);

	double emu_time = 0.0;
	double ips = 1000000.0;
	double pit_accum = 0.0;
	int pit_divisor = 65536;
	int pit_latch = 0;
	bool pit_lsb = true;
	double bios_frac = 0.0;
	int retrace_polls = 0;
	bool last_retrace = false;
	int64_t executed = 0;

	// sound: OPL3 (AdLib-compatible at 388h and 220h-223h) and an 8-bit SB DSP with DMA ch 1
	opl3_chip opl;
	int opl_addr = 0;
	int opl_timer_ctrl = 0;
	static const int AUDIO_RATE = 44100;
	static const int RING = AUDIO_RATE * 2;
	std::vector<float> ring;
	size_t audio_head = 0, audio_count = 0;
	double audio_done = 0.0;
	double next_audio = 0.0;
	// DSP
	int dsp_reset = 0;
	std::vector<uint8_t> dsp_out;
	size_t dsp_out_pos = 0;
	int dsp_cmd = -1;
	std::vector<uint8_t> dsp_args;
	int dsp_need = 0;
	int dsp_tc = 0;
	int dsp_block = 0;
	bool dsp_speaker = false;
	bool dsp_playing = false;
	bool dsp_auto = false;
	int dsp_len = 0;
	double dsp_frac = 0.0;
	float dsp_sample = 0.0f;
	bool irq5_pending = false;
	bool irq0_pending = false;
	int stat_irq0 = 0, stat_bios = 0;
	int64_t stat_ifoff = 0;
	double stat_warp = 0.0;
	// PIT channel 2 (used by the AdLib driver to calibrate its OPL write delays) and port 61h
	int pit2_reload = 65536;
	double pit2_start = 0.0;
	int pit2_frozen = 0;
	bool pit2_gate = false;
	int pit2_latched = -1;
	bool pit2_lsb_r = true, pit2_lsb_w = true;
	int pit2_lo = 0;
	int port61 = 0;
	int pit2_count() const;
	// DMA channel 1 and PIC mask
	int dma_addr = 0, dma_count = 0, dma_page = 0;
	int dma_base_addr = 0, dma_base_count = 0;
	bool dma_flip = false;
	bool dma_masked = true;
	int pic_mask = 0x00;

	void audio_until(double t);
	void dsp_write(int v);
	int dsp_read();
	void dsp_command(int cmd);

	// decode state
	int seg_override = -1;
	int rep = 0;
	int m_mod = 0, m_reg = 0, m_rm = 0;
	uint16_t ea = 0;
	uint16_t ea_seg = 0;

	inline uint32_t lin(uint16_t seg, uint16_t off) const { return ((uint32_t(seg) << 4) + off) & 0xFFFFF; }
	uint8_t rb(uint16_t seg, uint16_t off);
	uint16_t rw(uint16_t seg, uint16_t off);
	void wb(uint16_t seg, uint16_t off, uint8_t v);
	void ww(uint16_t seg, uint16_t off, uint16_t v);
	uint8_t vga_read(uint32_t a);
	void vga_write(uint32_t a, uint8_t v);

	uint8_t get_r8(int i) const { return i < 4 ? (r[i] & 0xFF) : (r[i - 4] >> 8); }
	void set_r8(int i, uint8_t v) {
		if (i < 4) r[i] = (r[i] & 0xFF00) | v;
		else r[i - 4] = (r[i - 4] & 0x00FF) | (uint16_t(v) << 8);
	}
	void push(uint16_t v) { r[4] -= 2; ww(s[2], r[4], v); }
	uint16_t pop() { uint16_t v = rw(s[2], r[4]); r[4] += 2; return v; }
	uint8_t fetch8() { uint8_t v = mem[lin(s[1], ip)]; ip++; return v; }
	uint16_t fetch16() { uint16_t v = fetch8(); return v | (uint16_t(fetch8()) << 8); }
	int8_t fetchs8() { return int8_t(fetch8()); }

	void modrm();
	uint8_t rm8();
	uint16_t rm16();
	void set_rm8(uint8_t v);
	void set_rm16(uint16_t v);
	uint16_t dseg() const { return seg_override >= 0 ? s[seg_override] : s[3]; }

	void szp(uint32_t v, bool w);
	void setf(uint16_t bit, bool on) { if (on) flags |= bit; else flags &= ~bit; }
	uint32_t alu(int op, uint32_t a, uint32_t b, bool w);
	uint32_t incdec(uint32_t v, bool dec, bool w);
	uint32_t shift(int op, uint32_t v, int count, bool w);
	bool cond(int c) const;
	void do_interrupt(int n);

	int in_port(int port);
	void out_port(int port, int v);

	void step();
	void exec(uint8_t op);
	void group3(bool w);
	void group5();
	void string_op(uint8_t op);
	void string_io(uint8_t op);
	void bios_tick();
};

} // namespace godot

VARIANT_ENUM_CAST(godot::X86Core::Status);
