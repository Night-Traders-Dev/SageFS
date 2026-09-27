# Encryption Layer
**Module:** [`src/encrypt.sage`](../src/encrypt.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Provides transparent per-directory or per-file encryption for both file data and filenames.

## Implementation Details
- **Data Encryption:** **not AES.** `encrypt_data()` is a repeating-key XOR
  stream cipher: `data[i] ^ key[i % len(key)]`. There is no XTS tweak and no
  ciphertext stealing.
- **Filename Encryption:** Uses AES-256-CTS (Ciphertext Stealing) to preserve filename lengths.
- Inode keys are derived by hashing `master_key + "_" + ino + "_" + salt`
  into a 32-*character* key. There is no KDF. `VFS.mount()` constructs this
  layer with an **empty** master key, and it is not in the I/O path.

## API
- `derive_inode_key(ino) -> String`
- `encrypt_data(data, ino, offset) -> Bytes`
- `decrypt_data(data, ino, offset) -> Bytes`
- `encrypt_filename(name, dir_ino) -> String`
- `decrypt_filename(name, dir_ino) -> String`

## Related
[inode.md](inode.md) · [dir.md](dir.md)
