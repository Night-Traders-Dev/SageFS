import sys
import aio

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check_int(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc test_aio_init():
    let engine = aio.AsyncIOEngine()
    check_int("total_reads init", engine.total_reads, 0)
    check_int("total_writes init", engine.total_writes, 0)
    check_int("bytes_read init", engine.bytes_read, 0)
    check_int("bytes_written init", engine.bytes_written, 0)
    check_int("pending_count init", engine.pending_count(), 0)
    check_bool("read_ahead enabled", engine.read_ahead_enabled, true)
    check_bool("write_back enabled", engine.write_back_enabled, true)

proc test_submit_read():
    let engine = aio.AsyncIOEngine()
    let req_id = engine.submit_read(1024, 4096, 0)
    check_int("submit_read req_id", req_id, 1)
    check_int("total_reads incremented", engine.total_reads, 1)
    check_int("bytes_read", engine.bytes_read, 4096)
    check_int("pending after read", engine.pending_count(), 1)

proc test_submit_write():
    let engine = aio.AsyncIOEngine()
    let data = bytes("hello world")
    let req_id = engine.submit_write(2048, data, 1)
    check_int("submit_write req_id", req_id, 1)
    check_int("total_writes incremented", engine.total_writes, 1)
    check_int("bytes_written", engine.bytes_written, 11)
    check_int("pending after write", engine.pending_count(), 1)

proc test_priority_queues():
    let engine = aio.AsyncIOEngine()
    let low_id = engine.submit_read(0, 512, 2)
    let mid_id = engine.submit_read(0, 512, 1)
    let high_id = engine.submit_read(0, 512, 0)
    check_int("low priority req_id", low_id, 1)
    check_int("mid priority req_id", mid_id, 2)
    check_int("high priority req_id", high_id, 3)
    check_int("three pending", engine.pending_count(), 3)

proc test_poll():
    let engine = aio.AsyncIOEngine()
    engine.submit_read(1024, 4096, 0)
    engine.submit_write(2048, bytes("data"), 1)
    let completed = engine.poll()
    check_int("poll completed 2", completed, 2)
    check_int("no pending after poll", engine.pending_count(), 0)

proc test_get_completions():
    let engine = aio.AsyncIOEngine()
    let rid1 = engine.submit_read(100, 512, 0)
    let rid2 = engine.submit_write(200, bytes("test"), 1)
    engine.poll()

    let completions = engine.get_completions()
    check_int("two completions", len(completions), 2)
    check_int("first completion req_id", completions[0].req_id, rid1)
    check_bool("first completed flag", completions[0].completed, true)
    check_int("second completion req_id", completions[1].req_id, rid2)
    check_bool("second completed flag", completions[1].completed, true)

    let empty = engine.get_completions()
    check_int("completions queue cleared", len(empty), 0)

proc test_multiple_requests():
    let engine = aio.AsyncIOEngine()
    var i = 0
    while i < 10:
        engine.submit_read(i * 4096, 4096, 0)
        i = i + 1
    check_int("10 pending reads", engine.pending_count(), 10)
    check_int("10 total reads", engine.total_reads, 10)
    check_int("bytes_read 40960", engine.bytes_read, 40960)

    let completed = engine.poll()
    check_int("10 completed", completed, 10)

proc test_get_stats():
    let engine = aio.AsyncIOEngine()
    engine.submit_read(0, 4096, 0)
    engine.submit_write(0, bytes("hello"), 1)
    engine.poll()

    let stats = engine.get_stats()
    check_int("stats total_reads", stats["total_reads"], 1)
    check_int("stats total_writes", stats["total_writes"], 1)
    check_int("stats bytes_read", stats["bytes_read"], 4096)
    check_int("stats bytes_written", stats["bytes_written"], 5)
    check_int("stats pending", stats["pending"], 0)
    check_bool("stats read_ahead", stats["read_ahead"], true)
    check_bool("stats write_back", stats["write_back"], true)

proc main():
    print("=== AIO Engine Tests ===")
    test_aio_init()
    test_submit_read()
    test_submit_write()
    test_priority_queues()
    test_poll()
    test_get_completions()
    test_multiple_requests()
    test_get_stats()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
