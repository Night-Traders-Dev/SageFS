class CompressionEngine:
    proc init(self):
        self.algorithms = ["lz4", "zstd", "zlib", "none"]
        
    proc select_algorithm(self, temperature: String) -> String:
        if temperature == "hot":
            return "lz4"
        elif temperature == "cold":
            return "zstd"
        else:
            # Fallback for unknown or mixed temperature
            return "none"
            
    proc compress_cluster(self, data: Bytes, algo: String) -> Bytes:
        if algo == "none":
            return data
            
        # In a real implementation, we would call native C functions for compression
        # e.g., lz4_compress(data) or zstd_compress(data)
        
        # Simulated compression: prepend algorithm name
        # We need to return some bytes representing the compressed form
        return data # Stub for SageLang representation
        
    proc decompress_cluster(self, data: Bytes, algo: String) -> Bytes:
        if algo == "none":
            return data
            
        # Simulated decompression
        return data

    proc is_incompressible(self, original_size: Int, compressed_size: Int) -> Bool:
        # If compression ratio is worse than 95%, consider it incompressible
        return compressed_size >= (original_size * 95 / 100)
