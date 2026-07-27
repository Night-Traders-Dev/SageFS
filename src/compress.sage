## compress.sage — SageFS Transparent Compression Engine
##
## Tiered compression: lz4 for hot/fast data, zstd for cold/best ratio.
## Simulates compression ratios since native C libraries aren't available.

let COMPRESS_NONE: Int = 0
let COMPRESS_LZ4: Int = 1
let COMPRESS_ZSTD: Int = 2
let COMPRESS_ZLIB: Int = 3

let LZ4_RATIO = 0.6
let ZSTD_RATIO = 0.35
let ZLIB_RATIO = 0.4

let INCOMPRESSIBLE_THRESHOLD = 0.95

class CompressionEngine:
    proc init(self):
        self.stats_compressed_bytes = 0
        self.stats_original_bytes = 0
        self.stats_incompressible = 0

    proc select_algorithm(self, temperature: String) -> Int:
        if temperature == "hot":
            return COMPRESS_LZ4
        elif temperature == "cold":
            return COMPRESS_ZSTD
        else:
            return COMPRESS_LZ4

    proc compress(self, data: Bytes, algo: Int) -> Bytes:
        let original_size = bytes_len(data)
        if algo == COMPRESS_NONE or original_size < 64:
            self.stats_original_bytes = self.stats_original_bytes + original_size
            self.stats_compressed_bytes = self.stats_compressed_bytes + original_size
            return data

        var compressed_size = original_size
        if algo == COMPRESS_LZ4:
            compressed_size = int(original_size * LZ4_RATIO)
        elif algo == COMPRESS_ZSTD:
            compressed_size = int(original_size * ZSTD_RATIO)
        elif algo == COMPRESS_ZLIB:
            compressed_size = int(original_size * ZLIB_RATIO)

        if compressed_size < 8:
            compressed_size = 8

        self.stats_original_bytes = self.stats_original_bytes + original_size
        self.stats_compressed_bytes = self.stats_compressed_bytes + compressed_size

        let ratio = compressed_size / original_size
        if ratio > INCOMPRESSIBLE_THRESHOLD:
            self.stats_incompressible = self.stats_incompressible + 1
            return data

        var result = bytes()
        bytes_push(result, algo & 0xFF)
        bytes_push(result, (original_size >> 8) & 0xFF)
        bytes_push(result, original_size & 0xFF)
        for i in range(original_size):
            bytes_push(result, bytes_get(data, i))
        return result

    proc decompress(self, data: Bytes) -> Bytes:
        if bytes_len(data) < 3:
            return data
        let algo = bytes_get(data, 0)
        if algo == COMPRESS_NONE:
            return data
        if algo != COMPRESS_LZ4 and algo != COMPRESS_ZSTD and algo != COMPRESS_ZLIB:
            return data
        let original_size = (bytes_get(data, 1) << 8) | bytes_get(data, 2)
        let total_size = bytes_len(data)

        var result = bytes()
        var src_idx = 3
        while src_idx < bytes_len(data) and bytes_len(result) < original_size:
            bytes_push(result, bytes_get(data, src_idx))
            src_idx = src_idx + 1
        while bytes_len(result) < original_size:
            bytes_push(result, 0)
        return result

    proc is_incompressible(self, original_size: Int, compressed_size: Int) -> Bool:
        if original_size <= 0:
            return true
        let ratio = compressed_size / original_size
        return ratio > INCOMPRESSIBLE_THRESHOLD

    proc get_stats(self) -> Dict:
        var ratio = 0.0
        if self.stats_original_bytes > 0:
            ratio = self.stats_compressed_bytes / self.stats_original_bytes
        return {
            "original_bytes": self.stats_original_bytes,
            "compressed_bytes": self.stats_compressed_bytes,
            "ratio": ratio,
            "incompressible_count": self.stats_incompressible
        }
