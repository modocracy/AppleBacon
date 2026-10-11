"""Read-only helpers for Helldivers 2 DSAR containers (bundles.NN.nxa and loose DSAR files)."""
import struct
import lz4.block

class DSAR:
    def __init__(self, path):
        self.f = open(path, 'rb')
        head = self.f.read(32)
        assert head[:4] == b'DSAR', path
        self.count, self.header_size = struct.unpack_from('<II', head, 8)
        self.total = struct.unpack_from('<Q', head, 16)[0]
        self.f.seek(32)
        raw = self.f.read(self.count * 32)
        self.rows = [struct.unpack_from('<QQIIBB', raw, i * 32) for i in range(self.count)]
        self.starts = [r[0] for r in self.rows]
        self.cache = {}
    def chunk(self, i):
        if i in self.cache: return self.cache[i]
        uoff, coff, usize, csize, kind, _ = self.rows[i]
        self.f.seek(coff); raw = self.f.read(csize)
        if kind == 0: data = raw
        elif kind == 3: data = lz4.block.decompress(raw, uncompressed_size=usize)
        else: raise ValueError(f'chunk kind {kind}')
        assert len(data) == usize
        if len(self.cache) > 64: self.cache.clear()
        self.cache[i] = data
        return data
    def read(self, offset, size):
        import bisect
        out = []
        while size > 0:
            i = bisect.bisect_right(self.starts, offset) - 1
            data = self.chunk(i)
            skip = offset - self.rows[i][0]
            piece = data[skip:skip + size]
            if not piece: raise ValueError('read past chunk')
            out.append(piece); offset += len(piece); size -= len(piece)
        return b''.join(out)
    def all(self):
        return self.read(0, self.total)


class BundleIndex:
    """bundles.nxa (DSAA) index: archive name -> spans inside the numbered DSAR bundles."""
    def __init__(self, index_bytes, data_dir):
        import bisect
        self.index = index_bytes; self.dir = data_dir
        _, _, _, files, archives = struct.unpack_from('<4sIIII4x', index_bytes)
        self.names = [self.string(struct.unpack_from('<I', index_bytes, 24 + archives * 24 + i * 4)[0]) for i in range(files)]
        self.archives = {}
        for i in range(archives):
            size, name, count, entries = struct.unpack_from('<QIIQ', index_bytes, 24 + i * 24)
            rows = [struct.unpack_from('<I4xI3xB', index_bytes, entries + j * 16) for j in range(count)]
            self.archives[self.string(name)] = (size, rows, [r[0] for r in rows])
        self.bundles = {}
    def string(self, offset):
        return self.index[offset:self.index.index(b'\0', offset)].decode()
    def bundle(self, i):
        if i not in self.bundles: self.bundles[i] = DSAR(self.dir + '/' + self.names[i])
        return self.bundles[i]
    def read(self, name, offset=0, size=None):
        import bisect
        total, rows, offsets = self.archives[name]
        if size is None: size = total - offset
        out = []
        while size:
            k = bisect.bisect_right(offsets, offset) - 1
            archive_offset, bundle_offset, bundle_index = rows[k]
            end = offsets[k + 1] if k + 1 < len(rows) else total
            take = min(size, end - offset)
            out.append(self.bundle(bundle_index).read(bundle_offset + offset - archive_offset, take))
            offset += take; size -= take
        return b''.join(out)


LUA_TYPE = 0xa14e8dfa2cd117e2

def archive_entries(main):
    """Classic Stingray archive TOC rows: (name, type, main_off, stream_off, gpu_off, main_size, stream_size, gpu_size)."""
    magic, types, count = struct.unpack_from('<III', main)
    assert magic == 0xf0000011
    base = 72 + types * 32
    out = []
    for i in range(count):
        v = struct.unpack_from('<7Q6I', main, base + i * 80)
        out.append((v[0], v[1], v[2], v[3], v[4], v[7], v[8], v[9]))
    return out
