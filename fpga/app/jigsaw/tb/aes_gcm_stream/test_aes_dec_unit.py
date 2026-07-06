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


async def sender(dut, frames):
    for frame in frames:
        beats = [frame[i:i + 16] for i in range(0, len(frame), 16)]
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
    frames = []
    pulses = []
    cur = []
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if dut.aes_out_tvalid.value:
            if int(dut.ghash_tag_val.value):
                pulses.append(len(frames))
            nbytes = bin(int(dut.aes_out_tkeep.value)).count("1")
            raw = int(dut.aes_out_tdata.value).to_bytes(16, "little")[:nbytes]
            if int(dut.aes_out_tlast.value):
                frames.append(b"".join(cur))
                cur = []
                if len(frames) == n_frames:
                    return frames, pulses
            else:
                cur.append(raw)
    raise AssertionError(f"timeout: got {len(frames)}/{n_frames} frames")


@cocotb.test()
async def multi_packet_decrypt(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())

    dut.aes_in_tvalid.value = 0
    dut.aes_in_tlast.value = 0
    dut.aes_in_tuser.value = 0
    dut.aes_out_tready.value = 1
    dut.enc_dec.value = 1

    dut.rst.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(200):
        await RisingEdge(dut.clk)

    payloads = [b"\x11" * 8, b"\x22" * 24, bytes(range(16)), b"\x55" * 40]
    corrupt = 2  # packet with a bad tag: PT still comes out, no tag pulse

    frames = []
    for n, pt in enumerate(payloads):
        ct, tag = model_encrypt(pt, n)
        if n == corrupt:
            tag = bytes(16)
        frames.append(tag + ct)

    recv = cocotb.start_soon(receiver(dut, len(payloads)))
    cocotb.start_soon(sender(dut, frames))
    out_frames, pulses = await recv

    for n, (pt, frame) in enumerate(zip(payloads, out_frames)):
        ok = frame == pt
        dut._log.info(f"pkt {n}: len={len(pt)} pt_ok={ok} tag_pulse={n in pulses}")
        assert ok, f"pkt {n}: PT mismatch: {frame.hex()} != {pt.hex()}"

    expected_pulses = [n for n in range(len(payloads)) if n != corrupt]
    assert pulses == expected_pulses, f"tag pulses {pulses} != {expected_pulses}"
    dut._log.info(f"tag pulses OK: {pulses} (packet {corrupt} correctly rejected)")
