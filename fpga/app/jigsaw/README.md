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
   not processed), ≤ NIC MTU (9214 B). The crypto path itself handles up
   to **1 MiB of ciphertext per packet** (see §5) — within a packet
   every 128-bit block simply continues the CTR counter, so large
   packets need nothing special from software.
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
- **Per-packet ciphertext is limited to 1 MiB.** The engine's length
  accumulator is sized for 1 MiB (GCM itself would allow ~64 GiB), but
  the binding constraint is architectural: the decrypt path releases a
  frame only after its tag verifies, and the tag is only known at the
  end of the frame, so the *entire* decrypted frame is buffered in its
  engine's output FIFO before the first byte leaves. Those FIFOs are
  sized 2 MiB each to cover the limit — substantial block RAM per
  engine on a real FPGA, and the cost scales linearly with the maximum
  frame size. A frame exceeding the limit wraps the length counter
  (guaranteed authentication failure) and can deadlock its decrypt
  engine on the full FIFO — do not send one. Raising the limit further
  means either more FIFO memory or moving to cut-through release with a
  late-abort contract downstream.

## 6. Expected throughput

Each engine processes one 128-bit block per cycle, continuously across
packet boundaries (the AES pipe is never drained; its 56-cycle transit
is latency, not throughput). The per-packet overhead is one J0 slot on
the input side plus one GHASH length cycle and one tag beat on the
output side, so for a packet of `m` 128-bit beats:

```
engine goodput   ≈ f_clk × 128 bit × m / (m + 3)        (worst case)
aggregate        ≈ N_engines × engine goodput, capped by the bus
bus capacity     = f_clk × 512 bit                (128 Gb/s @ 250 MHz)
```

Measured in the unit TB (cycle-accurate, frequency-independent):
5 back-to-back packets totalling 6269 data beats completed in 6336
cycles — **98.9 % duty**, i.e. per-packet overhead ≈ 2 slots in
practice, slightly better than the m+3 model.

Projected at 250 MHz with the default 4 engines (m+3 model):

| Payload | m (beats) | duty | aggregate | vs 100G line rate |
|---|---|---|---|---|
| 33 B (jigsaw MMIO) | 3 | 50 % | 64 Gb/s | 148 Mpps capacity vs 148.8 needed: marginal |
| 64 B | 4 | 57 % | 73 Gb/s | marginal at worst case, OK at measured overhead |
| 256 B | 16 | 84 % | 108 Gb/s | line rate |
| 512 B | 32 | 91 % | 117 Gb/s | line rate |
| 1500 B | 94 | 97 % | 124 Gb/s | line rate |
| 9 KB jumbo | 576 | 99.5 % | 127 Gb/s | line rate (bus-capped) |

Notes:

- **Min-size packets are the marginal case:** 4 engines deliver
  ~143–167 Mpps (worst-case vs measured overhead) against the 148.8 Mpps
  that 64-byte line rate demands. For guaranteed headroom set
  `NUM_AES_ENGINES = 8` (one parameter in `jigsaw_pkt_processor`).
- **Single flow:** one packet passes through one engine, so a single
  large packet/flow is bounded by one 128-bit lane, 32 Gb/s @ 250 MHz.
  Exceeding that needs a wider (multi-lane) core, not more engines.
- **Latency:** ~56 cycles AES transit (224 ns @ 250 MHz) plus adapters
  and FIFOs on the encrypt path; the decrypt path additionally buffers
  each full frame until its tag verifies (store-and-forward), adding one
  frame time.
- **All bit-rates assume the pipe-7 core closes 250 MHz.** This is the
  reason the core is generated with 4 register stages per round, but it
  has not yet been confirmed by synthesis; throughput scales linearly
  with the actual Fmax. The duty-cycle figures are cycle-accurate and
  hold at any frequency.

## 7. Running the AES-GCM tests standalone

All simulations use Icarus Verilog + cocotb. The expected environment is
the project nix shell, which provides iverilog, cocotb, and the
`cryptography`/`pycryptodome` packages used by the reference models:

```sh
nix-shell <jigsaw-ns>/corundum-stuff/default.nix
```

### Engine unit tests (fast, run these while developing)

These exercise the encrypt/decrypt wrappers plus the full `aes_gcm_stream`
engine directly — no NIC, no PCIe — and check every ciphertext, plaintext
and tag against the Python `cryptography` GCM model:

```sh
cd fpga/app/jigsaw/tb/aes_gcm_stream

# encryption: back-to-back packets with incrementing IVs, partial final
# blocks, a >64 KiB packet, a throughput report (cycles/packet), and two
# back-to-back 64 KiB packets verifying IV continuity across packets
make

# decryption: tag stripping/queueing, multiple packets in flight,
# ghash_tag_val per packet, corrupted-tag rejection
make TOPLEVEL=aes_gcm_decryption MODULE=test_aes_dec_unit
```

Results are printed as a cocotb summary table; `make` exits non-zero on
failure. Remove `sim_build/` when switching between the two targets so
the right toplevel is elaborated. Compilation of the generated AES
netlist (`top_aes_gcm.v`, ~35 MB) dominates the run time; the large-packet
encryption test additionally simulates ~100 KiB of traffic and takes
several minutes under Icarus.

### Full end-to-end test

The complete NIC simulation (PCIe host model, driver bring-up, MAC
loopback) sends encrypted MMIO write/read transactions through all four
decrypt and encrypt engines, including rotation wrap-around and the
positional IV schedule of §3:

```sh
cd fpga/app/jigsaw/tb/mqnic_core_pcie_us
make
```

This is the slowest test (roughly ten minutes); use it as the final
regression, not the development loop. The verdict is in the cocotb table
and in `results.xml` (a `<failure>` element means a failed run).

### Upstream core tests

The generated AES core itself (`top_aes_gcm.v`) has its own randomized
testbench with NIST-vector support in the vendored source repository
(`AES-GCM-128-192-256-bits/verilog-tb`, outside this tree); regenerate
and re-verify there when changing the core's VHDL, then copy the fresh
netlist into `rtl/jigsaw_modules/`.
