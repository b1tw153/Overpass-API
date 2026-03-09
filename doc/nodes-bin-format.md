# OSM Binary File Formats: nodes.bin, ways.bin, relations.bin

## Overview

Overpass API stores OSM element skeleton data in three paired binary files:

| File pair | OSM type | Record type | Index type |
|-----------|----------|-------------|------------|
| `nodes.bin` / `nodes.bin.idx` | Nodes | `Node_Skeleton` (fixed 12 B) | `Uint32_Index` |
| `ways.bin` / `ways.bin.idx` | Ways | `Way_Skeleton` / `Way_Delta` (variable) | `Uint31_Index` |
| `relations.bin` / `relations.bin.idx` | Relations | `Relation_Skeleton` / `Relation_Delta` (variable) | `Uint31_Index` |

All three use the same **Block Backend** container format — an identical outer structure of fixed-size, optionally-compressed blocks with a companion index file. The differences lie in the index key type, block size, and the record layout stored inside the blocks.

**Associated files for each element type:**

| File | Purpose |
|------|---------|
| `{db_dir}/{type}.bin` | Block data — skeleton records |
| `{db_dir}/{type}.bin.idx` | Block index — maps spatial keys to block positions |
| `{db_dir}/{type}.bin.map` | Random-access ID→index map (separate format) |
| `{db_dir}/{type}.bin.shadow` | Shadow copy used during write transactions |

Attic (historical) data lives under a parallel set of files: `nodes_attic.bin`, `ways_attic.bin`, `relations_attic.bin`, etc.

---

## File Properties

Configured in `src/overpass_api/core/settings.cc`:

| Property | nodes.bin | ways.bin | relations.bin |
|----------|-----------|----------|---------------|
| Settings line | line 125 | line 137 | line 149 |
| `OSM_File_Properties<>` | `Uint32_Index` | `Uint31_Index` | `Uint31_Index` |
| Physical block size (on disk) | **16 KiB** | **16 KiB** | **64 KiB** |
| Decompressed block size | 128 KiB | 128 KiB | **512 KiB** |
| Compression factor | 8× | 8× | 8× |
| Map block size | 256 KiB | 256 KiB | 256 KiB |
| Compression method | LZ4 / ZLIB | LZ4 / ZLIB | LZ4 / ZLIB |

```cpp
// src/overpass_api/core/settings.cc:125
NODES(new OSM_File_Properties< Uint32_Index >("nodes", 128*1024, 256*1024))
// src/overpass_api/core/settings.cc:137
WAYS(new OSM_File_Properties< Uint31_Index >("ways", 128*1024, 256*1024))
// src/overpass_api/core/settings.cc:149
RELATIONS(new OSM_File_Properties< Uint31_Index >("relations", 512*1024, 256*1024))
```

The constructor parameter (`128*1024` for nodes/ways, `512*1024` for relations) is an internal unit equal to `physical_block_bytes × 8`. `get_block_size()` divides by 8 (`settings.cc:51`), yielding the physical block size in bytes: `128*1024/8 = 16,384` bytes for nodes/ways, `512*1024/8 = 65,536` bytes for relations.

**Two distinct block sizes matter for implementation:**
- **Physical block size**: the unit used for file seeking and the `pos`/`size` fields in `.idx` entries. Equals `1 << block_size_log2` bytes from the `.idx` header.
- **Decompressed block size**: the size of the buffer after decompression, where the index-group payload layout lives. Equals `physical_block_size × compression_factor` = `physical_block_size × (1 << compression_factor_log2)`.

For LZ4/ZLIB, a single compressed physical block (16 KiB) decompresses to one logical block (128 KiB). For `NO_COMPRESSION`, each physical block is both the stored and the logical size (16 KiB), but `entry.size > 1` is used for large payloads (all `entry.size × 16 KiB` are read in one call).

---

## Index Key Types

### `Uint32_Index` — used by nodes.bin

**Source:** `src/overpass_api/core/basic_types.h:38–99`

A plain 32-bit spatial quadtile hash (`ll_upper`). All 32 bits are significant. Nodes with the same `ll_upper` value are grouped into the same block.

```cpp
struct Uint32_Index {
  uint32 value;
  uint32 size_of() const { return 4; }
  void to_data(void* data) const { *(uint32*)data = value; }
  Uint32_Index(void* data) : value(*(uint32*)data) {}
};
```

### `Uint31_Index` — used by ways.bin and relations.bin

**Source:** `src/overpass_api/core/basic_types.h:120–163`

Inherits from `Uint32_Index` but reserves **bit 31 (MSB = `0x80000000`)** as a special flag. When set, the index value is a "multi-tile geometry" index rather than a normal quadtile, and comparison ignores the MSB:

```cpp
struct Uint31_Index : Uint32_Index {
  bool less(void* rhs) const {
    if ((value & 0x7fffffff) != (*(uint32*)rhs & 0x7fffffff))
      return (value & 0x7fffffff) < (*(uint32*)rhs & 0x7fffffff);
    return value < *(uint32*)rhs;
  }
};
```

The MSB flag is used when a way or relation spans multiple quadtiles — its index encodes the *bounding box* of that span using lower bits as a resolution indicator (`type_way.h:61–64`):

```cpp
static bool indicates_geometry(Uint31_Index index) {
  return ((index.val() & 0x80000000) != 0 && ((index.val() & 0x1) == 0));
}
```

**Key implication for readers:** each way/relation is stored under **exactly one** computed index key — either a normal tile index (MSB clear) or a geometry index (MSB set, bit 0 clear). There is no duplication. A reader must query both normal-tile and geometry-tile index groups to find all ways/relations in an area.

- When `indicates_geometry` is **false**: the way/relation fits in a single quadtile. The record's `geometry` / `node_idxs` / `way_idxs` arrays are **empty** (cleared at write time, `way_updater.cc:98–99`, `relation_updater.cc:559–562`).
- When `indicates_geometry` is **true**: the way/relation spans multiple tiles. The geometry/index arrays are **populated** (see Way_Skeleton and Relation_Skeleton record sections).

The index wire size is still 4 bytes.

---

## Coordinate Encoding

Coordinates are shared across all three element types. Each node's (and each way node's) lat/lon is encoded as two 32-bit unsigned integers using a **quadtile / Z-order (Morton code)** scheme.

**Source:** `src/overpass_api/core/index_computations.h`

### Integer latitude/longitude

- **ilat** = `(lat + 90.0) / 180.0 × 2^32`
- **ilon** = `(lon + 180.0) / 360.0 × 2^32`

### `ll_upper` — upper 32 bits of Morton code

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

A XOR with `0x40000000` is applied when constructing from float coordinates to shift the longitude origin (`index_computations.h:84–87`).

### `ll_lower` — lower 32 bits of Morton code

`ll_lower` holds the lower 32 bits of the interleaved coordinate, providing sub-tile precision. Together, `ll_upper || ll_lower` forms a full 64-bit quadtile:

```cpp
struct Quad_Coord {         // src/overpass_api/core/basic_types.h:227–239
  uint32 ll_upper;          // top 32 bits of Morton code = spatial index key
  uint32 ll_lower;          // bottom 32 bits of Morton code
};
```

To recover lat/lon: use `ilat(ll_upper, ll_lower)` and `ilon(ll_upper, ll_lower)` (`index_computations.h:89–115`).

---

## Record Formats

### Node_Skeleton — fixed 12 bytes

**Source:** `src/overpass_api/core/type_node.h:87–139`

Node ID type is `Uint64` (8 bytes) because OSM node IDs exceed 2³². All values little-endian.

```
Offset  Size  Type    Field      Description
------  ----  ------  ---------  ----------------------------------------
0       8     uint64  id         OSM node ID
8       4     uint32  ll_lower   Lower 32 bits of Morton-code coordinate
```

```cpp
uint32 size_of() const { return 12; }

void to_data(void* data) const {
  *(Id_Type*)data = id.val();
  *(uint32*)((uint8*)data+8) = ll_lower;
}

Node_Skeleton(void* data)
  : id(*(Id_Type*)data), ll_lower(*(uint32*)((uint8*)data+8)) {}
```

---

### Way_Skeleton — variable length

**Source:** `src/overpass_api/core/type_way.h:87–156`

Way ID type is `Uint32_Index` (4 bytes) — way IDs fit in 32 bits. The record embeds the full ordered list of member node IDs and, for multi-tile ways only, a `Quad_Coord` geometry entry for every node.

**`geometry_count` is nonzero if and only if `indicates_geometry(index)` is true** — i.e., the way's nodes span more than one quadtile. When the way fits in a single tile, `geometry_count = 0` and the `geometry[]` array is absent. (`way_updater.cc:96–99`)

Size formula: `8 + 8 × nds_count + 8 × geometry_count` bytes. All values little-endian.

```
Offset         Size      Type          Field           Description
------         ----      --------      --------------  ----------------------------------------
0              4         uint32        id              OSM way ID
4              2         uint16        nds_count       Number of member node IDs (N)
6              2         uint16        geometry_count  Number of Quad_Coord entries (M)
8              8×N       uint64[]      nds             Member node IDs in way order
8+8N           8×M       Quad_Coord[]  geometry        Per-node coords; present iff M > 0
                                                       (M == N when present)
```

Each `Quad_Coord` in the geometry array is 8 bytes: 4 bytes `ll_upper` + 4 bytes `ll_lower`.

```cpp
// src/overpass_api/core/type_way.h:117–125
uint32 size_of() const {
  return 8 + 8*nds.size() + 8*geometry.size();
}
static uint32 size_of(void* data) {
  return (8 + 8 * *((uint16*)data + 2) + 8 * *((uint16*)data + 3));
}
```

Deserialization (`type_way.h:100–109`):
```cpp
Way_Skeleton(void* data) : id(*(Id_Type*)data)
{
  nds.reserve(*((uint16*)data + 2));
  for (int i = 0; i < *((uint16*)data + 2); ++i)
    nds.push_back(*(uint64*)((uint16*)data + 4 + 4*i));
  uint16* start_ptr = (uint16*)data + 4 + 4*nds.size();
  geometry.reserve(*((uint16*)data + 3));
  for (int i = 0; i < *((uint16*)data + 3); ++i)
    geometry.push_back(Quad_Coord(*(uint32*)(start_ptr + 4*i),
                                  *(uint32*)(start_ptr + 4*i + 2)));
}
```

---

### Relation_Skeleton — variable length

**Source:** `src/overpass_api/core/type_relation.h:104–189`

Relation ID type is `Uint32_Index` (4 bytes). The record embeds all member entries (each carrying a ref ID, member type, and role ID) plus index arrays listing which quadtiles contain member nodes and ways.

**`node_idxs_count` and `way_idxs_count` are nonzero if and only if `indicates_geometry(index)` is true** — i.e., the relation's members span multiple tiles. When the relation fits in a single tile, both arrays are empty. (`relation_updater.cc:553–562`)

Size formula: `16 + 12 × members_count + 4 × node_idxs_count + 4 × way_idxs_count` bytes. All values little-endian.

```
Offset           Size    Type           Field            Description
------           ----    ----           -----            -----------
0                4       uint32         id               OSM relation ID
4                4       uint32         members_count    Number of member entries
8                4       uint32         node_idxs_count  Number of node-tile index entries
12               4       uint32         way_idxs_count   Number of way-tile index entries
16               12×M    Relation_Entry[]  members       Member array (M = members_count)
16+12M           4×N     uint32[]       node_idxs        Uint31_Index values for node tiles
16+12M+4N        4×P     uint32[]       way_idxs         Uint31_Index values for way tiles
```

Each `Relation_Entry` is 12 bytes:

```
Offset (within entry)  Size  Type    Field  Description
---------------------  ----  ------  -----  ------------------------------------
0                      8     uint64  ref    Referenced element ID
8                      3     uint24  role   Role string ID (lower 24 bits of uint32)
11                     1     uint8   type   1=NODE, 2=WAY, 3=RELATION
```

```cpp
// src/overpass_api/core/type_relation.h:160–178
void to_data(void* data) const {
  *(Id_Type*)data = id.val();
  *((uint32*)data + 1) = members.size();
  *((uint32*)data + 2) = node_idxs.size();
  *((uint32*)data + 3) = way_idxs.size();
  for (uint i = 0; i < members.size(); ++i) {
    *(uint64*)((uint32*)data + 4 + 3*i) = members[i].ref.val();
    *((uint32*)data + 6 + 3*i) = members[i].role & 0xffffff;
    *((uint8*)data + 27 + 12*i) = members[i].type;
  }
  // node_idxs and way_idxs follow as uint32 arrays
}
```

```cpp
// src/overpass_api/core/type_relation.h:150–153
static uint32 size_of(void* data) {
  return 16 + 12 * *((uint32*)data + 1)
            +  4 * *((uint32*)data + 2)
            +  4 * *((uint32*)data + 3);
}
```

`Relation_Entry` type constants (`type_relation.h:41–43`):
```cpp
const static uint32 NODE     = 1;
const static uint32 WAY      = 2;
const static uint32 RELATION = 3;
```

---

## Attic (Historical) Record Formats

Historical versions of deleted/modified elements are stored in `*_attic.bin` files. For nodes the `Attic<>` wrapper simply appends a timestamp; for ways and relations a full **delta encoding** is used instead.

### Attic<Node_Skeleton> — 17 bytes fixed

**Source:** `src/overpass_api/core/basic_types.h:242–284`

```
Offset  Size  Type    Field      Description
------  ----  ------  ---------  -----------------------------------------
0       8     uint64  id         OSM node ID
8       4     uint32  ll_lower   Lower Morton code bits
12      4     uint32  timestamp  Unix timestamp, lower 32 bits
16      1     uint8   timestamp  Unix timestamp, bits 32–39 (5-byte total)
```

The timestamp is a 40-bit little-endian value covering dates to year ~36812.

```cpp
uint32 size_of() const { return Element_Skeleton::size_of() + 5; }  // 12 + 5 = 17

void to_data(void* data) const {
  Element_Skeleton::to_data(data);
  void* pos = (uint8*)data + Element_Skeleton::size_of();
  *(uint32*)(pos)          = (timestamp & 0xffffffffull);   // bytes 12–15
  *(uint8*)((uint8*)pos+4) = ((timestamp>>32) & 0xff);      // byte 16
}
```

### Way_Delta — variable length (attic ways)

**Source:** `src/overpass_api/core/type_way.h:159–409`

The attic way file stores `Way_Delta` records rather than full `Way_Skeleton` copies. A delta encodes changes relative to the previous version. There are two forms, distinguished by `word[1]`:

**Full form** (`word[1] == 0xffffffff`) — stores the complete snapshot:

```
Offset     Size    Field                Description
------     ----    -----                -----------
0          4       id                   OSM way ID
4          4       0xffffffff           Full-record marker
8          4       nds_count            Number of node IDs
12         4       geometry_count       Number of geometry entries
16         8×N     nds[]                Node IDs (uint64 each)
16+8N      8×M     geometry[]           Quad_Coord pairs (M = geometry_count)
```

Total size: `16 + 8×nds_count + 8×geometry_count`

**Incremental form** (`word[1] != 0xffffffff`) — stores only the diff:

```
Offset              Size      Field                   Description
------              ----      -----                   -----------
0                   4         id                      OSM way ID
4                   4         nds_removed_count
8                   4         nds_added_count
12                  4         geometry_removed_count
16                  4         geometry_added_count
20                  4×R1      nds_removed[]           Removed node indices (uint32 each)
20+4R1              12×A1     nds_added[]             (index:uint32, node_id:uint64) each
20+4R1+12A1         4×R2      geometry_removed[]      Removed geometry indices (uint32)
20+4R1+12A1+4R2     12×A2     geometry_added[]        (index:uint32, Quad_Coord) each
```

Total size: `20 + 4×R1 + 12×A1 + 4×R2 + 12×A2`

```cpp
// src/overpass_api/core/type_way.h:322–338
static uint32 size_of(void* data) {
  if (*((uint32*)data + 1) == 0xffffffff)
    return 16 + 8 * *((uint32*)data + 2) + 8 * *((uint32*)data + 3);
  else
    return 20 + 4 * *((uint32*)data + 1) + 12 * *((uint32*)data + 2)
              +  4 * *((uint32*)data + 3) + 12 * *((uint32*)data + 4);
}
```

The code switches to a full record when the incremental form would be larger than half the full record size (`type_way.h:246–253`).

### Relation_Delta — variable length (attic relations)

**Source:** `src/overpass_api/core/type_relation.h:192–474`

Same two-form pattern as `Way_Delta` but for relation members and member index arrays.

**Full form** (`word[1] == 0xffffffff`):

```
Offset          Size    Field                   Description
------          ----    -----                   -----------
0               4       id                      OSM relation ID
4               4       0xffffffff              Full-record marker
8               4       members_count
12              4       node_idxs_count
16              4       way_idxs_count
20              12×M    members_added[]         Full member list (Relation_Entry each)
20+12M          4×N     node_idxs_added[]       Node tile indices (uint32 each)
20+12M+4N       4×P     way_idxs_added[]        Way tile indices (uint32 each)
```

Total size: `20 + 12×M + 4×N + 4×P`

**Incremental form** (`word[1] != 0xffffffff`):

```
Offset                   Size    Field
------                   ----    -----
0                        4       id
4                        4       members_removed_count     (R1)
8                        4       members_added_count       (A1)
12                       4       node_idxs_removed_count   (R2)
16                       4       node_idxs_added_count     (A2)
20                       4       way_idxs_removed_count    (R3)
24                       4       way_idxs_added_count      (A3)
28                       4×R1    members_removed[]         Removed member indices
28+4R1                   16×A1   members_added[]           (index:4, ref:8, role:3, type:1)
28+4R1+16A1              4×R2    node_idxs_removed[]
28+4R1+16A1+4R2          8×A2    node_idxs_added[]         (index:4, idx:4)
28+4R1+16A1+4R2+8A2      4×R3    way_idxs_removed[]
28+4R1+16A1+4R2+8A2+4R3  8×A3    way_idxs_added[]          (index:4, idx:4)
```

Total size: `28 + 4×R1 + 16×A1 + 4×R2 + 8×A2 + 4×R3 + 8×A3`

```cpp
// src/overpass_api/core/type_relation.h:369–377
static uint32 size_of(void* data) {
  if (*((uint32*)data + 1) == 0xffffffff)
    return 20 + 12 * *((uint32*)data + 2) + 4 * *((uint32*)data + 3) + 4 * *((uint32*)data + 4);
  else
    return 28 + 4 * *((uint32*)data + 1) + 16 * *((uint32*)data + 2)
              +  4 * *((uint32*)data + 3) +  8 * *((uint32*)data + 4)
              +  4 * *((uint32*)data + 5) +  8 * *((uint32*)data + 6);
}
```

---

## Shared Container Format

The `.bin` and `.bin.idx` file structures are identical across all three element types. Only the index key type and block size differ. Everything below applies equally to `nodes.bin`, `ways.bin`, and `relations.bin`.

### .bin.idx — Index File Format

Maps spatial index values to block positions. Consists of an 8-byte header followed by fixed-size entries.

**Source:** `src/template_db/file_blocks_index.h`

#### Header (8 bytes)

```
Offset  Size  Type    Field                    Description
------  ----  ------  -----------------------  --------------------------------------------------
0       4     int32   file_format_version      Must be in [7512, 7600]
4       1     uint8   block_size_log2          physical_block_bytes = 1 << this value
5       1     uint8   compression_factor_log2  compression_factor   = 1 << this value
6       2     uint16  compression_method       0=none, 1=ZLIB, 2=LZ4
```

Current format version: `7600` (`FILE_FORMAT_VERSION`, `file_blocks_index.h:133`).

Written by `shift_log(get_block_size())` where `shift_log(x) = floor(log2(x))` (`types.h:324`). Read back as `block_size_ = 1ull << header[4]` (`file_blocks_index.h:475`). For nodes/ways: `block_size_log2 = 14` → `physical_block_bytes = 16,384`. `compression_factor_log2 = 3` → `compression_factor = 8` → `decompressed_block_bytes = 131,072`.

The total number of index entries is `(idx_file_size - 8) / 16`. The index file has no entry count field; readers must use the file size.

#### Index Entry (16 bytes each)

**Source:** `src/template_db/file_blocks_index.h:37–51`, `646–657`

```
Offset  Size  Type    Field   Description
------  ----  ------  ------  ---------------------------------------------------
0       4     uint32  pos     Start physical block number (0-based)
4       4     uint32  size    Number of consecutive physical blocks in this entry
8       4     uint32  (pad)   Reserved / zero
12      4     uint32  index   Index key value (Uint32_Index or Uint31_Index)
```

- **Byte offset** in `.bin` file: `entry.pos × physical_block_bytes`
- **Byte length** to read: `entry.size × physical_block_bytes`

### .bin — Data Block Format

A flat sequence of physical blocks. **Source:** `src/template_db/block_backend.h:100–166`

#### Compressed vs. uncompressed

**Source:** `src/template_db/file_blocks.h:821–865, 988–1013`

For each index entry, read `entry.size × physical_block_bytes` bytes from `.bin` at byte offset `entry.pos × physical_block_bytes`. Then:

- **`NO_COMPRESSION`**: the bytes are the decompressed payload directly. The logical block size for parsing is `physical_block_bytes × compression_factor` bytes, but only `entry.size × physical_block_bytes` are populated; bytes beyond `total_payload_size` (see below) are zero.
- **`ZLIB_COMPRESSION`** or **`LZ4_COMPRESSION`**: pass the entire `entry.size × physical_block_bytes` span as the compressed input to the decompressor. Output buffer must be `physical_block_bytes × compression_factor` bytes. The compressed data is written zero-padded to an exact `entry.size × physical_block_bytes` boundary on disk (`file_blocks.h:1036–1037`).

For LZ4, the output buffer allocated is `2 × physical_block_bytes × compression_factor` to handle pathological incompressible input expanding beyond the nominal decompressed size (`file_blocks.h:699, 1006`).

#### Block payload layout

```
Offset  Size  Type    Field               Description
------  ----  ------  ----------------    -----------------------------------------
0       4     uint32  total_payload_size  Bytes of used payload in this buffer
4       ...           index groups        Packed end-to-end (see below)
```

#### Index group layout

```
Offset within group  Size   Type      Field            Description
-------------------  ----   --------  ---------------  ----------------------------
0                    4      uint32    next_idx_offset  Byte offset of NEXT group from
                                                       start of buffer (or ==
                                                       total_payload_size if last)
4                    4      uint32    index_key        Uint32_Index or Uint31_Index
8                    var    records   records[]        All records for this index key,
                                                       packed end-to-end
```

Records run from `idx_block_offset + 8` to `next_idx_offset - 1` (exclusive). For variable-length records (ways, relations) each record carries its own `size_of()` to advance the read pointer.

#### Visual block layout

```
┌─────────────────────────────────────────────────────────────────┐
│  [0..3]    total_payload_size  (uint32)                         │
│                                                                 │
│  ── Index Group 1 ────────────────────────────────────────────  │
│  [4..7]    next_idx_offset_1   (uint32, offset of group 2)      │
│  [8..11]   index_key_1         (uint32, spatial index)          │
│  [12..]    record #1           (12 B for nodes, variable for     │
│            record #2            ways/relations)                  │
│            ...                                                  │
│                                                                 │
│  ── Index Group 2 (starts at next_idx_offset_1) ─────────────  │
│  [N+0..3]  next_idx_offset_2   (uint32)                         │
│  [N+4..7]  index_key_2         (uint32)                         │
│  [N+8..]   records...                                           │
│                                                                 │
│  [total_payload_size .. block_size-1]  (zero padding)           │
└─────────────────────────────────────────────────────────────────┘
```

#### Multi-block segments

If a single index group exceeds `block_size`, it spans multiple consecutive blocks (`size > 1` in the index entry). The buffer is enlarged dynamically. See `src/template_db/block_backend.h:250–262` and `src/template_db/block_backend_write.h:44–65`.

---

## Write Path Summary

`Block_Backend::update()` (`src/template_db/block_backend.h`) calls `flush_if_necessary_and_write_obj()` (`src/template_db/block_backend_write.h:28–73`):

1. Records are accumulated in a write buffer, sorted by index key.
2. Each new index key group is prefixed with `next_idx_offset` (4 bytes) and the key value (4 bytes).
3. When the buffer is full, it is flushed as one block via `file_blocks.insert_block()`.
4. The first 4 bytes of each flushed block are set to `bytes_written` (the payload size).

---

## Source File Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| `Node_Skeleton` struct & serialization | `src/overpass_api/core/type_node.h` | 87–139 |
| `Node` struct | `src/overpass_api/core/type_node.h` | 29–58 |
| `Way_Skeleton` struct & serialization | `src/overpass_api/core/type_way.h` | 87–156 |
| `Way_Delta` struct & serialization | `src/overpass_api/core/type_way.h` | 159–409 |
| `Way` struct | `src/overpass_api/core/type_way.h` | 35–65 |
| `Relation_Skeleton` struct & serialization | `src/overpass_api/core/type_relation.h` | 104–189 |
| `Relation_Delta` struct & serialization | `src/overpass_api/core/type_relation.h` | 192–474 |
| `Relation_Entry` struct | `src/overpass_api/core/type_relation.h` | 32–51 |
| `Relation` struct | `src/overpass_api/core/type_relation.h` | 54–82 |
| `Uint32_Index` | `src/overpass_api/core/basic_types.h` | 38–99 |
| `Uint31_Index` | `src/overpass_api/core/basic_types.h` | 120–163 |
| `Uint64` (node ID type) | `src/overpass_api/core/basic_types.h` | 166–224 |
| `Quad_Coord` | `src/overpass_api/core/basic_types.h` | 227–239 |
| `Attic<>` wrapper | `src/overpass_api/core/basic_types.h` | 242–284 |
| `ll_upper()` Morton encoding | `src/overpass_api/core/index_computations.h` | 59–87 |
| `ilat()` / `ilon()` Morton decoding | `src/overpass_api/core/index_computations.h` | 89–115 |
| `calc_index()` multi-tile index | `src/overpass_api/core/index_computations.h` | 117–182 |
| File properties (block size, compression) | `src/overpass_api/core/settings.cc` | 37–89, 125, 137, 149 |
| `.idx` header write | `src/template_db/file_blocks_index.h` | 626–658 |
| `.idx` header read | `src/template_db/file_blocks_index.h` | 453–488 |
| `.idx` entry layout / iterator | `src/template_db/file_blocks_index.h` | 37–51, 138–189 |
| `FILE_FORMAT_VERSION` constant | `src/template_db/file_blocks_index.h` | 133 |
| Block read (compressed/uncompressed) | `src/template_db/file_blocks.h` | 813–877 |
| Block payload parsing (iterator) | `src/template_db/block_backend.h` | 100–166, 208–263 |
| Block write / flush logic | `src/template_db/block_backend_write.h` | 27–73 |
| Compression constants | `src/template_db/types.h` | 86–90 |
| `Block_Backend` API | `src/template_db/block_backend.h` | 499–540 |

---

## Documentation Status

Files drawn from `src/bin/download_clone.sh`. Each `.bin` file is accompanied by a `.bin.idx` index file (same format for all); `.map` files use a separate random-access format.

### Base files (`FILES_BASE`)

- [x] `nodes.bin` / `nodes.bin.idx` — Node_Skeleton records (this document)
- [ ] `nodes.map` — random-access node ID → ll_upper index map
- [ ] `node_tags_local.bin` — per-node tags indexed by spatial tile
- [ ] `node_tags_global.bin` — per-node tags indexed by (key, value) pair
- [ ] `node_frequent_tags.bin` — frequent-tag optimised index for nodes
- [ ] `node_keys.bin` — key string table for node tags
- [x] `ways.bin` / `ways.bin.idx` — Way_Skeleton records (this document)
- [ ] `ways.map` — random-access way ID → index map
- [ ] `way_tags_local.bin` — per-way tags indexed by spatial tile
- [ ] `way_tags_global.bin` — per-way tags indexed by (key, value) pair
- [ ] `way_frequent_tags.bin` — frequent-tag optimised index for ways
- [ ] `way_keys.bin` — key string table for way tags
- [x] `relations.bin` / `relations.bin.idx` — Relation_Skeleton records (this document)
- [ ] `relations.map` — random-access relation ID → index map
- [ ] `relation_roles.bin` — role string table for relation members
- [ ] `relation_tags_local.bin` — per-relation tags indexed by spatial tile
- [ ] `relation_tags_global.bin` — per-relation tags indexed by (key, value) pair
- [ ] `relation_frequent_tags.bin` — frequent-tag optimised index for relations
- [ ] `relation_keys.bin` — key string table for relation tags

### Meta files (`FILES_META`, `--meta=yes`)

- [ ] `nodes_meta.bin` — changeset/uid/timestamp metadata for current nodes
- [ ] `ways_meta.bin` — changeset/uid/timestamp metadata for current ways
- [ ] `relations_meta.bin` — changeset/uid/timestamp metadata for current relations
- [ ] `user_data.bin` — user ID → display name mapping
- [ ] `user_indices.bin` — index of edits per user

### Attic files (`FILES_ATTIC`, `--meta=attic`)

- [x] `nodes_attic.bin` / `nodes_attic.bin.idx` — Attic\<Node_Skeleton\> historical records (this document)
- [ ] `nodes_attic.map` — random-access node ID → attic index map
- [ ] `node_attic_indexes.bin` — per-node list of historical index values
- [ ] `nodes_attic_undeleted.bin` — node IDs present in attic but not deleted
- [ ] `nodes_meta_attic.bin` — metadata for historical node versions
- [ ] `node_changelog.bin` — per-tile log of node changes
- [ ] `node_tags_local_attic.bin` — historical node tags by spatial tile
- [ ] `node_tags_global_attic.bin` — historical node tags by (key, value)
- [ ] `node_frequent_tags_attic.bin` — historical frequent-tag index for nodes
- [x] `ways_attic.bin` / `ways_attic.bin.idx` — Way_Delta historical records (this document)
- [ ] `ways_attic.map` — random-access way ID → attic index map
- [ ] `way_attic_indexes.bin` — per-way list of historical index values
- [ ] `ways_attic_undeleted.bin` — way IDs present in attic but not deleted
- [ ] `ways_meta_attic.bin` — metadata for historical way versions
- [ ] `way_changelog.bin` — per-tile log of way changes
- [ ] `way_tags_local_attic.bin` — historical way tags by spatial tile
- [ ] `way_tags_global_attic.bin` — historical way tags by (key, value)
- [ ] `way_frequent_tags_attic.bin` — historical frequent-tag index for ways
- [x] `relations_attic.bin` / `relations_attic.bin.idx` — Relation_Delta historical records (this document)
- [ ] `relations_attic.map` — random-access relation ID → attic index map
- [ ] `relation_attic_indexes.bin` — per-relation list of historical index values
- [ ] `relations_attic_undeleted.bin` — relation IDs present in attic but not deleted
- [ ] `relations_meta_attic.bin` — metadata for historical relation versions
- [ ] `relation_changelog.bin` — per-tile log of relation changes
- [ ] `relation_tags_local_attic.bin` — historical relation tags by spatial tile
- [ ] `relation_tags_global_attic.bin` — historical relation tags by (key, value)
- [ ] `relation_frequent_tags_attic.bin` — historical frequent-tag index for relations
