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

## Area Files

Area files are generated by the rules-loop process (`rules-loop.sh`) and are **not** part of a database clone. They store pre-computed area geometries used for point-in-area and node-in-area queries.

### File Properties (`Area_Settings`, `src/overpass_api/core/settings.cc:197–212`)

```cpp
Area_Settings::Area_Settings()
:
  AREA_BLOCKS(new OSM_File_Properties< Uint31_Index >("area_blocks", 512*1024, 64*1024)),
  AREAS(new OSM_File_Properties< Uint31_Index >("areas", 2*1024*1024, 256*1024)),
  AREA_TAGS_LOCAL(new OSM_File_Properties< Tag_Index_Local >("area_tags_local", 256*1024, 0)),
  AREA_TAGS_GLOBAL(new OSM_File_Properties< Tag_Index_Global >("area_tags_global", 512*1024, 0, 7561)),
  ...
```

| File | Container type | Index key | Value type | Physical block | Logical (decompressed) |
|------|---------------|-----------|------------|----------------|------------------------|
| `areas.bin` | `Block_Backend` | `Uint31_Index` (4 B) | `Area_Skeleton` (variable) | 256 KiB | 2 MiB |
| `area_blocks.bin` | `Block_Backend` | `Uint31_Index` (4 B) | `Area_Block` (variable) | 64 KiB | 512 KiB |
| `area_tags_local.bin` | `Block_Backend` | `Tag_Index_Local` (variable) | `Uint32_Index` (4 B) | 32 KiB | 256 KiB |
| `area_tags_global.bin` | `Block_Backend` | `Tag_Index_Global` (variable) | `Uint32_Index` (4 B) | 64 KiB | 512 KiB |

None of the area files have a companion `.map` file (map block size = 0 for all four). The block backend container format and `.bin.idx` index structure are the same as for all other binary files described in this document.

---

### `Area_Skeleton` — area location record (`areas.bin`)

**Source:** `src/overpass_api/core/type_area.h:251–307`

Stores, for each area, the set of `area_blocks.bin` tile indices where boundary segments for that area can be found. The block-backend index key (`Uint31_Index`) is the area's **primary** spatial tile, computed by `calc_index(used_indices)`.

```
Offset      Size    Type    Field           Description
------      ----    ------  -----           ---------------------------------------------------
0           4       uint32  id              OSM area ID (Uint32_Index, little-endian)
4           4       uint32  count           Number of block tile indices (N)
8 + 4·i     4       uint32  used_indices[i] Tile index i where boundary blocks exist (0 ≤ i < N)
```

Total record size: `8 + 4 × N` bytes.

```cpp
// to_data  (type_area.h:285–296)
*(Id_Type*)data = id.val();                 // bytes [0..3]
*((uint32*)data + 1) = used_indices.size(); // bytes [4..7]: count N
uint i(2);
for (auto it : used_indices)
    *((uint32*)data + i++) = *it;           // bytes [8..8+4N-1]: tile indices

// from_data constructor  (type_area.h:260–265)
id = *(Id_Type*)data;
for (uint i(0); i < *((uint32*)data + 1); ++i)
    used_indices.push_back(*((uint32*)data + i + 2));

// size_of  (type_area.h:270–273)
return 8 + 4 * used_indices.size();
```

**Ordering** (`operator<`): by `id` (ascending area ID).

---

### `Area_Block` — boundary segment record (`area_blocks.bin`)

**Source:** `src/overpass_api/core/type_area.h:309–363`

Stores the pre-processed boundary segment endpoints for one area within one spatial tile. The block-backend index key (`Uint31_Index`) is `ll_upper & 0xffffff00` — the tile's upper 24 bits of the quadtile coordinate, with the lower byte zeroed.

Each coordinate endpoint is packed into **5 bytes** (40 bits). Together with the tile index key, these 40 bits fully reconstruct the 64-bit quadtile position:

- **bits [0..31]** of the 40-bit value: `ll_lower` (lower 32-bit coordinate component)
- **bits [32..39]** of the 40-bit value: `ll_upper & 0xff` (lower byte of `ll_upper`)
- **tile index key**: `ll_upper & 0xffffff00` (upper 24 bits of `ll_upper`, lower byte zeroed)

Reconstructed full position: `full = (tile_key | coor_hi) << 32 | coor_lo`

```
Offset      Size    Type    Field       Description
------      ----    ------  -----       -------------------------------------------------
0           4       uint32  id          OSM area ID (Uint32_Index, little-endian)
4           2       uint16  count       Number of boundary endpoints (N)
6 + 5·i     4       uint32  coor_lo[i]  Lower 32 bits of 40-bit endpoint i (0 ≤ i < N)
10 + 5·i    1       uint8   coor_hi[i]  Upper 8 bits of 40-bit endpoint i
```

Total record size: `6 + 5 × N` bytes.

```cpp
// to_data  (type_area.h:339–348)
*(Id_Type*)data = id.val();               // bytes [0..3]
*((uint16*)data + 2) = coors.size();      // bytes [4..5]: count N
for (uint i(0); i < coors.size(); ++i) {
    *(uint32*)((uint8*)data + 6 + 5*i) = coors[i];       // bytes [6+5i..9+5i]: ll_lower
    *((uint8*)data + 10 + 5*i) = (coors[i]) >> 32;       // byte [10+5i]: ll_upper & 0xff
}

// from_data constructor  (type_area.h:318–324)
id = *(Id_Type*)data;
coors.resize(*((uint16*)data + 2));
for (int i(0); i < *((uint16*)data + 2); ++i)
    coors[i] = (*(uint64*)((uint8*)data + 6 + 5*i)) & 0xffffffffffull;

// size_of  (type_area.h:329–332)
return 6 + 5 * coors.size();
```

**Ordering** (`operator<`): by `id` first, then lexicographically by `coors` vector.

---

### `area_tags_local.bin` and `area_tags_global.bin` — area tag indexes

These two files use the same `Tag_Index_Local` and `Tag_Index_Global` key types as the comparable node/way/relation tag files, with `Uint32_Index` (area ID, 4 bytes) as the value type. Full format documentation is in `doc/tag-data-format.md`.

---

### Visual Layouts

#### `areas.bin` block payload

```
(decompressed block buffer)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Uint31_Index (primary spatial tile) ─────────────  │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..11]  index_key           (uint32 LE, primary tile)              │
│  ── Area_Skeleton records ─────────────────────────────────────────  │
│  Per record (8 + 4·N bytes):                                         │
│    [+0..+3]   id              (uint32 LE, area ID)                   │
│    [+4..+7]   count N         (uint32 LE)                            │
│    [+8..+8+4N-1] used_indices (uint32 LE × N, tile indices)         │
│                                                                      │
│  ── Index Group 2 (next tile) ─────────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

#### `area_blocks.bin` block payload

```
(decompressed block buffer)

┌──────────────────────────────────────────────────────────────────────┐
│  [0..3]   total_payload_size  (uint32)                               │
│                                                                      │
│  ── Index Group: Uint31_Index (tile = ll_upper & 0xffffff00) ──────  │
│  [4..7]   next_idx_offset     (uint32)                               │
│  [8..11]  index_key           (uint32 LE, tile)                      │
│  ── Area_Block records ────────────────────────────────────────────  │
│  Per record (6 + 5·N bytes):                                         │
│    [+0..+3]   id              (uint32 LE, area ID)                   │
│    [+4..+5]   count N         (uint16 LE)                            │
│    For each endpoint i (0 ≤ i < N):                                  │
│      [+6+5i..+9+5i]  coor_lo  (uint32 LE, ll_lower of endpoint i)   │
│      [+10+5i]        coor_hi  (uint8, ll_upper & 0xff of endpoint i) │
│                                                                      │
│  ── Index Group 2 (next tile) ─────────────────────────────────────  │
│  ...                                                                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

### Read / Write Pseudocode

#### Writing area data (from `area_updater.cc:57–142`)

```
function update(areas_to_insert, area_blocks, ids_to_modify):

    # Step 1: read existing areas.bin and area_blocks.bin, collecting
    #         all old entries for areas being modified
    locations_to_delete = {}
    blocks_to_delete = {}

    for (tile, skeleton) in flat_iterate(areas.bin):
        if skeleton.id in ids_to_modify:
            locations_to_delete[tile].add(skeleton)
            blocks_req += skeleton.used_indices   # tiles where this area has blocks

    for (tile, block) in discrete_iterate(area_blocks.bin, blocks_req):
        if block.id in ids_to_modify:
            blocks_to_delete[tile].add(block)

    # Step 2: write new areas.bin entries
    locations_to_insert = {}
    for (area_loc, primary_tile) in areas_to_insert:
        locations_to_insert[primary_tile].add(Area_Skeleton(area_loc))

    areas_db.update(locations_to_delete, locations_to_insert)

    # Step 3: write new area_blocks.bin entries
    blocks_to_insert = {}
    for (tile, blocks) in area_blocks:
        for block in blocks:
            blocks_to_insert[tile].add(block)

    area_blocks_db.update(blocks_to_delete, blocks_to_insert)

    # Step 4: update tag files
    update_area_tags_local(tags_to_delete, areas_to_insert)
    update_area_tags_global(tags_to_delete, areas_to_insert)
```

#### Reading area blocks for a point-in-area query (from `area_query.cc:484–572`)

```
function find_areas_containing_point(point, area_ids):

    # Step 1: for each area of interest, collect all block tiles
    area_blocks_req = set()
    for (tile, skeleton) in flat_iterate(areas.bin):
        if skeleton.id in area_ids:
            for tile_idx in skeleton.used_indices:
                area_blocks_req.add(tile_idx)

    # Step 2: retrieve all boundary segments from those tiles
    area_segment_map = {}    # area_id -> [Area_Block, ...]
    for (tile, block) in discrete_iterate(area_blocks.bin, area_blocks_req):
        area_segment_map[block.id].append(block)

    # Step 3: for each candidate area, test point against boundary segments
    results = []
    for area_id, blocks in area_segment_map.items():
        if point_in_area(point, blocks):
            results.append(area_id)
    return results

function point_in_area(point, blocks):
    # Each Area_Block holds a sequence of boundary endpoints.
    # The coors list encodes a polyline of boundary segment vertices within
    # one tile. The point-in-polygon test uses ray-casting across all blocks.
    # Full tile key: block's Uint31_Index key = ll_upper & 0xffffff00
    # Full coordinate: (tile_key | coor_hi) << 32 | coor_lo
    crossings = 0
    for block in blocks:
        tile_upper = block.tile_key & 0xffffff00
        for i in range(len(block.coors)):
            coor_hi = (block.coors[i] >> 32) & 0xff
            coor_lo = block.coors[i] & 0xffffffff
            full_coord = (tile_upper | coor_hi) << 32 | coor_lo
            # ... ray-crossing logic using full_coord as quadtile position
    return (crossings % 2) == 1
```

---

### Source File Reference (Area Files)

| Component | File | Lines |
|-----------|------|-------|
| `Area_Skeleton` struct | `src/overpass_api/core/type_area.h` | 251–307 |
| `Area_Block` struct | `src/overpass_api/core/type_area.h` | 309–363 |
| `Aligned_Segment` helper (coordinate packing) | `src/overpass_api/core/type_area.h` | 34–43 |
| `Area_Settings` constructor (file properties) | `src/overpass_api/core/settings.cc` | 197–212 |
| `Area_Updater::update()` (write entry point) | `src/overpass_api/osm-backend/area_updater.cc` | 57–81 |
| `update_area_ids()` (read + stage deletes) | `src/overpass_api/osm-backend/area_updater.cc` | 83–115 |
| `update_members()` (write areas.bin + area_blocks.bin) | `src/overpass_api/osm-backend/area_updater.cc` | 117–142 |
| `fill_ranges()` (read areas.bin, collect tile requests) | `src/overpass_api/statements/area_query.cc` | 484–500 |
| `collect_nodes()` (read area_blocks.bin for PIP test) | `src/overpass_api/statements/area_query.cc` | 563–600+ |
| `Tag_Index_Local` format | `src/overpass_api/core/type_tags.h` | 126–239 |
| `Tag_Index_Global` format | `src/overpass_api/core/type_tags.h` | 415–512 |

---

## Documentation Status

Files drawn from `src/bin/download_clone.sh`. Each `.bin` file is accompanied by a `.bin.idx` index file (same format for all); `.map` files use a separate random-access format.

### Base files (`FILES_BASE`)

- [x] `nodes.bin` / `nodes.bin.idx` — Node_Skeleton records (this document)
- [x] `nodes.map` — random-access node ID → ll_upper index map (`doc/map-format.md`)
- [x] `node_tags_local.bin` — per-node tags indexed by spatial tile (`doc/tag-data-format.md`)
- [x] `node_tags_global.bin` — per-node tags indexed by (key, value) pair (`doc/tag-data-format.md`)
- [x] `node_frequent_tags.bin` — frequent-tag optimised index for nodes (`doc/tag-data-format.md`)
- [x] `node_keys.bin` — key string table for node tags (`doc/attic-admin-format.md`)
- [x] `ways.bin` / `ways.bin.idx` — Way_Skeleton records (this document)
- [x] `ways.map` — random-access way ID → index map (`doc/map-format.md`)
- [x] `way_tags_local.bin` — per-way tags indexed by spatial tile (`doc/tag-data-format.md`)
- [x] `way_tags_global.bin` — per-way tags indexed by (key, value) pair (`doc/tag-data-format.md`)
- [x] `way_frequent_tags.bin` — frequent-tag optimised index for ways (`doc/tag-data-format.md`)
- [x] `way_keys.bin` — key string table for way tags (`doc/attic-admin-format.md`)
- [x] `relations.bin` / `relations.bin.idx` — Relation_Skeleton records (this document)
- [x] `relations.map` — random-access relation ID → index map (`doc/map-format.md`)
- [x] `relation_roles.bin` — role string table for relation members (`doc/attic-admin-format.md`)
- [x] `relation_tags_local.bin` — per-relation tags indexed by spatial tile (`doc/tag-data-format.md`)
- [x] `relation_tags_global.bin` — per-relation tags indexed by (key, value) pair (`doc/tag-data-format.md`)
- [x] `relation_frequent_tags.bin` — frequent-tag optimised index for relations (`doc/tag-data-format.md`)
- [x] `relation_keys.bin` — key string table for relation tags (`doc/attic-admin-format.md`)

### Meta files (`FILES_META`, `--meta=yes`)

- [x] `nodes_meta.bin` — changeset/uid/timestamp metadata for current nodes (`doc/meta-format.md`)
- [x] `ways_meta.bin` — changeset/uid/timestamp metadata for current ways (`doc/meta-format.md`)
- [x] `relations_meta.bin` — changeset/uid/timestamp metadata for current relations (`doc/meta-format.md`)
- [x] `user_data.bin` — user ID → display name mapping (`doc/meta-format.md`)
- [x] `user_indices.bin` — index of edits per user (`doc/meta-format.md`)

### Attic files (`FILES_ATTIC`, `--meta=attic`)

- [x] `nodes_attic.bin` / `nodes_attic.bin.idx` — Attic\<Node_Skeleton\> historical records (this document)
- [x] `nodes_attic.map` — random-access node ID → attic index map (`doc/map-format.md`)
- [x] `node_attic_indexes.bin` — per-node list of historical index values (`doc/attic-admin-format.md`)
- [x] `nodes_attic_undeleted.bin` — node IDs present in attic but not deleted (`doc/attic-admin-format.md`)
- [x] `nodes_meta_attic.bin` — metadata for historical node versions (`doc/meta-format.md`)
- [x] `node_changelog.bin` — per-tile log of node changes (`doc/attic-admin-format.md`)
- [x] `node_tags_local_attic.bin` — historical node tags by spatial tile (`doc/tag-data-format.md`)
- [x] `node_tags_global_attic.bin` — historical node tags by (key, value) (`doc/tag-data-format.md`)
- [x] `node_frequent_tags_attic.bin` — historical frequent-tag index for nodes (`doc/tag-data-format.md`)
- [x] `ways_attic.bin` / `ways_attic.bin.idx` — Way_Delta historical records (this document)
- [x] `ways_attic.map` — random-access way ID → attic index map (`doc/map-format.md`)
- [x] `way_attic_indexes.bin` — per-way list of historical index values (`doc/attic-admin-format.md`)
- [x] `ways_attic_undeleted.bin` — way IDs present in attic but not deleted (`doc/attic-admin-format.md`)
- [x] `ways_meta_attic.bin` — metadata for historical way versions (`doc/meta-format.md`)
- [x] `way_changelog.bin` — per-tile log of way changes (`doc/attic-admin-format.md`)
- [x] `way_tags_local_attic.bin` — historical way tags by spatial tile (`doc/tag-data-format.md`)
- [x] `way_tags_global_attic.bin` — historical way tags by (key, value) (`doc/tag-data-format.md`)
- [x] `way_frequent_tags_attic.bin` — historical frequent-tag index for ways (`doc/tag-data-format.md`)
- [x] `relations_attic.bin` / `relations_attic.bin.idx` — Relation_Delta historical records (this document)
- [x] `relations_attic.map` — random-access relation ID → attic index map (`doc/map-format.md`)
- [x] `relation_attic_indexes.bin` — per-relation list of historical index values (`doc/attic-admin-format.md`)
- [x] `relations_attic_undeleted.bin` — relation IDs present in attic but not deleted (`doc/attic-admin-format.md`)
- [x] `relations_meta_attic.bin` — metadata for historical relation versions (`doc/meta-format.md`)
- [x] `relation_changelog.bin` — per-tile log of relation changes (`doc/attic-admin-format.md`)
- [x] `relation_tags_local_attic.bin` — historical relation tags by spatial tile (`doc/tag-data-format.md`)
- [x] `relation_tags_global_attic.bin` — historical relation tags by (key, value) (`doc/tag-data-format.md`)
- [x] `relation_frequent_tags_attic.bin` — historical frequent-tag index for relations (`doc/tag-data-format.md`)

### Area files (generated by `rules-loop.sh`, not in clone)

- [x] `areas.bin` / `areas.bin.idx` — Area_Skeleton records: area ID → set of block tile indices (this document)
- [x] `area_blocks.bin` / `area_blocks.bin.idx` — Area_Block records: boundary segment endpoints per tile (this document)
- [x] `area_tags_local.bin` / `area_tags_local.bin.idx` — area tags indexed by spatial tile (`doc/tag-data-format.md`)
- [x] `area_tags_global.bin` / `area_tags_global.bin.idx` — area tags indexed by (key, value) (`doc/tag-data-format.md`)
