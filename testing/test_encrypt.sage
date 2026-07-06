import sys
import std.testing
import encrypt

proc test_encrypt():
    let layer = encrypt.EncryptionLayer("masterkey")
    let enc = layer.encrypt_filename("test.txt")
    assert.equal(enc, "test.txt", "Encryption stub failed")

proc main():
    test_encrypt()
    print "All encrypt tests passed!"

main()
