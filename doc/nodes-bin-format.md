# nodes.bin File Format

## Overview

`nodes.bin` is the primary binary database file for OSM node skeleton data in Overpass API. It is a block-structured binary file managed by the **Block Backend** system, paired with a companion index file `nodes.bin.idx`. Together they provide efficient spatial lookup of OSM node IDs and geographic coordinates.

The file stores `Node_Skeleton` records — the minimal node representation containing only an OSM node ID and packed geographic coordinates — grouped into fixed-size, optionally-compressed blocks, spatially indexed by a 32-bit quadtile key (`Uint32_Index`).

**Associated files:**

| File | Purpose |
|------|---------|
| `{db_dir}/nodes.bin` | Block data — the node skeleton records |
| `{db_dir}/nodes.bin.idx` | Block index — maps spatial keys to block positions |
| `{db_dir}/nodes.bin.map` | Random-access ID→index map (separate format) |
| `{db_dir}/nodes.bin.shadow` | Shadow copy used during write transactions |

---

## File Properties

Configured in `src/overpass_api/core/settings.cc` at line 125:

```cpp
NODES(new OSM_File_Properties< Uint32_Index >("nodes", 128*1024, 256*1024))
```

| Property | Value | Notes |
|----------|-------|-------|
| File name trunk | `nodes` | → `nodes.bin`, `nodes.bin.idx`, etc. |
| Data suffix | `.bin` | Defined in `Basic_Settings` (`settings.cc:96`) |
| Index suffix | `.idx` | Defined in `Basic_Settings` (`settings.cc:97`) |
| ID/map suffix | `.map` | Defined in `Basic_Settings` (`settings.cc:98`) |
| Shadow suffix | `.shadow` | Defined in `Basic_Settings` (`settings.cc:99`) |
| Block size | 128 KiB (131,072 bytes) | `block_size` param ÷ 8: `128*1024/8 = 16,384` uint64 words |
| Map block size | 256 KiB | For the `.map` random-access index |
| Compression factor | 8× | Decompressed block = 8 × compressed block |
| Compression method | LZ4 (if available) or ZLIB | `settings.cc:108–111` |
| Index type | `Uint32_Index` (4 bytes) | Spatial quadtile hash |

> **Note on block size units:** `OSM_File_Properties::get_block_size()` returns `block_size/8`
> (`settings.cc:51`). The block size stored in the index header is an exponent (log₂), so
> 16,384 uint64 words × 8 bytes = 131,072 bytes = 128 KiB per block.

---

## Coordinate Encoding

Each node's latitude/longitude is encoded as two 32-bit unsigned integers using a **quadtile / Z-order (Morton code)** scheme. The encoding is defined in `src/overpass_api/core/index_computations.h`.

### Integer latitude/longitude

Before bit-interleaving, floating-point lat/lon are converted to unsigned 32-bit integers:

- **ilat** = `(lat + 90.0) / 180.0 × 2^32` — latitude in \[0, 2³²)
- **ilon** = `(lon + 180.0) / 360.0 × 2^32` — longitude in \[0, 2³²)

### `ll_upper` — spatial index (upper 32 bits of quadtile)

`src/overpass_api/core/index_computations.h:59–82`:

```cpp
inline uint32 ll_upper(uint32 ilat, uint32 ilon)
{
  // Spread ilat bits into even positions
  ilat &= 0xffff0000;
  ilat |= (ilat>>8);  ilat &= 0xff00ff00;
  ilat |= (ilat>>4);  ilat &= 0xf0f0f0f0;
  ilat |= (ilat>>2);  ilat &= 0xcccccccc;
  ilat |= (ilat>>1);  ilat &= 0xaaaaaaaa;

  // Spread ilon bits into odd positions
  ilon &= 0xffff0000;
  ilon |= (ilon>>8);  ilon &= 0xff00ff00;
  ilon |= (ilon>>4);  ilon &= 0xf0f0f0f0;
  ilon |= (ilon>>2);  ilon &= 0xcccccccc;
  ilon |= (ilon>>1);  ilon &= 0xaaaaaaaa;

  return ilat | (ilon>>1);
}
```

The result interleaves the top 16 bits of `ilat` (into even bit positions) and the top 16 bits of `ilon` (into odd bit positions), producing a 32-bit Morton code. This is the **block index key** (`Uint32_Index`) stored in both the `.idx` file and the data block header.

When constructing a `Node` from float coordinates, a XOR with `0x40000000` is applied to shift the longitude origin:

`src/overpass_api/core/index_computations.h:84–87`:
```cpp
inline uint32 ll_upper_(uint32 ilat, int32 ilon)
{
  return (ll_upper(ilat, ilon) ^ 0x40000000);
}
```

### `ll_lower` — lower 32 bits of quadtile

`ll_lower` stores the lower 32 bits of the full 64-bit Morton code — the bits of `ilat` and `ilon` below the top 16 bits, interleaved. Combined, `ll_upper || ll_lower` forms a full 64-bit quadtile coordinate:

```cpp
struct Quad_Coord {         // src/overpass_api/core/basic_types.h:227–239
  uint32 ll_upper;          // top 32 bits of Morton code = spatial index
  uint32 ll_lower;          // bottom 32 bits of Morton code = stored in Node_Skeleton
};
```

To recover lat/lon from a `(ll_upper, ll_lower)` pair, use `ilat(ll_upper, ll_lower)` and `ilon(ll_upper, ll_lower)` from `src/overpass_api/core/index_computations.h`.

---

## Node_Skeleton Record Format

Each OSM node is stored as a `Node_Skeleton` record. This is the smallest serializable unit in `nodes.bin`.

**Source:** `src/overpass_api/core/type_node.h:87–139`

```cpp
struct Node_Skeleton
{
  typedef Node::Id_Type Id_Type;   // = Uint64

  Node::Id_Type id;   // 8 bytes: OSM node ID
  uint32 ll_lower;    // 4 bytes: lower Morton code bits

  uint32 size_of() const { return 12; }
  static uint32 size_of(void* data) { return 12; }

  void to_data(void* data) const
  {
    *(Id_Type*)data = id.val();
    *(uint32*)((uint8*)data+8) = ll_lower;
  }

  Node_Skeleton(void* data)
    : id(*(Id_Type*)data), ll_lower(*(uint32*)((uint8*)data+8)) {}
};
```

### Record layout (12 bytes, little-endian)

```
Offset  Size  Type    Field        Description
------  ----  ------  -----------  -----------------------------------------
0       8     uint64  id           OSM node ID (little-endian)
8       4     uint32  ll_lower     Lower 32 bits of Morton-code coordinate
```

All values are stored in **native (little-endian on x86) byte order** via direct pointer casts.

### ID type: `Uint64`

`src/overpass_api/core/basic_types.h:166–224`:

```cpp
struct Uint64 {
  uint32 size_of() const { return 8; }
  void to_data(void* data) const { *(uint64*)data = value; }
  Uint64(void* data) : value(*(uint64*)data) {}
};
```

---

## Index Key: `Uint32_Index`

Each block in `nodes.bin` is indexed by a `Uint32_Index`, which holds `ll_upper` — the upper 32-bit Morton code hash for that group of nodes.

**Source:** `src/overpass_api/core/basic_types.h:38–99`

```cpp
struct Uint32_Index {
  uint32 value;

  uint32 size_of() const { return 4; }
  static constexpr uint32 const_size() { return 4; }
  void to_data(void* data) const { *(uint32*)data = value; }
  Uint32_Index(void* data) : value(*(uint32*)data) {}
};
```

Nodes with the same `ll_upper` (i.e., in the same Morton-code tile) are grouped together into the same block or set of adjacent blocks.

---

## nodes.bin.idx — Index File Format

The companion index file `nodes.bin.idx` maps spatial index values to block positions within `nodes.bin`. It consists of an 8-byte header followed by a sequence of fixed-size index entries.

### Header (8 bytes)

**Source:** `src/template_db/file_blocks_index.h:454–488` (parsing) and `src/template_db/file_blocks_index.h:641–644` (writing)

```
Offset  Size  Type    Field                   Description
------  ----  ------  ----------------------  ----------------------------------
0       4     int32   file_format_version     Must be in [7512, 7600]
4       1     uint8   block_size_log2         block_size = 1 << this value
5       1     uint8   compression_factor_log2 compression_factor = 1 << this value
6       2     uint16  compression_method      0=none, 1=ZLIB, 2=LZ4
```

The current file format version is `7600` (`FILE_FORMAT_VERSION`, `src/template_db/file_blocks_index.h:133`).

Compression method constants (`src/template_db/types.h:87–89`):

```cpp
static const int NO_COMPRESSION   = 0;
static const int ZLIB_COMPRESSION = 1;
static const int LZ4_COMPRESSION  = 2;
```

### Index Entry (16 bytes each)

Each entry describes one block (or contiguous multi-block segment) in `nodes.bin`.

**Source:** `src/template_db/file_blocks_index.h:37–51` (`File_Block_Index_Entry`) and `src/template_db/file_blocks_index.h:182–183` (field accessors)

```
Offset  Size  Type      Field    Description
------  ----  --------  -------  -------------------------------------------
0       4     uint32    pos      Block position (index into file, in blocks)
4       4     uint32    size     Number of consecutive blocks this entry spans
8       4     uint32    (pad)    Reserved / zero (written as 0)
12      4     uint32    index    Uint32_Index value (ll_upper / Morton key)
```

Written by `src/template_db/file_blocks_index.h:646–657`:
```cpp
*(uint32*)(buf.ptr+pos) = it->pos;   pos += 4;
*(uint32*)(buf.ptr+pos) = it->size;  pos += 4;
*(uint32*)(buf.ptr+pos) = 0;         pos += 4;   // padding
it->index.to_data(buf.ptr+pos);      pos += it->index.size_of();
```

The iterator advances by `12 + Index::size_of()` bytes per entry (`src/template_db/file_blocks_index.h:77–81` and `161–162`).

**Byte offset of a block in `nodes.bin`:** `entry.pos × block_size`

---

## nodes.bin — Data Block Format

`nodes.bin` is a flat sequence of fixed-size blocks. The block size is 128 KiB (per the index header). Each block (or multi-block segment for large payloads) holds one or more **index groups**, where each group contains all `Node_Skeleton` records sharing the same `ll_upper` index value.

### Compressed vs. Uncompressed blocks

When the compression method is ZLIB or LZ4, each physical block in the file is the compressed form. The decompressed size is `block_size × compression_factor` (up to 1 MiB for nodes). The decompressed buffer is what the layout below describes.

Reading logic: `src/template_db/file_blocks.h:821–865`

### Block payload layout

After decompression, the block buffer contains:

```
Offset  Size  Type    Field               Description
------  ----  ------  ------------------  -----------------------------------------
0       4     uint32  total_payload_size  Byte count of used payload in this buffer
```

Followed by a sequence of **index groups** packed end-to-end:

```
[idx_group_1][idx_group_2]...[idx_group_N]
```

### Index group layout

Each index group begins at an offset tracked by `idx_block_offset` in the iterator:

```
Offset (within group)  Size  Type      Field             Description
---------------------  ----  --------  ----------------  ----------------------------
0                      4     uint32    next_idx_offset   Byte offset of the NEXT index
                                                         group from start of buffer
                                                         (or == total_payload_size for
                                                         the last group)
4                      4     uint32    ll_upper          Uint32_Index value (Morton key)
8                      N×12  records   Node_Skeleton[]   All nodes for this ll_upper,
                                                         each 12 bytes
```

The `next_idx_offset` field is both a forward-link and a size: the `Node_Skeleton` records run from `idx_block_offset + 4 + 4` to `next_idx_offset - 1` (exclusive).

**Source:** `src/template_db/block_backend.h:127–138`
```cpp
uint32 next_idx_block_offset() const {
  return *(uint32*)(((uint8*)buffer.ptr) + idx_block_offset);
}
uint8* idx_ptr() const {
  return ((uint8*)buffer.ptr) + idx_block_offset + 4;
}
uint32 total_payload_size() const {
  return *(uint32*)buffer.ptr;
}
```

Object iteration starts at `src/template_db/block_backend.h:157`:
```cpp
obj_offset = idx_block_offset + 4 + Index::size_of(idx_ptr());
//         = idx_block_offset + 4 + 4   (for Uint32_Index)
//         = idx_block_offset + 8
```

### Visual block layout

```
┌─────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                      │
│                                                             │
│  ── Index Group 1 ──────────────────────────────────────    │
│  [4..7]   next_idx_offset_1   (uint32, offset of group 2)   │
│  [8..11]  ll_upper_1          (uint32, Uint32_Index)         │
│  [12..23] Node_Skeleton #1    (12 bytes)                    │
│  [24..35] Node_Skeleton #2    (12 bytes)                    │
│  ...                                                        │
│                                                             │
│  ── Index Group 2 (at offset next_idx_offset_1) ────────    │
│  [N+0..3] next_idx_offset_2   (uint32, offset of group 3)   │
│  [N+4..7] ll_upper_2          (uint32, Uint32_Index)         │
│  [N+8..]  Node_Skeleton #M    (12 bytes each)               │
│  ...                                                        │
│                                                             │
│  [total_payload_size .. block_size-1]  (zero padding)       │
└─────────────────────────────────────────────────────────────┘
```

### Multi-block segments

If a single index group's payload exceeds `block_size` (i.e., many nodes share the same `ll_upper`), it is written across multiple consecutive blocks. The index entry for such a segment has `size > 1`. The `next_idx_offset` in the first physical block is set to `block_size` (to signal continuation), and subsequent blocks are read sequentially. The buffer is enlarged dynamically to accommodate. See `src/template_db/block_backend.h:250–262`.

When writing an oversized object: `src/template_db/block_backend_write.h:44–65`:
```cpp
if (idx_size + obj_size + 8 > block_size)
{
  uint buf_scale = (idx_size + obj_size + 7)/block_size + 1;
  // ... writes buf_scale blocks, all indexed with the same idx
}
```

---

## nodes.bin.map — Random-Access Node ID Map

A companion `.map` file (`nodes.bin.map`) provides O(1) lookup from OSM node ID to `ll_upper` index. This is a separate random-access format not described in detail here; it uses `map_block_size = 256 KiB` (`settings.cc:125`).

---

## Attic (Historical) Node Data

Historical (deleted/modified) node skeletons are stored in `nodes.bin` under the `attic_settings()` path, using the `Attic<Node_Skeleton>` wrapper.

**Source:** `src/overpass_api/core/basic_types.h:242–284`

```cpp
template< typename Element_Skeleton >
struct Attic : public Element_Skeleton {
  uint64 timestamp;

  uint32 size_of() const { return Element_Skeleton::size_of() + 5; }  // 12 + 5 = 17 bytes

  void to_data(void* data) const {
    Element_Skeleton::to_data(data);
    void* pos = (uint8*)data + Element_Skeleton::size_of();
    *(uint32*)(pos)     = (timestamp & 0xffffffffull);       // bytes 12–15
    *(uint8*)((uint8*)pos+4) = ((timestamp>>32) & 0xff);     // byte 16
  }
};
```

`Attic<Node_Skeleton>` records are **17 bytes** each:

```
Offset  Size  Type    Field      Description
------  ----  ------  ---------  -----------------------------------------
0       8     uint64  id         OSM node ID
8       4     uint32  ll_lower   Lower Morton code bits
12      4     uint32  timestamp  Unix timestamp, lower 32 bits
16      1     uint8   timestamp  Unix timestamp, bits 32–39 (5-byte total)
```

The timestamp is stored as a 40-bit (5-byte) little-endian value, covering dates up to year ~36812.

---

## Write Path Summary

When the database is updated, `Block_Backend::update()` (`src/template_db/block_backend.h`) calls `flush_if_necessary_and_write_obj()` in `src/template_db/block_backend_write.h:28–73`:

1. Records are accumulated in a write buffer, sorted by `Uint32_Index`.
2. When the buffer is full (`insert_ptr - start_ptr + obj_size > block_size`), the current buffer is flushed as one block via `file_blocks.insert_block()`.
3. The first 4 bytes of a flushed block are set to `bytes_written` (the payload size).
4. Each new `Uint32_Index` group is preceded by its `next_idx_offset` (4 bytes) and the index value (4 bytes), then the `Node_Skeleton` records follow immediately.

---

## Source File Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| `Node_Skeleton` struct & serialization | `src/overpass_api/core/type_node.h` | 87–139 |
| `Node` struct (with float coords) | `src/overpass_api/core/type_node.h` | 29–58 |
| `Uint32_Index` | `src/overpass_api/core/basic_types.h` | 38–99 |
| `Uint64` (node ID type) | `src/overpass_api/core/basic_types.h` | 166–224 |
| `Quad_Coord` | `src/overpass_api/core/basic_types.h` | 227–239 |
| `Attic<Node_Skeleton>` | `src/overpass_api/core/basic_types.h` | 242–284 |
| `ll_upper()` Morton encoding | `src/overpass_api/core/index_computations.h` | 59–87 |
| `ilat()` / `ilon()` Morton decoding | `src/overpass_api/core/index_computations.h` | 89–115 |
| File properties (block size, compression) | `src/overpass_api/core/settings.cc` | 37–89, 125 |
| `OSM_File_Properties` template | `src/overpass_api/core/settings.cc` | 37–89 |
| `.idx` header write | `src/template_db/file_blocks_index.h` | 626–658 |
| `.idx` header read | `src/template_db/file_blocks_index.h` | 453–488 |
| `.idx` entry layout / iterator | `src/template_db/file_blocks_index.h` | 37–51, 138–189 |
| `FILE_FORMAT_VERSION` constant | `src/template_db/file_blocks_index.h` | 133 |
| Block read (compressed/uncompressed) | `src/template_db/file_blocks.h` | 813–877 |
| Block payload parsing (iterator) | `src/template_db/block_backend.h` | 100–166, 208–263 |
| Block write / flush logic | `src/template_db/block_backend_write.h` | 27–73 |
| Compression constants | `src/template_db/types.h` | 86–90 |
| `Block_Backend` API | `src/template_db/block_backend.h` | 499–540 |
