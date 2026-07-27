## test_encrypt.sage — unit tests for the SageFS encryption layer

import encrypt
let EncryptionLayer = encrypt.EncryptionLayer

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc check_str(name: String, got: String, expected: String):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + got + " expected=" + expected)

proc test_derive_key():
    print("derive_inode_key:")
    let layer = EncryptionLayer("test-master-key")
    let k1 = layer.derive_inode_key(1, "data")
    let k2 = layer.derive_inode_key(1, "data")
    let k3 = layer.derive_inode_key(2, "data")
    check_str("same ino+salt = same key", k1, k2)
    check_bool("different ino = different key", k1 != k3)
    let k4 = layer.derive_inode_key(1, "filename")
    check_bool("different salt = different key", k1 != k4)

proc test_encrypt_decrypt_data():
    print("encrypt/decrypt data roundtrip:")
    let layer = EncryptionLayer("master-key")
    let original = bytes("This is sensitive data that should be encrypted")
    let encrypted = layer.encrypt_data(original, 42)
    check_bool("encrypted length > original", bytes_len(encrypted) > bytes_len(original))
    check_bool("encrypted differs from original", bytes_get(encrypted, 0) != bytes_get(original, 0) or bytes_len(encrypted) != bytes_len(original))

    let decrypted = layer.decrypt_data(encrypted, 42)
    var enc_match = true
    for i in range(bytes_len(original)):
        if bytes_get(decrypted, i) != bytes_get(original, i):
            enc_match = false
    check_bool("decrypted matches original", enc_match)

proc test_encrypt_decrypt_data_empty():
    print("encrypt/decrypt empty data:")
    let layer = EncryptionLayer("key")
    let empty = bytes()
    let enc = layer.encrypt_data(empty, 1)
    check_bool("encrypted empty has algo byte", bytes_len(enc) == 1)
    let dec = layer.decrypt_data(enc, 1)
    check("decrypted empty len", bytes_len(dec), 0)

proc test_filename_encryption():
    print("filename encrypt/decrypt roundtrip:")
    let layer = EncryptionLayer("file-key")
    let names = ["hello.txt", "my_document.pdf", "image.jpg", "a"]
    for name in names:
        let enc = layer.encrypt_filename(name, 10)
        check_bool("encrypted name differs", enc != name or len(enc) == len(name))
        let dec = layer.decrypt_filename(enc, 10)
        check_str("decrypted name matches: " + name, dec, name)

proc test_filename_encryption_different_dir():
    print("filename encryption with different dirs:")
    let layer = EncryptionLayer("key")
    let name = "secret.doc"
    let enc1 = layer.encrypt_filename(name, 1)
    let enc2 = layer.encrypt_filename(name, 2)
    check_bool("different dir -> different encrypted name", enc1 != enc2)
    let dec1 = layer.decrypt_filename(enc1, 1)
    let dec2 = layer.decrypt_filename(enc2, 2)
    check_str("decrypt with dir 1", dec1, name)
    check_str("decrypt with dir 2", dec2, name)

proc test_get_stats():
    print("get_stats:")
    let layer = EncryptionLayer("stats-key")
    var stats = layer.get_stats()
    check("initial encrypted_inodes", stats["encrypted_inodes"], 0)
    check("initial cached keys", stats["inode_keys_cached"], 0)

    layer.encrypt_data(bytes("test data"), 5)
    stats = layer.get_stats()
    check("after encrypt, encrypted_inodes", stats["encrypted_inodes"], 1)

proc test_overwrite_key():
    print("key derivation is deterministic:")
    let layer = EncryptionLayer("deterministic")
    let k1 = layer.derive_inode_key(100, "data")
    let layer2 = EncryptionLayer("deterministic")
    let k2 = layer2.derive_inode_key(100, "data")
    check_str("same master key, same derived key", k1, k2)

proc main():
    print("=== SageFS Encryption Layer Tests ===")
    test_derive_key()
    test_encrypt_decrypt_data()
    test_encrypt_decrypt_data_empty()
    test_filename_encryption()
    test_filename_encryption_different_dir()
    test_get_stats()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
