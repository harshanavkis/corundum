import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

KEY = bytes(32)


def model_encrypt(pt: bytes, iv_int: int):
    iv = iv_int.to_bytes(12, "big")
    enc = Cipher(algorithms.AES(KEY), modes.GCM(iv), backend=default_backend()).encryptor()
    ct = enc.update(pt) + enc.finalize()
    return ct, enc.tag


async def sender(dut, payloads):
    """Drive all packets back-to-back with no inter-packet waits."""
    for payload in payloads:
        beats = [payload[i:i + 16] for i in range(0, len(payload), 16)]
        idx = 0
        while idx < len(beats):
            beat = beats[idx]
            dut.aes_in_tdata.value = int.from_bytes(beat.ljust(16, b"\x00"), "little")
            dut.aes_in_tkeep.value = (1 << len(beat)) - 1
            dut.aes_in_tvalid.value = 1
            dut.aes_in_tlast.value = 1 if idx == len(beats) - 1 else 0
            await RisingEdge(dut.clk)
            if dut.aes_in_tready.value:
                idx += 1
    dut.aes_in_tvalid.value = 0
    dut.aes_in_tlast.value = 0


async def receiver(dut, n_frames):
    """Collect n_frames output frames (data beats + tag beat with tlast)."""
    frames = []
    cur = []
    for _ in range(40000):
        await RisingEdge(dut.clk)
        if dut.aes_out_tvalid.value:
            nbytes = bin(int(dut.aes_out_tkeep.value)).count("1")
            raw = int(dut.aes_out_tdata.value).to_bytes(16, "little")[:nbytes]
            cur.append(raw)
            if int(dut.aes_out_tlast.value):
                frames.append(b"".join(cur))
                cur = []
                if len(frames) == n_frames:
                    return frames
    raise AssertionError(f"timeout: got {len(frames)}/{n_frames} frames")


@cocotb.test()
async def multi_packet_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())

    dut.aes_in_tvalid.value = 0
    dut.aes_in_tlast.value = 0
    dut.aes_in_tuser.value = 0
    dut.aes_out_tready.value = 1
    dut.enc_dec.value = 0

    dut.rst.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # allow one-time init (key load + H through the pipe)
    for _ in range(200):
        await RisingEdge(dut.clk)

    # includes a 100000-byte packet crossing the old 64 KiB length-counter limit
    payloads = [b"\x11" * 8, b"\x22" * 8, bytes(range(16)), b"\x55" * 40,
                bytes(range(256)) * 391 + b"\xAB" * 104]  # 100200 bytes

    recv = cocotb.start_soon(receiver(dut, len(payloads)))
    send = cocotb.start_soon(sender(dut, payloads))

    t0 = cocotb.utils.get_sim_time("ns")
    frames = await recv
    t1 = cocotb.utils.get_sim_time("ns")

    for n, (pt, frame) in enumerate(zip(payloads, frames)):
        exp_ct, exp_tag = model_encrypt(pt, n)
        ct, tag = frame[:-16], frame[-16:]
        dut._log.info(f"pkt {n}: len={len(pt)} iv={n} ct_ok={ct == exp_ct} tag_ok={tag == exp_tag}")
        assert ct == exp_ct, f"pkt {n}: CT mismatch: {ct.hex()} != {exp_ct.hex()}"
        assert tag == exp_tag, f"pkt {n}: TAG mismatch: {tag.hex()} != {exp_tag.hex()}"

    total_beats = sum((len(p) + 15) // 16 for p in payloads)
    cycles = (t1 - t0) / 4
    dut._log.info(f"5 packets, {total_beats} data beats, {cycles:.0f} cycles total "
                  f"({cycles / len(payloads):.1f} cycles/pkt incl. one-time latency)")


@cocotb.test()
async def two_64k_packets(dut):
    """Two back-to-back 64 KiB packets: the second tag verifies only if
    the engine advanced its IV across the packet boundary, and 65536
    bytes exercises the length accumulator just past the 16-bit mark."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())

    dut.aes_in_tvalid.value = 0
    dut.aes_in_tlast.value = 0
    dut.aes_in_tuser.value = 0
    dut.aes_out_tready.value = 1
    dut.enc_dec.value = 0

    dut.rst.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(200):
        await RisingEdge(dut.clk)

    payloads = [bytes(range(256)) * 256, bytes(range(255, -1, -1)) * 256]  # 2 x 65536 B

    recv = cocotb.start_soon(receiver(dut, len(payloads)))
    cocotb.start_soon(sender(dut, payloads))
    frames = await recv

    for n, (pt, frame) in enumerate(zip(payloads, frames)):
        exp_ct, exp_tag = model_encrypt(pt, n)
        ct, tag = frame[:-16], frame[-16:]
        dut._log.info(f"64k pkt {n}: iv={n} ct_ok={ct == exp_ct} tag_ok={tag == exp_tag}")
        assert ct == exp_ct, f"pkt {n}: CT mismatch"
        assert tag == exp_tag, f"pkt {n}: TAG mismatch (IV not advanced across packets?)"
