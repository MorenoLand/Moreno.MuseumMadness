# MUSEUM.NDX / MUSEUM.RES Format

Status: **verified**. The decoder reproduces every one of the 2026 resources at exactly its indexed unpacked size, and it consumes exactly the stored byte count of each one. Its GDScript output matches the Python reference by SHA-256.
Source of truth: `MUSEUMG.OVL`, which is EXEPACK-compressed and had to be unpacked before analysis. The functions are named by their addresses in a Ghidra analysis of the unpacked image (load segment 0x1000, DGROUP 0x4241).

| Routine | Role |
|---|---|
| `27c4:98dc` | Opens `MUSEUM.RES` (handle at DS:1FCE) and `MUSEUM.NDX` (handle at DS:1FB6) |
| `27c4:9828` | Binary-searches NDX by id (records sorted by id) |
| `27c4:9996` | 8-slot cache of NDX records |
| `27c4:9a28` | Reads (part of) a resource; walks compressed blocks |
| `27c4:efe1` | LZ block decompressor (hand-written assembly) |
| `17ea:ef30`, `17ea:ef6e` | Writes palettes to the VGA DAC |

## NDX
The file is an array of 16-byte little-endian records, sorted by id:

```
u16 id
u16 type          ; bit 15 = compressed; low bits = 1, 2 or 3
u32 offset        ; into MUSEUM.RES
u32 stored_size
u32 unpacked_size
```

## RES storage
- **Uncompressed:** the resource is `stored_size` raw bytes at `offset`.
- **Compressed:** the resource is a sequence of blocks, read until `unpacked_size` bytes have been produced. Each block is:
  ```
  u32 block_unpacked   ; at most 0x8000 (the loader advances its output by 32 KB per block)
  u32 block_packed
  u8  data[block_packed]
  ```
  A loader can start decoding at any block boundary. Image banks rely on this, because each image record stores the offset of its first block.

## LZ block
The block data is an LSB-first bitstream, read with `bits(n)` (least-significant bit first). Decoding repeats until `block_unpacked` bytes have been written:

```
if bits(1) == 1:            literal: out += bits(8)
else:
    dist = bits(13) if bits(1) else bits(10)
    n = 2; while bits(1) == 0: n += 1
    len = bits(n) + 2^n - 2
    copy len bytes from out[pos - dist - 1] (byte by byte, overlap allowed)
```

## Content types (decoded)
| Type | Count | Observed content |
|---|---:|---|
| 1 | 161 | 127 `RIFF WAVE` (8-bit mono, 11025 Hz), 18 standard MIDI (`MThd`), 7 `FONT`, 4 AdLib instrument banks (6144 bytes, names such as `AcouPiano1`), 5 sound-driver code blobs (`AdLib Driver 01.11`, `SoundBlaster Driver 07.27`, `Speaker Driver 07.27`, ...) |
| 2 | 81 | 27 image groups, ids N000 / N001 / N002 (N = 0–25, 28) |
| 3 | 1784 | Small records. Many contain dialogue text. Layout not yet decoded |

## Image groups (type 2)
- **N002** holds an array of 16-byte image records:
  ```
  char[2] "BM"
  u32 pixel_count      ; = width * height
  u32 offset           ; stored-byte offset of this image's first block inside N001
  u16 flags            ; meaning unknown (0x0000, 0x0200, 0xFF00, ...)
  u16 width
  u16 height
  ```
- **N001** holds the pixels: 8-bit indexed, row-major, with no row padding. Each image starts on a block boundary, and the decoded N001 size equals the sum of `pixel_count` exactly.
- **N000** holds scene data. Its leading u16 table and contents are not yet decoded. It ends in a run of 1024-byte palettes.

## Palettes
A palette is 256 entries of 4 bytes, `R G B 0`, with 8-bit components. The DAC routine scales each component by `(v * brightness) >> 8` to get the 6-bit VGA value, and forces entry 0 to black.
Which palette a picture uses is not yet traced. The inspector's "Auto" mode picks the palette that gives the smoothest neighbouring colours. This is a **heuristic**: it works for the full-screen scenes but is not the game's own logic.

## Verified rendering rules (2026-10-09)

- **Palette to screen:** each palette entry is 8-bit. The VGA DAC takes `v >> 2` (6-bit), and the screen shows `(v6 << 2) | (v6 >> 4)`. The DAC routine (`17ea:ef30`) multiplies by a brightness byte. The value that reproduces the screen is 64, which is the same as `>> 2`. The caller that passes 64 is not yet identified.
- **Verified example:** image 28/10 (160×151) with palette 28/18 matches the original's on-screen portrait at (0, 24) exactly, except 13 pixels in column 159 (rows 75–87). The original draws those pixels differently, and the cause is not yet identified. Earlier wording in this file said the palette choice was not traced. It is now, for this image.
- **Dialogue records (type 3, ids N100–N199):** every one of the 1784 records parses as repeated `[kind][param][text…\0]` entries and ends with `fe 00 00`. In group 28 the narrative entries are kind `0xff`, param `0`. Each entry is one page of dialogue. Kind 0 (params 5 and 12) and kind 1 (params 0–21+) also occur. Their meaning is not yet decoded.
- **Dialogue layout code:** `27c4:7e4e` word-wraps entries and draws each one. Line advance is font height plus a leading global. The dialogue call in `17ea:4562` uses x = 165, width = 155 (`0xa5`, `0x140`).

## Font resources (partially decoded, not usable yet)

- Header: `FONT`, u32 size, name, then u16 values. For GOTHIC120 the values are width 560, height 10, 0, 6.
- Table A: 94 u16 cumulative x offsets starting at byte 24. Index = character − 0x20. Glyph width = difference of adjacent offsets. The space glyph is 6 px.
- Table B: 94 u16 values at byte 212, one per character. The values are 4, 5 or 6 and follow letter shapes: `f`, `i`, `l`, `t` are 4, `r` is 5, x-height letters are 6.
- Glyph data starts at byte 402. The space glyph there is 6 zero bytes, which confirms the offset. The bit layout of the non-blank glyphs is **not** decoded. Tested and rejected: row-major 1 bpp strips at any stride, column-major 2-byte columns, per-glyph byte rows, and word-swapped rows.
