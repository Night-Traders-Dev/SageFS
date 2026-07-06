import sys
import std.testing
import aio

proc test_aio():
    let engine = aio.AsyncIOEngine()
    
    let read_id = engine.submit_read(1024, 4096)
    assert.equal(read_id, 1, "Submit read failed")
    
    let write_id = engine.submit_write(2048, bytes_from_string("hello"))
    assert.equal(write_id, 1, "Submit write failed")
    
    let polled = engine.poll()
    assert.equal(polled, true, "Poll failed")

proc main():
    test_aio()
    print "All aio tests passed!"

main()
