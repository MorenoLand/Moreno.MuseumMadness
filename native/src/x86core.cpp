#include "x86core.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

static const uint16_t CF = 0x0001, PF = 0x0004, AF = 0x0010, ZF = 0x0040, SF = 0x0080,
					  TF = 0x0100, IF_ = 0x0200, DF = 0x0400, OF = 0x0800;
static const double PIT_HZ = 1193182.0;
static const double VSYNC = 1.0 / 70.086;
static uint8_t PARITY[256];
static bool parity_ready = false;

X86Core::X86Core() {
	mem.assign(0x110000, 0);
	std::memset(planes, 0, sizeof(planes));
	std::memset(seq, 0, sizeof(seq));
	std::memset(gc, 0, sizeof(gc));
	std::memset(crtc, 0, sizeof(crtc));
	std::memset(dac, 0, sizeof(dac));
	seq[2] = 0x0F;
	seq[4] = 0x0E;
	gc[8] = 0xFF;
	crtc[0x13] = 40;
	OPL3_Reset(&opl, AUDIO_RATE);
	ring.assign(RING * 2, 0.0f);
	if (!parity_ready) {
		for (int i = 0; i < 256; i++) {
			int c = 0;
			for (int b = i; b; b >>= 1) c += b & 1;
			PARITY[i] = (c % 2 == 0) ? 1 : 0;
		}
		parity_ready = true;
	}
}

void X86Core::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "addr", "data"), &X86Core::load);
	ClassDB::bind_method(D_METHOD("read", "addr", "count"), &X86Core::read);
	ClassDB::bind_method(D_METHOD("peek8", "addr"), &X86Core::peek8);
	ClassDB::bind_method(D_METHOD("peek16", "addr"), &X86Core::peek16);
	ClassDB::bind_method(D_METHOD("poke8", "addr", "v"), &X86Core::poke8);
	ClassDB::bind_method(D_METHOD("poke16", "addr", "v"), &X86Core::poke16);
	ClassDB::bind_method(D_METHOD("get_reg", "i"), &X86Core::get_reg);
	ClassDB::bind_method(D_METHOD("set_reg", "i", "v"), &X86Core::set_reg);
	ClassDB::bind_method(D_METHOD("get_sreg", "i"), &X86Core::get_sreg);
	ClassDB::bind_method(D_METHOD("set_sreg", "i", "v"), &X86Core::set_sreg);
	ClassDB::bind_method(D_METHOD("get_ip"), &X86Core::get_ip);
	ClassDB::bind_method(D_METHOD("set_ip", "v"), &X86Core::set_ip);
	ClassDB::bind_method(D_METHOD("get_flags"), &X86Core::get_flags);
	ClassDB::bind_method(D_METHOD("set_flags", "v"), &X86Core::set_flags);
	ClassDB::bind_method(D_METHOD("run", "until", "budget"), &X86Core::run);
	ClassDB::bind_method(D_METHOD("get_trap"), &X86Core::get_trap);
	ClassDB::bind_method(D_METHOD("get_time"), &X86Core::get_time);
	ClassDB::bind_method(D_METHOD("advance", "seconds"), &X86Core::advance);
	ClassDB::bind_method(D_METHOD("set_ips", "v"), &X86Core::set_ips);
	ClassDB::bind_method(D_METHOD("get_executed"), &X86Core::get_executed);
	ClassDB::bind_method(D_METHOD("raise_interrupt", "n"), &X86Core::raise_interrupt);
	ClassDB::bind_method(D_METHOD("enter_isr", "seg", "off"), &X86Core::enter_isr);
	ClassDB::bind_method(D_METHOD("vga_mode13", "clear"), &X86Core::vga_mode13);
	ClassDB::bind_method(D_METHOD("screen"), &X86Core::screen);
	ClassDB::bind_method(D_METHOD("palette"), &X86Core::palette);
	ClassDB::bind_method(D_METHOD("dac_get", "i"), &X86Core::dac_get);
	ClassDB::bind_method(D_METHOD("vga_reg", "bank", "i"), &X86Core::vga_reg);
	ClassDB::bind_method(D_METHOD("vga_set_reg", "bank", "i", "v"), &X86Core::vga_set_reg);
	ClassDB::bind_method(D_METHOD("dac_set", "i", "v"), &X86Core::dac_set);
	ClassDB::bind_method(D_METHOD("fault_text"), &X86Core::fault_text);
	ClassDB::bind_method(D_METHOD("set_breakpoint", "seg", "off"), &X86Core::set_breakpoint);
	ClassDB::bind_method(D_METHOD("take_audio", "max_frames"), &X86Core::take_audio);
	ClassDB::bind_method(D_METHOD("audio_available"), &X86Core::audio_available);
	ClassDB::bind_method(D_METHOD("get_stat", "i"), &X86Core::get_stat);
	BIND_ENUM_CONSTANT(TIME_REACHED);
	BIND_ENUM_CONSTANT(TRAP);
	BIND_ENUM_CONSTANT(HALTED);
	BIND_ENUM_CONSTANT(FAULT);
	BIND_ENUM_CONSTANT(BUDGET);
	BIND_ENUM_CONSTANT(BREAK);
}

// ---- memory -------------------------------------------------------------------------------

void X86Core::load(int addr, const PackedByteArray &data) {
	int n = data.size();
	for (int i = 0; i < n && addr + i < int(mem.size()); i++) mem[addr + i] = data[i];
}

PackedByteArray X86Core::read(int addr, int count) const {
	PackedByteArray out;
	out.resize(count);
	for (int i = 0; i < count; i++) out.set(i, mem[(addr + i) % mem.size()]);
	return out;
}

int X86Core::peek8(int addr) const { return mem[addr & 0xFFFFF]; }
int X86Core::peek16(int addr) const { return mem[addr & 0xFFFFF] | (mem[(addr + 1) & 0xFFFFF] << 8); }
void X86Core::poke8(int addr, int v) { mem[addr & 0xFFFFF] = uint8_t(v); }
void X86Core::poke16(int addr, int v) {
	mem[addr & 0xFFFFF] = uint8_t(v);
	mem[(addr + 1) & 0xFFFFF] = uint8_t(v >> 8);
}

uint8_t X86Core::rb(uint16_t seg, uint16_t off) {
	uint32_t a = lin(seg, off);
	if (a >= 0xA0000 && a < 0xB0000) return vga_read(a);
	return mem[a];
}

uint16_t X86Core::rw(uint16_t seg, uint16_t off) {
	return rb(seg, off) | (uint16_t(rb(seg, uint16_t(off + 1))) << 8);
}

void X86Core::wb(uint16_t seg, uint16_t off, uint8_t v) {
	uint32_t a = lin(seg, off);
	if (a >= 0xA0000 && a < 0xB0000) {
		vga_write(a, v);
		return;
	}
	if (a >= 0xF0000) return; // ROM
	mem[a] = v;
}

void X86Core::ww(uint16_t seg, uint16_t off, uint16_t v) {
	wb(seg, off, uint8_t(v));
	wb(seg, uint16_t(off + 1), uint8_t(v >> 8));
}

// ---- VGA ----------------------------------------------------------------------------------

uint8_t X86Core::vga_read(uint32_t a) {
	uint32_t off = a - 0xA0000;
	if (seq[4] & 0x08) return planes[off & 3][(off >> 2) & 0xFFFF];
	for (int p = 0; p < 4; p++) latch[p] = planes[p][off];
	if (gc[5] & 0x08) {
		uint8_t res = 0xFF;
		for (int p = 0; p < 4; p++) {
			if (!(gc[7] & (1 << p))) continue;
			uint8_t cc = (gc[2] & (1 << p)) ? 0xFF : 0x00;
			res &= ~(latch[p] ^ cc);
		}
		return res;
	}
	return planes[gc[4] & 3][off];
}

void X86Core::vga_write(uint32_t a, uint8_t v) {
	uint32_t off = a - 0xA0000;
	if (seq[4] & 0x08) {
		planes[off & 3][(off >> 2) & 0xFFFF] = v;
		return;
	}
	// Full VGA write pipeline: rotate, set/reset, logical function, bit mask (modes 0-3).
	int mask = seq[2] & 0x0F;
	int mode = gc[5] & 3;
	int rot = gc[3] & 7;
	int func = (gc[3] >> 3) & 3;
	uint8_t bm = gc[8];
	uint8_t val = uint8_t((v >> rot) | (v << (8 - rot)));
	for (int p = 0; p < 4; p++) {
		if (!(mask & (1 << p))) continue;
		uint8_t d;
		uint8_t pmask = bm;
		switch (mode) {
			case 1:
				planes[p][off] = latch[p];
				continue;
			case 2:
				d = (v & (1 << p)) ? 0xFF : 0x00;
				break;
			case 3:
				pmask = bm & val;
				d = (gc[0] & (1 << p)) ? 0xFF : 0x00;
				break;
			default:
				d = (gc[1] & (1 << p)) ? ((gc[0] & (1 << p)) ? 0xFF : 0x00) : val;
				break;
		}
		switch (func) {
			case 1: d &= latch[p]; break;
			case 2: d |= latch[p]; break;
			case 3: d ^= latch[p]; break;
		}
		planes[p][off] = (d & pmask) | (latch[p] & ~pmask);
	}
}

void X86Core::vga_mode13(bool clear) {
	seq[4] = 0x0E;
	seq[2] = 0x0F;
	crtc[0x13] = 40;
	crtc[0x0C] = 0;
	crtc[0x0D] = 0;
	if (clear) std::memset(planes, 0, sizeof(planes));
}

PackedByteArray X86Core::screen() const {
	PackedByteArray out;
	out.resize(64000);
	uint8_t *o = out.ptrw();
	int start = (seq[4] & 0x08) ? 0 : ((crtc[0x0C] << 8) | crtc[0x0D]);
	int pitch = crtc[0x13] * 2;
	if (pitch == 0) pitch = 80;
	for (int y = 0; y < 200; y++) {
		int row = start + y * pitch;
		for (int x = 0; x < 320; x++) *o++ = planes[x & 3][(row + (x >> 2)) & 0xFFFF];
	}
	return out;
}

PackedByteArray X86Core::palette() const {
	PackedByteArray out;
	out.resize(1024);
	uint8_t *o = out.ptrw();
	for (int c = 0; c < 256; c++) {
		for (int k = 0; k < 3; k++) {
			int v = dac[c * 3 + k];
			o[c * 4 + k] = uint8_t((v << 2) | (v >> 4));
		}
		o[c * 4 + 3] = 255;
	}
	return out;
}

// ---- ports --------------------------------------------------------------------------------

int X86Core::in_port(int port) {
	switch (port & 0xFFFF) {
		case 0x3DA: {
			// bit 3 = vertical retrace (first 5% of each frame); a repeated poll on the same side
			// moves emulated time to the edge, so busy waits end immediately.
			double t = std::fmod(emu_time, VSYNC);
			bool in_retrace = t < VSYNC * 0.05;
			if (retrace_polls > 0 && last_retrace == in_retrace) {
				stat_warp += in_retrace ? (VSYNC * 0.05 - t) : (VSYNC - t);
				advance(in_retrace ? (VSYNC * 0.05 - t + 1e-7) : (VSYNC - t + 1e-7));
				in_retrace = !in_retrace;
			}
			retrace_polls++;
			last_retrace = in_retrace;
			return in_retrace ? 0x09 : 0x00;
		}
		case 0x3C9: {
			int v = dac[dac_read * 3 + dac_comp];
			if (++dac_comp == 3) {
				dac_comp = 0;
				dac_read = (dac_read + 1) & 0xFF;
			}
			return v;
		}
		case 0x3C4: return seq_index;
		case 0x3C5: return seq[seq_index & 7];
		case 0x3CE: return gc_index;
		case 0x3CF: return gc[gc_index & 15];
		case 0x3D4: return crtc_index;
		case 0x3D5: return crtc[crtc_index & 31];
		case 0x40: return pit_latch & 0xFF;
		case 0x388: case 0x220: case 0x228: {
			int st = 0;
			if ((opl_timer_ctrl & 1) && !(opl_timer_ctrl & 0x40)) st |= 0xC0;
			if ((opl_timer_ctrl & 2) && !(opl_timer_ctrl & 0x20)) st |= 0xA0;
			return st;
		}
		case 0x22A: return dsp_read();
		case 0x22E:
			irq5_pending = false;
			return (dsp_out_pos < dsp_out.size()) ? 0xFF : 0x7F;
		case 0x22C: return 0x7F;
		case 0x21: return pic_mask;
		case 0x60: return 0;
		case 0x61: {
			// bit 5: channel 2 output (high once a mode-0 count has run out)
			int out = (pit2_gate && pit2_count() == 0) ? 0x20 : 0;
			return (port61 & 0x0F) | out;
		}
		case 0x42: {
			int v = (pit2_latched >= 0) ? pit2_latched : pit2_count();
			int b = pit2_lsb_r ? (v & 0xFF) : ((v >> 8) & 0xFF);
			if (!pit2_lsb_r) pit2_latched = -1;
			pit2_lsb_r = !pit2_lsb_r;
			return b;
		}
	}
	return 0xFF;
}

void X86Core::out_port(int port, int v) {
	v &= 0xFF;
	switch (port & 0xFFFF) {
		case 0x3C4: seq_index = v; break;
		case 0x3C5: seq[seq_index & 7] = v; break;
		case 0x3CE: gc_index = v; break;
		case 0x3CF: gc[gc_index & 15] = v; break;
		case 0x3D4: crtc_index = v; break;
		case 0x3D5: crtc[crtc_index & 31] = v; break;
		case 0x3C7: dac_read = v; dac_comp = 0; break;
		case 0x3C8: dac_write = v; dac_comp = 0; break;
		case 0x3C9:
			dac[dac_write * 3 + dac_comp] = v & 0x3F;
			if (++dac_comp == 3) {
				dac_comp = 0;
				dac_write = (dac_write + 1) & 0xFF;
			}
			break;
		case 0x43:
			if ((v & 0xC0) == 0x80) {
				if ((v & 0x30) == 0) pit2_latched = pit2_count();
				else { pit2_lsb_r = true; pit2_lsb_w = true; }
			} else pit_lsb = true;
			break;
		case 0x42:
			if (pit2_lsb_w) pit2_lo = v;
			else {
				pit2_reload = pit2_lo | (v << 8);
				if (pit2_reload == 0) pit2_reload = 65536;
				pit2_start = emu_time;
				pit2_frozen = pit2_reload;
			}
			pit2_lsb_w = !pit2_lsb_w;
			break;
		case 0x61: {
			bool gate = (v & 1) != 0;
			if (gate && !pit2_gate) pit2_start = emu_time;
			if (!gate && pit2_gate) pit2_frozen = pit2_count();
			pit2_gate = gate;
			port61 = v;
			break;
		}
		case 0x388: case 0x220: case 0x228: opl_addr = v; break;
		case 0x222: opl_addr = 0x100 | v; break;
		case 0x389: case 0x221: case 0x229: case 0x223:
			audio_until(emu_time);
			if ((opl_addr & 0xFF) == 0x04 && !(opl_addr & 0x100)) {
				if (v & 0x80) opl_timer_ctrl = 0;
				else opl_timer_ctrl = v;
			}
			OPL3_WriteReg(&opl, uint16_t(opl_addr), uint8_t(v));
			break;
		case 0x226:
			if (v & 1) dsp_reset = 1;
			else if (dsp_reset) {
				dsp_reset = 0;
				dsp_out.clear();
				dsp_out_pos = 0;
				dsp_out.push_back(0xAA);
				dsp_cmd = -1;
				dsp_playing = false;
			}
			break;
		case 0x22C: dsp_write(v); break;
		case 0x02:
			if (!dma_flip) dma_base_addr = (dma_base_addr & 0xFF00) | v;
			else dma_base_addr = (dma_base_addr & 0x00FF) | (v << 8);
			dma_flip = !dma_flip;
			dma_addr = dma_base_addr;
			break;
		case 0x03:
			if (!dma_flip) dma_base_count = (dma_base_count & 0xFF00) | v;
			else dma_base_count = (dma_base_count & 0x00FF) | (v << 8);
			dma_flip = !dma_flip;
			dma_count = dma_base_count;
			break;
		case 0x83: dma_page = v; break;
		case 0x0A: if ((v & 3) == 1) dma_masked = (v & 4) != 0; break;
		case 0x0C: dma_flip = false; break;
		case 0x21: pic_mask = v; break;
		case 0x40:
			if (pit_lsb) {
				pit_latch = v;
				pit_lsb = false;
			} else {
				pit_divisor = pit_latch | (v << 8);
				if (pit_divisor == 0) pit_divisor = 65536;
				pit_lsb = true;
			}
			break;
	}
}

// ---- time ---------------------------------------------------------------------------------

void X86Core::advance(double seconds) {
	emu_time += seconds;
	pit_accum += seconds * PIT_HZ;
	double div = double(pit_divisor);
	if (pit_accum >= div) {
		pit_accum -= div;
		if (pit_accum > div * 4) pit_accum = 0;
		irq0_pending = true;
	}
	if (irq0_pending && (flags & IF_) && !(pic_mask & 1)) {
		irq0_pending = false;
		halted = false;
		do_interrupt(8);
	}
}

// INT 08 in the BIOS: one tick per call (programs that speed up the PIT, like the AdLib
// driver, chain to the BIOS at the original 18.2 Hz themselves), then INT 1C if hooked.
void X86Core::bios_tick() {
	stat_bios++;
	uint32_t t = peek16(0x46C) | (uint32_t(peek16(0x46E)) << 16);
	t++;
	poke16(0x46C, t & 0xFFFF);
	poke16(0x46E, t >> 16);
	if (peek16(0x1C * 4 + 2) != 0xF000) do_interrupt(0x1C);
}

// ---- flags & ALU --------------------------------------------------------------------------

void X86Core::szp(uint32_t v, bool w) {
	flags &= ~(SF | ZF | PF);
	if (w) {
		v &= 0xFFFF;
		if (v & 0x8000) flags |= SF;
	} else {
		v &= 0xFF;
		if (v & 0x80) flags |= SF;
	}
	if (v == 0) flags |= ZF;
	if (PARITY[v & 0xFF]) flags |= PF;
}

uint32_t X86Core::alu(int op, uint32_t a, uint32_t b, bool w) {
	uint32_t mask = w ? 0xFFFF : 0xFF;
	uint32_t sign = w ? 0x8000 : 0x80;
	int32_t res = 0;
	switch (op) {
		case 0: case 2: {
			int c = (op == 2) ? (flags & CF) : 0;
			res = int32_t(a + b + c);
			setf(CF, uint32_t(res) > mask);
			setf(OF, ((a ^ res) & (b ^ res) & sign) != 0);
			setf(AF, ((a ^ b ^ res) & 0x10) != 0);
			break;
		}
		case 1: res = a | b; flags &= ~(CF | OF | AF); break;
		case 4: res = a & b; flags &= ~(CF | OF | AF); break;
		case 6: res = a ^ b; flags &= ~(CF | OF | AF); break;
		case 3: case 5: case 7: {
			int c = (op == 3) ? (flags & CF) : 0;
			res = int32_t(a) - int32_t(b) - c;
			setf(CF, res < 0);
			setf(OF, ((a ^ b) & (a ^ res) & sign) != 0);
			setf(AF, ((a ^ b ^ res) & 0x10) != 0);
			break;
		}
	}
	uint32_t out = uint32_t(res) & mask;
	szp(out, w);
	return out;
}

uint32_t X86Core::incdec(uint32_t v, bool dec, bool w) {
	uint32_t mask = w ? 0xFFFF : 0xFF;
	uint32_t sign = w ? 0x8000 : 0x80;
	uint32_t res = (dec ? v - 1 : v + 1) & mask;
	if (dec) {
		setf(OF, v == sign);
		setf(AF, (v & 0xF) == 0);
	} else {
		setf(OF, res == sign);
		setf(AF, (res & 0xF) == 0);
	}
	szp(res, w);
	return res;
}

uint32_t X86Core::shift(int op, uint32_t v, int count, bool w) {
	int bits = w ? 16 : 8;
	uint32_t mask = w ? 0xFFFF : 0xFF;
	uint32_t sign = w ? 0x8000 : 0x80;
	count &= 0x1F;
	if (count == 0) return v;
	uint32_t res = v;
	switch (op) {
		case 0:
			for (int i = 0; i < count; i++) res = ((res << 1) | ((res & sign) ? 1 : 0)) & mask;
			setf(CF, res & 1);
			setf(OF, ((res & sign) != 0) != ((flags & CF) != 0));
			return res;
		case 1:
			for (int i = 0; i < count; i++) res = (res >> 1) | ((res & 1) ? sign : 0);
			setf(CF, (res & sign) != 0);
			setf(OF, ((res ^ (res << 1)) & sign) != 0);
			return res;
		case 2:
			for (int i = 0; i < count; i++) {
				uint32_t c = (flags & CF) ? 1 : 0;
				setf(CF, (res & sign) != 0);
				res = ((res << 1) | c) & mask;
			}
			setf(OF, ((res & sign) != 0) != ((flags & CF) != 0));
			return res;
		case 3:
			for (int i = 0; i < count; i++) {
				uint32_t c = (flags & CF) ? sign : 0;
				setf(CF, res & 1);
				res = (res >> 1) | c;
			}
			setf(OF, ((res ^ (res << 1)) & sign) != 0);
			return res;
		case 4: case 6:
			if (count > bits) {
				res = 0;
				setf(CF, false);
			} else {
				setf(CF, ((v << (count - 1)) & sign) != 0);
				res = (v << count) & mask;
			}
			setf(OF, ((res & sign) != 0) != ((flags & CF) != 0));
			break;
		case 5:
			if (count > bits) {
				res = 0;
				setf(CF, false);
			} else {
				setf(CF, ((v >> (count - 1)) & 1) != 0);
				res = v >> count;
			}
			setf(OF, (v & sign) != 0);
			break;
		case 7: {
			int32_t sv = (v & sign) ? int32_t(v) - int32_t(mask + 1) : int32_t(v);
			if (count >= bits) {
				res = sv < 0 ? mask : 0;
				setf(CF, sv < 0);
			} else {
				setf(CF, ((sv >> (count - 1)) & 1) != 0);
				res = uint32_t(sv >> count) & mask;
			}
			setf(OF, false);
			break;
		}
	}
	szp(res, w);
	return res;
}

bool X86Core::cond(int c) const {
	bool res = false;
	switch (c >> 1) {
		case 0: res = flags & OF; break;
		case 1: res = flags & CF; break;
		case 2: res = flags & ZF; break;
		case 3: res = flags & (CF | ZF); break;
		case 4: res = flags & SF; break;
		case 5: res = flags & PF; break;
		case 6: res = ((flags & SF) != 0) != ((flags & OF) != 0); break;
		case 7: res = (flags & ZF) || (((flags & SF) != 0) != ((flags & OF) != 0)); break;
	}
	return res != bool(c & 1);
}

void X86Core::do_interrupt(int n) {
	push(flags);
	push(s[1]);
	push(ip);
	flags &= ~(IF_ | TF);
	ip = peek16(n * 4);
	s[1] = peek16(n * 4 + 2);
}

// ---- ModRM --------------------------------------------------------------------------------

void X86Core::modrm() {
	uint8_t b = fetch8();
	m_mod = b >> 6;
	m_reg = (b >> 3) & 7;
	m_rm = b & 7;
	if (m_mod == 3) return;
	uint16_t off = 0;
	int dseg_i = 3;
	switch (m_rm) {
		case 0: off = r[3] + r[6]; break;
		case 1: off = r[3] + r[7]; break;
		case 2: off = r[5] + r[6]; dseg_i = 2; break;
		case 3: off = r[5] + r[7]; dseg_i = 2; break;
		case 4: off = r[6]; break;
		case 5: off = r[7]; break;
		case 6:
			if (m_mod == 0) off = fetch16();
			else { off = r[5]; dseg_i = 2; }
			break;
		case 7: off = r[3]; break;
	}
	if (m_mod == 1) off += int16_t(fetchs8());
	else if (m_mod == 2) off += fetch16();
	ea = off;
	ea_seg = seg_override >= 0 ? s[seg_override] : s[dseg_i];
}

uint8_t X86Core::rm8() { return m_mod == 3 ? get_r8(m_rm) : rb(ea_seg, ea); }
uint16_t X86Core::rm16() { return m_mod == 3 ? r[m_rm] : rw(ea_seg, ea); }
void X86Core::set_rm8(uint8_t v) { if (m_mod == 3) set_r8(m_rm, v); else wb(ea_seg, ea, v); }
void X86Core::set_rm16(uint16_t v) { if (m_mod == 3) r[m_rm] = v; else ww(ea_seg, ea, v); }

// ---- run ----------------------------------------------------------------------------------

int X86Core::run(double until, int budget) {
	trap = -1;
	const double dt = 1.0 / ips;
	const double pit_step = PIT_HZ / ips;
	int count = 0;
	while (emu_time < until) {
		if (halted) return HALTED;
		if (count >= budget) return BUDGET;
		step();
		if (!(flags & IF_)) stat_ifoff++;
		count++;
		executed++;
		emu_time += dt;
		pit_accum += pit_step;
		if (pit_accum >= double(pit_divisor)) {
			pit_accum -= double(pit_divisor);
			irq0_pending = true;
		}
		// The PIC holds a request until interrupts are enabled (and the line is unmasked).
		if (irq0_pending && (flags & IF_) && !(pic_mask & 1)) {
			irq0_pending = false;
			stat_irq0++;
			do_interrupt(8);
		}
		if (emu_time >= next_audio) {
			audio_until(emu_time);
			next_audio = emu_time + 0.001;
		}
		if (irq5_pending && (flags & IF_) && !(pic_mask & 0x20)) {
			irq5_pending = false;
			do_interrupt(0x0D);
		}
		if (trap >= 0) return TRAP;
		if (!fault.is_empty()) return FAULT;
		if (bp_lin >= 0 && int(lin(s[1], ip)) == bp_lin) return BREAK;
	}
	return TIME_REACHED;
}

void X86Core::step() {
	seg_override = -1;
	rep = 0;
	uint8_t op = fetch8();
	for (;;) {
		switch (op) {
			case 0x26: seg_override = 0; break;
			case 0x2E: seg_override = 1; break;
			case 0x36: seg_override = 2; break;
			case 0x3E: seg_override = 3; break;
			case 0xF2: case 0xF3: rep = op; break;
			case 0xF0: break;
			default: exec(op); return;
		}
		op = fetch8();
	}
}

void X86Core::exec(uint8_t op) {
	if (op < 0x40 && (op & 7) < 6) {
		int a_op = op >> 3;
		bool w = op & 1;
		switch (op & 7) {
			case 0: case 1: {
				modrm();
				uint32_t a = w ? rm16() : rm8();
				uint32_t b = w ? r[m_reg] : get_r8(m_reg);
				uint32_t res = alu(a_op, a, b, w);
				if (a_op != 7) { if (w) set_rm16(res); else set_rm8(res); }
				return;
			}
			case 2: case 3: {
				modrm();
				uint32_t a = w ? r[m_reg] : get_r8(m_reg);
				uint32_t b = w ? rm16() : rm8();
				uint32_t res = alu(a_op, a, b, w);
				if (a_op != 7) { if (w) r[m_reg] = res; else set_r8(m_reg, res); }
				return;
			}
			case 4: {
				uint32_t res = alu(a_op, get_r8(0), fetch8(), false);
				if (a_op != 7) set_r8(0, res);
				return;
			}
			case 5: {
				uint32_t res = alu(a_op, r[0], fetch16(), true);
				if (a_op != 7) r[0] = res;
				return;
			}
		}
	}
	switch (op) {
		case 0x06: push(s[0]); break;
		case 0x07: s[0] = pop(); break;
		case 0x0E: push(s[1]); break;
		case 0x16: push(s[2]); break;
		case 0x17: s[2] = pop(); break;
		case 0x1E: push(s[3]); break;
		case 0x1F: s[3] = pop(); break;
		case 0x27: {
			uint8_t al = get_r8(0);
			bool c = flags & CF;
			if ((al & 0xF) > 9 || (flags & AF)) { al += 6; flags |= AF; }
			if (get_r8(0) > 0x99 || c) { al += 0x60; flags |= CF; }
			set_r8(0, al);
			szp(al, false);
			break;
		}
		case 0x2F: {
			uint8_t al = get_r8(0);
			bool c = flags & CF;
			if ((al & 0xF) > 9 || (flags & AF)) { al -= 6; flags |= AF; }
			if (get_r8(0) > 0x99 || c) { al -= 0x60; flags |= CF; }
			set_r8(0, al);
			szp(al, false);
			break;
		}
		case 0x37:
			if ((get_r8(0) & 0xF) > 9 || (flags & AF)) { r[0] += 0x106; flags |= AF | CF; }
			else flags &= ~(AF | CF);
			set_r8(0, get_r8(0) & 0xF);
			break;
		case 0x3F:
			if ((get_r8(0) & 0xF) > 9 || (flags & AF)) {
				r[0] -= 6;
				set_r8(4, get_r8(4) - 1);
				flags |= AF | CF;
			} else flags &= ~(AF | CF);
			set_r8(0, get_r8(0) & 0xF);
			break;
		case 0x40: case 0x41: case 0x42: case 0x43: case 0x44: case 0x45: case 0x46: case 0x47: {
			uint16_t c = flags & CF;
			r[op & 7] = incdec(r[op & 7], false, true);
			flags = (flags & ~CF) | c;
			break;
		}
		case 0x48: case 0x49: case 0x4A: case 0x4B: case 0x4C: case 0x4D: case 0x4E: case 0x4F: {
			uint16_t c = flags & CF;
			r[op & 7] = incdec(r[op & 7], true, true);
			flags = (flags & ~CF) | c;
			break;
		}
		case 0x50: case 0x51: case 0x52: case 0x53: case 0x55: case 0x56: case 0x57: push(r[op & 7]); break;
		case 0x54: { uint16_t v = r[4]; push(v); break; }
		case 0x58: case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F:
			r[op & 7] = pop();
			break;
		case 0x60: {
			uint16_t sp0 = r[4];
			for (int i = 0; i < 8; i++) push(i == 4 ? sp0 : r[i]);
			break;
		}
		case 0x61:
			for (int i = 7; i >= 0; i--) {
				uint16_t v = pop();
				if (i != 4) r[i] = v;
			}
			break;
		case 0x62: modrm(); break;
		case 0x68: push(fetch16()); break;
		case 0x69: case 0x6B: {
			modrm();
			int32_t a = int16_t(rm16());
			int32_t b = (op == 0x69) ? int32_t(int16_t(fetch16())) : int32_t(fetchs8());
			int32_t res = a * b;
			r[m_reg] = uint16_t(res);
			bool ov = res < -32768 || res > 32767;
			setf(CF, ov);
			setf(OF, ov);
			break;
		}
		case 0x6A: push(uint16_t(int16_t(fetchs8()))); break;
		case 0x6C: case 0x6D: case 0x6E: case 0x6F: string_io(op); break;
		case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
		case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F: {
			int8_t d = fetchs8();
			if (cond(op & 0xF)) ip += d;
			break;
		}
		case 0x80: case 0x81: case 0x82: case 0x83: {
			modrm();
			bool w = op & 1;
			uint32_t a = w ? rm16() : rm8();
			uint32_t b;
			if (op == 0x81) b = fetch16();
			else if (op == 0x83) b = uint16_t(int16_t(fetchs8()));
			else b = fetch8();
			uint32_t res = alu(m_reg, a, b, w);
			if (m_reg != 7) { if (w) set_rm16(res); else set_rm8(res); }
			break;
		}
		case 0x84: modrm(); alu(4, rm8(), get_r8(m_reg), false); break;
		case 0x85: modrm(); alu(4, rm16(), r[m_reg], true); break;
		case 0x86: { modrm(); uint8_t t = rm8(); set_rm8(get_r8(m_reg)); set_r8(m_reg, t); break; }
		case 0x87: { modrm(); uint16_t t = rm16(); set_rm16(r[m_reg]); r[m_reg] = t; break; }
		case 0x88: modrm(); set_rm8(get_r8(m_reg)); break;
		case 0x89: modrm(); set_rm16(r[m_reg]); break;
		case 0x8A: modrm(); set_r8(m_reg, rm8()); break;
		case 0x8B: modrm(); r[m_reg] = rm16(); break;
		case 0x8C: modrm(); set_rm16(s[m_reg & 3]); break;
		case 0x8D: modrm(); r[m_reg] = ea; break;
		case 0x8E: modrm(); s[m_reg & 3] = rm16(); break;
		case 0x8F: { modrm(); uint16_t v = pop(); set_rm16(v); break; }
		case 0x90: break;
		case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97: {
			uint16_t t = r[0];
			r[0] = r[op & 7];
			r[op & 7] = t;
			break;
		}
		case 0x98: r[0] = uint16_t(int16_t(int8_t(r[0] & 0xFF))); break;
		case 0x99: r[2] = (r[0] & 0x8000) ? 0xFFFF : 0; break;
		case 0x9A: {
			uint16_t off = fetch16();
			uint16_t seg = fetch16();
			push(s[1]);
			push(ip);
			s[1] = seg;
			ip = off;
			break;
		}
		case 0x9B: break;
		case 0x9C: push(flags | 0xF002); break;
		case 0x9D: flags = (pop() & 0x0FD5) | 2; break;
		case 0x9E: flags = (flags & 0xFF00) | (get_r8(4) & 0xD5) | 2; break;
		case 0x9F: set_r8(4, flags & 0xFF); break;
		case 0xA0: set_r8(0, rb(dseg(), fetch16())); break;
		case 0xA1: r[0] = rw(dseg(), fetch16()); break;
		case 0xA2: wb(dseg(), fetch16(), get_r8(0)); break;
		case 0xA3: ww(dseg(), fetch16(), r[0]); break;
		case 0xA4: case 0xA5: case 0xA6: case 0xA7: case 0xAA: case 0xAB: case 0xAC: case 0xAD:
		case 0xAE: case 0xAF:
			string_op(op);
			break;
		case 0xA8: alu(4, get_r8(0), fetch8(), false); break;
		case 0xA9: alu(4, r[0], fetch16(), true); break;
		case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:
			set_r8(op & 7, fetch8());
			break;
		case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:
			r[op & 7] = fetch16();
			break;
		case 0xC0: case 0xC1: case 0xD0: case 0xD1: case 0xD2: case 0xD3: {
			modrm();
			bool w = op & 1;
			int count = 1;
			if (op <= 0xC1) count = fetch8();
			else if (op >= 0xD2) count = get_r8(1);
			uint32_t res = shift(m_reg, w ? rm16() : rm8(), count, w);
			if (w) set_rm16(res); else set_rm8(res);
			break;
		}
		case 0xC2: { uint16_t n = fetch16(); ip = pop(); r[4] += n; break; }
		case 0xC3: ip = pop(); break;
		case 0xC4: case 0xC5: {
			modrm();
			r[m_reg] = rw(ea_seg, ea);
			s[op == 0xC4 ? 0 : 3] = rw(ea_seg, uint16_t(ea + 2));
			break;
		}
		case 0xC6: modrm(); set_rm8(fetch8()); break;
		case 0xC7: modrm(); set_rm16(fetch16()); break;
		case 0xC8: {
			uint16_t size = fetch16();
			int level = fetch8() & 0x1F;
			push(r[5]);
			uint16_t frame = r[4];
			if (level > 0) {
				for (int i = 1; i < level; i++) {
					r[5] -= 2;
					push(rw(s[2], r[5]));
				}
				push(frame);
			}
			r[5] = frame;
			r[4] -= size;
			break;
		}
		case 0xC9: r[4] = r[5]; r[5] = pop(); break;
		case 0xCA: { uint16_t n = fetch16(); ip = pop(); s[1] = pop(); r[4] += n; break; }
		case 0xCB: ip = pop(); s[1] = pop(); break;
		case 0xCC: do_interrupt(3); break;
		case 0xCD: do_interrupt(fetch8()); break;
		case 0xCE: if (flags & OF) do_interrupt(4); break;
		case 0xCF: ip = pop(); s[1] = pop(); flags = (pop() & 0x0FD5) | 2; break;
		case 0xD4: {
			int base = fetch8();
			if (base == 0) base = 10;
			uint8_t al = get_r8(0);
			set_r8(4, al / base);
			set_r8(0, al % base);
			szp(get_r8(0), false);
			break;
		}
		case 0xD5: {
			int base = fetch8();
			uint8_t v = uint8_t(get_r8(4) * base + get_r8(0));
			r[0] = v;
			szp(v, false);
			break;
		}
		case 0xD6: set_r8(0, (flags & CF) ? 0xFF : 0); break;
		case 0xD7: set_r8(0, rb(dseg(), uint16_t(r[3] + get_r8(0)))); break;
		case 0xD8: case 0xD9: case 0xDA: case 0xDB: case 0xDC: case 0xDD: case 0xDE: case 0xDF:
			modrm();
			break;
		case 0xE0: case 0xE1: case 0xE2: {
			int8_t d = fetchs8();
			r[1]--;
			bool z = flags & ZF;
			bool take = r[1] != 0;
			if (op == 0xE0) take = take && !z;
			else if (op == 0xE1) take = take && z;
			if (take) ip += d;
			break;
		}
		case 0xE3: { int8_t d = fetchs8(); if (r[1] == 0) ip += d; break; }
		case 0xE4: set_r8(0, in_port(fetch8())); break;
		case 0xE5: { int p = fetch8(); r[0] = in_port(p) | (in_port(p + 1) << 8); break; }
		case 0xE6: out_port(fetch8(), get_r8(0)); break;
		case 0xE7: { int p = fetch8(); out_port(p, r[0] & 0xFF); out_port(p + 1, r[0] >> 8); break; }
		case 0xE8: { uint16_t d = fetch16(); push(ip); ip += d; break; }
		case 0xE9: { uint16_t d = fetch16(); ip += d; break; }
		case 0xEA: { uint16_t off = fetch16(); s[1] = fetch16(); ip = off; break; }
		case 0xEB: { int8_t d = fetchs8(); ip += d; break; }
		case 0xEC: set_r8(0, in_port(r[2])); break;
		case 0xED: r[0] = in_port(r[2]) | (in_port(r[2] + 1) << 8); break;
		case 0xEE: out_port(r[2], get_r8(0)); break;
		case 0xEF: out_port(r[2], r[0] & 0xFF); out_port(r[2] + 1, r[0] >> 8); break;
		case 0xF1: {
			int n = fetch8();
			if (n == 0x08) bios_tick();
			else trap = n;
			break;
		}
		case 0xF4: halted = true; break;
		case 0xF5: flags ^= CF; break;
		case 0xF6: group3(false); break;
		case 0xF7: group3(true); break;
		case 0xF8: flags &= ~CF; break;
		case 0xF9: flags |= CF; break;
		case 0xFA: flags &= ~IF_; break;
		case 0xFB: flags |= IF_; break;
		case 0xFC: flags &= ~DF; break;
		case 0xFD: flags |= DF; break;
		case 0xFE: {
			modrm();
			if (m_reg <= 1) {
				uint16_t c = flags & CF;
				set_rm8(incdec(rm8(), m_reg == 1, false));
				flags = (flags & ~CF) | c;
			}
			break;
		}
		case 0xFF: group5(); break;
		default:
			fault = vformat("unknown opcode %02X at %04X:%04X", op, s[1], uint16_t(ip - 1));
			break;
	}
}

void X86Core::group3(bool w) {
	modrm();
	switch (m_reg) {
		case 0: case 1:
			if (w) alu(4, rm16(), fetch16(), true);
			else alu(4, rm8(), fetch8(), false);
			break;
		case 2:
			if (w) set_rm16(~rm16());
			else set_rm8(~rm8());
			break;
		case 3: {
			uint32_t v = w ? rm16() : rm8();
			uint32_t res = alu(5, 0, v, w);
			setf(CF, v != 0);
			if (w) set_rm16(res); else set_rm8(res);
			break;
		}
		case 4:
			if (w) {
				uint32_t res = uint32_t(r[0]) * rm16();
				r[0] = res & 0xFFFF;
				r[2] = res >> 16;
				setf(CF, r[2] != 0);
				setf(OF, r[2] != 0);
			} else {
				uint32_t res = uint32_t(get_r8(0)) * rm8();
				r[0] = res;
				setf(CF, (res & 0xFF00) != 0);
				setf(OF, (res & 0xFF00) != 0);
			}
			break;
		case 5:
			if (w) {
				int32_t res = int32_t(int16_t(r[0])) * int32_t(int16_t(rm16()));
				r[0] = uint16_t(res);
				r[2] = uint16_t(uint32_t(res) >> 16);
				bool ov = res < -32768 || res > 32767;
				setf(CF, ov);
				setf(OF, ov);
			} else {
				int32_t res = int32_t(int8_t(get_r8(0))) * int32_t(int8_t(rm8()));
				r[0] = uint16_t(res);
				bool ov = res < -128 || res > 127;
				setf(CF, ov);
				setf(OF, ov);
			}
			break;
		case 6:
			if (w) {
				uint32_t d = rm16();
				uint32_t n = (uint32_t(r[2]) << 16) | r[0];
				if (d == 0 || n / d > 0xFFFF) { do_interrupt(0); return; }
				r[0] = n / d;
				r[2] = n % d;
			} else {
				uint32_t d = rm8();
				uint32_t n = r[0];
				if (d == 0 || n / d > 0xFF) { do_interrupt(0); return; }
				set_r8(0, n / d);
				set_r8(4, n % d);
			}
			break;
		case 7:
			if (w) {
				int32_t d = int16_t(rm16());
				int32_t n = int32_t((uint32_t(r[2]) << 16) | r[0]);
				if (d == 0) { do_interrupt(0); return; }
				int32_t q = n / d, m = n % d;
				if (q > 32767 || q < -32768) { do_interrupt(0); return; }
				r[0] = uint16_t(q);
				r[2] = uint16_t(m);
			} else {
				int32_t d = int8_t(rm8());
				int32_t n = int16_t(r[0]);
				if (d == 0) { do_interrupt(0); return; }
				int32_t q = n / d, m = n % d;
				if (q > 127 || q < -128) { do_interrupt(0); return; }
				set_r8(0, uint8_t(q));
				set_r8(4, uint8_t(m));
			}
			break;
	}
}

void X86Core::group5() {
	modrm();
	switch (m_reg) {
		case 0: case 1: {
			uint16_t c = flags & CF;
			set_rm16(incdec(rm16(), m_reg == 1, true));
			flags = (flags & ~CF) | c;
			break;
		}
		case 2: { uint16_t t = rm16(); push(ip); ip = t; break; }
		case 3: {
			uint16_t off = rw(ea_seg, ea);
			uint16_t seg = rw(ea_seg, uint16_t(ea + 2));
			push(s[1]);
			push(ip);
			s[1] = seg;
			ip = off;
			break;
		}
		case 4: ip = rm16(); break;
		case 5: {
			uint16_t off = rw(ea_seg, ea);
			s[1] = rw(ea_seg, uint16_t(ea + 2));
			ip = off;
			break;
		}
		case 6: push(rm16()); break;
	}
}

void X86Core::string_op(uint8_t op) {
	bool w = op & 1;
	int16_t st = w ? 2 : 1;
	if (flags & DF) st = -st;
	uint16_t src = dseg();
	uint32_t count = rep ? r[1] : 1;
	if (rep && count == 0) return;
	while (count > 0) {
		switch (op) {
			case 0xA4: wb(s[0], r[7], rb(src, r[6])); r[6] += st; r[7] += st; break;
			case 0xA5: ww(s[0], r[7], rw(src, r[6])); r[6] += st; r[7] += st; break;
			case 0xAA: wb(s[0], r[7], get_r8(0)); r[7] += st; break;
			case 0xAB: ww(s[0], r[7], r[0]); r[7] += st; break;
			case 0xAC: set_r8(0, rb(src, r[6])); r[6] += st; break;
			case 0xAD: r[0] = rw(src, r[6]); r[6] += st; break;
			case 0xA6: case 0xA7: {
				uint32_t a = w ? rw(src, r[6]) : rb(src, r[6]);
				uint32_t b = w ? rw(s[0], r[7]) : rb(s[0], r[7]);
				alu(7, a, b, w);
				r[6] += st;
				r[7] += st;
				break;
			}
			case 0xAE: case 0xAF: {
				uint32_t b = w ? rw(s[0], r[7]) : rb(s[0], r[7]);
				alu(7, w ? r[0] : get_r8(0), b, w);
				r[7] += st;
				break;
			}
		}
		if (!rep) return;
		count--;
		r[1] = count;
		executed++;
		if (op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF) {
			bool z = flags & ZF;
			if ((rep == 0xF3 && !z) || (rep == 0xF2 && z)) return;
		}
	}
}

void X86Core::string_io(uint8_t op) {
	bool w = op & 1;
	int16_t st = w ? 2 : 1;
	if (flags & DF) st = -st;
	uint32_t count = rep ? r[1] : 1;
	while (count > 0) {
		if (op <= 0x6D) {
			int v = in_port(r[2]);
			if (w) ww(s[0], r[7], v | (in_port(r[2] + 1) << 8));
			else wb(s[0], r[7], v);
			r[7] += st;
		} else {
			if (w) {
				uint16_t v = rw(dseg(), r[6]);
				out_port(r[2], v & 0xFF);
				out_port(r[2] + 1, v >> 8);
			} else out_port(r[2], rb(dseg(), r[6]));
			r[6] += st;
		}
		count--;
		if (rep) r[1] = count;
		else return;
	}
}

// ---- sound --------------------------------------------------------------------------------

int X86Core::dsp_read() {
	if (dsp_out_pos < dsp_out.size()) {
		int v = dsp_out[dsp_out_pos++];
		if (dsp_out_pos >= dsp_out.size()) {
			dsp_out.clear();
			dsp_out_pos = 0;
		}
		return v;
	}
	return 0xAA;
}

void X86Core::dsp_write(int v) {
	if (dsp_cmd < 0) {
		dsp_cmd = v;
		dsp_args.clear();
		switch (v) {
			case 0x10: case 0x40: case 0xE0: case 0x38: dsp_need = 1; break;
			case 0x14: case 0x16: case 0x17: case 0x24: case 0x48: case 0x74: case 0x75: dsp_need = 2; break;
			default: dsp_need = 0; break;
		}
		if (dsp_need == 0) {
			dsp_command(v);
			dsp_cmd = -1;
		}
		return;
	}
	dsp_args.push_back(uint8_t(v));
	if (int(dsp_args.size()) >= dsp_need) {
		dsp_command(dsp_cmd);
		dsp_cmd = -1;
	}
}

void X86Core::dsp_command(int cmd) {
	switch (cmd) {
		case 0x10: dsp_sample = (int(dsp_args[0]) - 128) / 128.0f; break;
		case 0x14: case 0x16: case 0x17: case 0x74: case 0x75:
			dsp_len = dsp_args[0] | (dsp_args[1] << 8);
			dsp_playing = true;
			dsp_auto = false;
			break;
		case 0x1C: case 0x90:
			dsp_len = dsp_block;
			dsp_playing = true;
			dsp_auto = true;
			break;
		case 0x91:
			dsp_len = dsp_block;
			dsp_playing = true;
			dsp_auto = false;
			break;
		case 0x40: dsp_tc = dsp_args[0]; break;
		case 0x48: dsp_block = dsp_args[0] | (dsp_args[1] << 8); break;
		case 0xD0: dsp_playing = false; break;
		case 0xD4: dsp_playing = true; break;
		case 0xD1: dsp_speaker = true; break;
		case 0xD3: dsp_speaker = false; break;
		case 0xDA: dsp_auto = false; break;
		case 0xD8: dsp_out.push_back(dsp_speaker ? 0xFF : 0x00); break;
		case 0xE0: dsp_out.push_back(uint8_t(~dsp_args[0])); break;
		case 0xE1: dsp_out.push_back(2); dsp_out.push_back(1); break;
		case 0x20: dsp_out.push_back(0x80); break;
		case 0xF2: irq5_pending = true; break;
		default: break;
	}
}

void X86Core::audio_until(double t) {
	double target = std::floor(t * AUDIO_RATE);
	int frames = int(target - audio_done);
	if (frames <= 0) return;
	if (frames > AUDIO_RATE) {
		audio_done = target - AUDIO_RATE;
		frames = AUDIO_RATE;
	}
	double dsp_rate = (dsp_tc > 0 && dsp_tc < 256) ? 1000000.0 / (256 - dsp_tc) : 22050.0;
	double step = dsp_rate / AUDIO_RATE;
	int16_t buf[2];
	for (int i = 0; i < frames; i++) {
		OPL3_GenerateResampled(&opl, buf);
		if (dsp_playing && !dma_masked) {
			dsp_frac += step;
			while (dsp_frac >= 1.0) {
				dsp_frac -= 1.0;
				uint32_t a = (uint32_t(dma_page) << 16) | uint32_t(dma_addr & 0xFFFF);
				dsp_sample = (int(mem[a & 0xFFFFF]) - 128) / 128.0f;
				dma_addr = (dma_addr + 1) & 0xFFFF;
				dma_count = (dma_count - 1) & 0xFFFF;
				if (dma_count == 0xFFFF) {
					dma_addr = dma_base_addr;
					dma_count = dma_base_count;
				}
				if (--dsp_len < 0) {
					irq5_pending = true;
					if (dsp_auto) dsp_len = dsp_block;
					else {
						dsp_playing = false;
						break;
					}
				}
			}
		}
		float pcm = (dsp_speaker || dsp_playing) ? dsp_sample * 0.6f : 0.0f;
		float l = buf[0] / 32768.0f + pcm;
		float rr = buf[1] / 32768.0f + pcm;
		size_t pos = (audio_head + audio_count) % RING;
		ring[pos * 2] = l;
		ring[pos * 2 + 1] = rr;
		if (audio_count < size_t(RING)) audio_count++;
		else audio_head = (audio_head + 1) % RING;
	}
	audio_done += frames;
}

PackedVector2Array X86Core::take_audio(int max_frames) {
	PackedVector2Array out;
	int n = int(audio_count < size_t(max_frames) ? audio_count : size_t(max_frames));
	out.resize(n);
	for (int i = 0; i < n; i++) {
		size_t pos = (audio_head + i) % RING;
		out.set(i, Vector2(ring[pos * 2], ring[pos * 2 + 1]));
	}
	audio_head = (audio_head + n) % RING;
	audio_count -= n;
	return out;
}

int X86Core::pit2_count() const {
	if (!pit2_gate) return pit2_frozen & 0xFFFF;
	int64_t ticks = int64_t((emu_time - pit2_start) * PIT_HZ);
	int64_t c = int64_t(pit2_reload) - ticks;
	if (c < 0) c = 0;
	return int(c) & 0xFFFF;
}
