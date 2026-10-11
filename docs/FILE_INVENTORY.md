# File Inventory — Museum Madness (MECC, 1994)

Source: `G:\Games\MUSEUM` (read-only). Copied byte-for-byte to `assets/original/` on 2026-10-09.
Each copied file's SHA-256 was compared with its source after the copy, and all 13 matched (`sha256sum -c`).

The directory contains 13 files and no subdirectories. They match the preliminary list.

## Files

| File | Size (bytes) | Date | SHA-256 | Signature / first bytes |
|---|---:|---|---|---|
| MUSEUM.CFG | 17 | 2025-02-08 | `df5ba4fe3ecfe533b6793066c5246520dde9ed691821edd4e778a9fedf23a04b` | ASCII text: `-sSBL -p220 -i5` CRLF |
| MUSEUM.COM | 686 | 1994-08-03 | `34f2712e238003cb4efc734593ec61c1d67caacfd3245c77c184b83a4f5ba579` | `E9 0C 01` (near JMP), DOS .COM |
| MUSEUM.NDX | 32416 | 1994-08-03 | `a391dca3004cca3a8ceb686bfed41b3c38fd908ec042e866f5980a665cfdab55` | No magic. Table of 16-byte records |
| MUSEUM.RES | 7799716 | 1994-08-03 | `96767efb04bd17f3dda7f0d3d2de4d37114fb2e11714fd50b26db32f26110069` | No magic. Resource blob indexed by NDX |
| MUSEUM.TMP | 550 | 2025-11-08 | `cda050b95c9b4e3d64d60dc91a120c2de23c82edae8feb923b6eb357a8faba3c` | No magic. Mostly little-endian u32 values and zeros |
| MUSEUMA.OVL | 368544 | 1994-08-03 | `a4886f61492b869e6cd0921ff40a86c236af213e8b26745b97dc4068ce54cee0` | `MZ` |
| MUSEUMG.OVL | 187108 | 1994-08-03 | `2be8f93e0d90ac52a557ef7c2788bab6409bd6a4822dcb680e12d32c5480ed7c` | `MZ` |
| MUSEUMN.OVL | 338144 | 1994-08-03 | `8446613f5a6b2a7634088eee66521d380f55f102417d4012c2e4b133a2af59be` | `MZ` |
| MUSEUMS.OVL | 348664 | 1994-08-03 | `cada2dbe8764e4f71b1c65ed036ac85e3ec2dfe29cfcdd8f4173efbcb0339fe9` | `MZ` |
| MUSEUMT.OVL | 308292 | 1994-08-03 | `3cb67ab77e9402d0c2528d730337f6ed08f8ff86396af9be658d5fad4949b0c4` | `MZ` |
| MUSEUMW.OVL | 342078 | 1994-08-03 | `10cb74c7b6a95074d6a52c00e9d3cc54d6c43caa6c78f396dfb4180aefcb3b27` | `MZ` |
| PRODUCT.PF | 350 | 1994-08-09 | `a65ac3e02ac72e8a9d3d27a7bb992ca66495b1f9c1ef5f16c34880f58fb04e66` | `4C 01 00 00`, then fixed-width ASCII fields |
| SETUP.EXE | 33521 | 1994-08-03 | `0196bd00b89e577675970d407d8840abc48497795843d35f93c9aa88244b6134` | `MZ` |

Total: 9,760,086 bytes.

## Verified observations

### MUSEUM.COM — launcher
I read the disassembly by hand. The program:
- shrinks its memory block (INT 21h AH=4Ah), then probes free memory with AH=48h. It aborts with `MUSEUM requires at least 560K free memory.` if fewer than 0x8B80 paragraphs are free.
- switches to video mode 13h (INT 10h AX=0013h, 320×200, 256 colours) before it starts a child, and restores mode 03h on exit.
- builds the filename `MUSEUM?.OVL`. The `?` comes from the table string `GTSANW`. It starts the overlay with INT 21h AX=4B00h (EXEC) and passes a built command tail (fragments `-g`, `-r21`, `-e` are visible). Afterwards it reads the child's exit code with AH=4Dh.
- loops. Exit code 0 selects `G`. For a code *n* from 1 to 254, the next letter is `GTSANW[(n-1)/5 + 1]`. Exit code 0xFF, or any code with bit 7 set, ends the loop.
- also references `MUSEUM.CFG` and `SETUP.EXE`.

The `.OVL` files are therefore separate DOS programs that the launcher chains together. They are not overlays in the linker sense. `G` runs first. What each letter means (for example, a museum wing) is **not yet verified**.

### *.OVL — MZ executables
| File | MZ image size | Bytes after image | Relocations | Header paragraphs |
|---|---:|---:|---:|---:|
| MUSEUMG.OVL | 187108 | 0 | 0 | 32 |
| MUSEUMA.OVL | 165483 | 203061 | 3371 | 864 |
| MUSEUMN.OVL | 176801 | 161343 | 3174 | 800 |
| MUSEUMS.OVL | 178397 | 170267 | 3237 | 832 |
| MUSEUMT.OVL | 160827 | 147465 | 3236 | 832 |
| MUSEUMW.OVL | 162873 | 179205 | 3278 | 832 |

- A, N, S, T and W share a header layout: large relocation tables, and 147–203 KB of data after the MZ load image.
- `MUSEUMG.OVL` and `SETUP.EXE` are **Microsoft EXEPACK** files. They contain the RB signature and the `Packed file is corrupt` stub. Unpacked, `MUSEUMG.OVL` is 214,624 bytes with 3,713 relocations, and `SETUP.EXE` is 42,320 bytes with 338. They were unpacked into a scratch area for analysis only, never into the project.
- All six contain `MUSEUM.TMP`, `ADLIB` and `SPEAKER`. `MUSEUMG.OVL` contains `MS Run-Time Library - Copyright (c) 1992, Microsoft Corp` and MECC copy-protection notices.
- What the trailing data is (Microsoft overlay segments, data, or something else) is **unknown**.

### MUSEUM.NDX — index into MUSEUM.RES (structure verified)
The file is 2026 records of 16 bytes each (32416 = 2026 × 16, no remainder):

```
u16 id      ; 0..32160, every value unique
u16 type    ; bit 15 = compressed flag (see below)
u32 offset  ; into MUSEUM.RES
u32 stored_size
u32 unpacked_size
```

The script checked this against the whole of MUSEUM.RES:
- All 2026 records are contiguous: each offset equals the previous offset plus the previous stored size, starting at 0.
- The last record ends at exactly 7799716, the size of MUSEUM.RES.

| type | count | storage |
|---|---:|---|
| 0x0001 | 12 | raw (stored == unpacked) |
| 0x0003 | 1000 | raw. Samples are NUL-separated English text strings (game dialogue) |
| 0x8001 | 149 | packed |
| 0x8002 | 81 | packed |
| 0x8003 | 784 | packed |

Packed chunks (bit 15 set) are made of blocks of at most 32 KB unpacked, each with an 8-byte `(unpacked, packed)` header. The 31 type-0x8002 chunks that didn't match a single header turned out to be multi-block chunks.

The compression algorithm and the content types were recovered from the game code and verified against all 2026 resources. See [RES_FORMAT.md](RES_FORMAT.md).

### MUSEUM.CFG
The file holds 17 bytes of ASCII. `-sSBL -p220 -i5` is consistent with Sound Blaster at port 220h, IRQ 5. SETUP.EXE offers `Internal speaker`, `Sound Blaster` and `Sound Blaster Pro`. The file is dated 2025, so it was rewritten by a local SETUP run, not shipped as-is.

### MUSEUM.TMP
The file is 550 bytes, mostly small little-endian u32 values. It is dated 2025, and every overlay references `MUSEUM.TMP` / `museum.tmp`. It is probably runtime state shared between the chained overlays, or a save file. Its layout is **unknown**.

### PRODUCT.PF
This is a MECC product/licence record with fixed-width NUL-padded ASCII fields: `Copyright 1994, MECC`, the MECC address and phone number, `icensed to Chaos Elementary School` (first byte overwritten), `Museum Madness`, and ` Quandary`. The binary prefix fields are **unknown**.

### SETUP.EXE
MZ executable with no relocations and no trailing data. It is the sound-device configuration tool and writes MUSEUM.CFG (inferred from strings).

## Still unknown
- What each overlay letter (G/T/S/A/N/W) means, and the full exit-code protocol.
- The format of the data after the MZ image in A/N/S/T/W.
- The record layout of type-3 resources (dialogue text plus unknown fields), `FONT`, and the N000 scene data.
- Which palette each image uses, and the meaning of the image `flags` field.
- The record layout of MUSEUM.TMP, and the binary fields in PRODUCT.PF.
