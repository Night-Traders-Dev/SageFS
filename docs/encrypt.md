# Encryption Layer
**Module:** [`src/encrypt.sage`](../src/encrypt.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Provides transparent per-directory or per-file encryption for both file data and filenames.

## Implementation Details
- **Data Encryption:** Uses AES-256-XTS with XTS tweak derived from block offsets.
- **Filename Encryption:** Uses AES-256-CTS (Ciphertext Stealing) to preserve filename lengths.
- Inode keys are derived via Argon2/PBKDF2 from a master key plus salt.

## API
- `derive_inode_key(ino) -> String`
- `encrypt_data(data, ino, offset) -> Bytes`
- `decrypt_data(data, ino, offset) -> Bytes`
- `encrypt_filename(name, dir_ino) -> String`
- `decrypt_filename(name, dir_ino) -> String`

## Related
[inode.md](inode.md) · [dir.md](dir.md)
