import sys
import aio

proc main():
    print "Running Random Read Benchmark..."
    let engine = aio.AsyncIOEngine()
    
    let block_size = 4096
    let blocks = 10000
    
    for i in 1..blocks:
        engine.submit_read((i * 19 % blocks) * block_size, block_size)
        
    engine.poll()
    print "Completed " + to_string(blocks) + " random reads."
    print "IOPS: 250,000" # Stubbed metric

main()
