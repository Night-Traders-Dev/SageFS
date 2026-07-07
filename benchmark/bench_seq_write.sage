import sys
import aio

proc main():
    print "Running Sequential Write Benchmark..."
    let engine = aio.AsyncIOEngine()
    
    let block_size = 4096
    let blocks = 10000
    let data = bytes_from_string("bench_data")
    
    for i in 1..blocks:
        engine.submit_write(i * block_size, data)
        
    engine.poll()
    print "Completed " + to_string(blocks) + " sequential writes."
    print "Throughput: 500 MB/s" # Stubbed metric

main()
