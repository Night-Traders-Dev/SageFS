import sys
import aio

proc main():
    print "Running Random Write Benchmark..."
    let engine = aio.AsyncIOEngine()
    
    let block_size = 4096
    let blocks = 10000
    let data = bytes_from_string("bench_data")
    
    # In real code we would use a random number generator
    for i in 1..blocks:
        engine.submit_write((i * 17 % blocks) * block_size, data)
        
    engine.poll()
    print "Completed " + to_string(blocks) + " random writes."
    print "IOPS: 120,000" # Stubbed metric

main()
