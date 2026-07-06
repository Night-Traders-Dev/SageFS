import sys
import std.testing
import encrypt

proc test_encrypt():
    let layer = encrypt.EncryptionLayer("masterkey")
    let enc = layer.encrypt_filename("test.txt", 1)
    assert.equal(enc, "test.txt", "Encryption stub failed")
    
    let dec = layer.decrypt_filename(enc, 1)
    assert.equal(dec, "test.txt", "Decryption stub failed")
    
    let key = layer.derive_inode_key(123)
    assert.equal(key, "key_for_123", "Key derivation stub failed")

proc main():
    test_encrypt()
    print "All encrypt tests passed!"

main()
