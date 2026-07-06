# Jigsaw AES-GCM datapath

This document describes the streaming interface of the AES-GCM engine
(`rtl/jigsaw_modules/aes_gcm_stream.v`), how data must be fed into it at
each level of the design, and how software prepares data that will pass
through it. The reference implementations are the unit testbenches in
`tb/aes_gcm_stream/` and `run_test_nic` in
`tb/mqnic_core_pcie_us/test_mqnic_core_pcie_us.py`.

## 1. The streaming engine: `aes_gcm_stream`

The engine is a free-running AES-256-GCM stream processor. It has no
per-packet control interface at all — no key/IV load strobes, no init
handshake, no mode changes. Everything is inferred from the data stream
itself: a packet is a run of beats ending in `tlast`, and each packet
automatically gets the next IV in the engine's lane (see §3). After the
one-time post-reset warmup the engine accepts one 128-bit beat per cycle
indefinitely, across packet boundaries, with no gaps required between
packets.

### Parameters

| Parameter | Meaning |
|---|---|
| `KEY` (256 bit) | AES-256 key, fixed at elaboration (zero in this PoC) |
| `IV_INIT` (96 bit) | IV of this engine's first packet after reset |
| `IV_STRIDE` (96 bit) | IV increment per packet |

### Input stream (`s_*`)

Standard valid/ready handshake, 128 bits per beat, **big-endian domain**:
byte 0 of the packet is bits `[127:120]`. `s_tbval` is a byte-valid mask
that must be **contiguous from the MSB** (`0x8000` = 1 byte … `0xFFFF` =
16 bytes); only the final beat of a packet may be partial. `s_tlast`
marks the last beat. That is the entire protocol:

- **Encryption** (`enc_dec = 0`): feed plaintext beats.
- **Decryption** (`enc_dec = 1`): feed ciphertext beats. The received
  tag must **not** be fed to the engine — strip it first (the decrypt
  wrapper does this, §2).

`s_tready` deasserts by itself whenever the engine needs a slot for
internal work (the one-cycle J0 injection at each packet start, pipe
backpressure, post-reset warmup). Producers need no knowledge of any of
this — just honour ready.

### Output stream (`m_*`)

Same conventions. For each input packet the engine emits its processed
data beats (ciphertext when encrypting, plaintext when decrypting, same
lengths and `bval`s as the input) followed by exactly one **tag beat**:
16 bytes, flagged with `m_is_tag` and carrying `m_tlast`. Output data for
beat *k* appears ~56 cycles (the AES pipe transit) plus any queueing
after beat *k* was accepted; this is latency only, throughput is one
beat per cycle. Several packets can be in flight inside the engine at
once; output packets always appear in input order.

### Reset and warmup

After `rst` the engine loads the key and streams 64 internal warmup
blocks through the AES pipe (the generated core's key expansion only
advances while blocks flow continuously). Until this finishes
(~150 cycles) `s_tready` stays low; no external sequencing is needed.

## 2. The frame-level wrappers

`aes_gcm_encryption.v` / `aes_gcm_decryption.v` adapt the engine to the
little-endian AXI-Stream used by the rest of the design (`tdata`/`tkeep`
in LE byte order, `tkeep` contiguous from bit 0) and fix the frame
formats:

- **Encrypt wrapper** — in: plaintext frame; out: ciphertext beats
  followed by the 16-byte tag beat (`tlast`). I.e. output frame =
  `ciphertext || tag`.
- **Decrypt wrapper** — in: frame whose **first beat is the 16-byte
  received tag**, followed by ciphertext beats (frame = `tag ||
  ciphertext`). The wrapper strips and queues the tag, feeds the
  ciphertext to the engine, and outputs the plaintext beats followed by
  an empty (`tkeep = 0`) `tlast` beat. `ghash_tag_val` pulses with that
  final beat iff the computed tag matches the received one; downstream
  (the per-engine FIFO credits in `jigsaw_pkt_processor.v`) releases the
  frame only on a match.

## 3. IV schedule across the engine bank

`jigsaw_pkt_processor.v` stripes frames round-robin over
`NUM_AES_ENGINES` (default 4) engines per direction and collects them in
the same rotation, preserving frame order. Engine `n` is instantiated
with `IV_INIT = n`, `IV_STRIDE = N` (receive) or `IV_INIT = 2^95 + n`
(transmit — the MSB is a direction bit so the two directions never share
an IV under the common key). Since engine `n` receives frames
`n, n+N, n+2N, …`, the bank as a whole consumes IVs `0, 1, 2, …` in
global frame order: **the IV of a frame is its index in the direction's
frame sequence since reset**. No IV travels in-band.

This is what makes the IV schedule *positional*, and it is the one
property software must respect end to end. It also assumes the link
delivers frames in order and without loss; a dropped or reordered frame
desynchronises all subsequent IVs in that direction until the NIC is
reset. A production design would carry an explicit IV/sequence number in
the frame header instead.

## 4. Preparing data in software

Software talking to the NIC must produce, for every frame it sends, a
standard AES-256-GCM encryption that the decrypt bank will accept:

| Parameter | Value |
|---|---|
| Cipher | AES-256-GCM |
| Key | 32 zero bytes (PoC) |
| IV | 12 bytes big-endian: frame index since reset (see §3) |
| AAD | none |
| Tag | 16 bytes, prepended (`frame = tag || ciphertext`) |

and, for every response it receives, verify a GCM decryption with the
transmit-side IV (`2^95 | response_index`) and the tag taken from the
**end** of the frame (`frame = ciphertext || tag`).

Rules that follow from the hardware:

1. **Count every frame you send** — frames that produce no response
   still consume a receive-side IV.
2. **Never send a frame with a bad tag.** Unreleased frames stay
   quarantined in their engine's FIFO and stall the in-order collector;
   recovery requires a reset.
3. **Sizes:** ≥ 1 byte of ciphertext after the tag (tag-only frames are
   not processed), ≤ NIC MTU (9214 B; the engine itself handles up to
   64 KB per packet — within a packet every 128-bit block simply
   continues the CTR counter, so large packets need nothing special).
4. **On NIC reset,** reset both IV counters to zero.

The payload *content* is opaque to the crypto path. In jigsaw the
plaintext happens to be an MMIO transaction —
`OP(1B, 0=read/1=write) || ADDR(8B LE) || LEN(8B LE) || DATA(LEN B,
writes only)`, with read responses containing the read data only (see
`txn_generator.v`) — but the engines encrypt/decrypt any byte stream.

### Reference implementation (Python)

```python
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
import itertools

KEY = bytes(32)                      # PoC key: all zero
rx_iv = itertools.count()            # host -> NIC frames (every frame)
tx_iv = itertools.count()            # NIC -> host responses

def _gcm(iv_int):
    return Cipher(algorithms.AES(KEY),
                  modes.GCM(iv_int.to_bytes(12, 'big')),
                  backend=default_backend())

def make_frame(plaintext: bytes) -> bytes:
    enc = _gcm(next(rx_iv)).encryptor()
    ct = enc.update(plaintext) + enc.finalize()
    return enc.tag + ct              # tag FIRST on the way in

def parse_response(frame: bytes) -> bytes:
    ct, tag = frame[:-16], frame[-16:]   # tag LAST on the way out
    dec = _gcm((1 << 95) | next(tx_iv)).decryptor()
    return dec.update(ct) + dec.finalize_with_tag(tag)
```

## 5. PoC limitations

- Fixed all-zero key (elaboration-time parameter, no runtime load path).
- Positional IVs require a lossless, in-order link.
- A failed request tag stalls the decrypt path until reset.
- Per-packet ciphertext limited to 64 KB (16-bit length accumulator).
