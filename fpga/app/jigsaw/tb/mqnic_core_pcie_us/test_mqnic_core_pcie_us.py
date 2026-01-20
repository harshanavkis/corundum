# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2021-2023 The Regents of the University of California

import logging
import os
import struct
import sys

import scapy.utils
from scapy.layers.l2 import Ether
from scapy.layers.inet import IP, UDP

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.log import SimLog
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from cocotbext.axi import AxiStreamBus
from cocotbext.axi import AxiSlave, AxiBus, SparseMemoryRegion
from cocotbext.eth import EthMac
from cocotbext.pcie.core import RootComplex
from cocotbext.pcie.xilinx.us import UltraScalePlusPcieDevice

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

from bitarray import bitarray
import random

try:
    import mqnic
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        import mqnic
    finally:
        del sys.path[0]


class TB(object):
    def __init__(self, dut, msix_count=32):
        self.dut = dut

        self.log = SimLog("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        # PCIe
        self.rc = RootComplex()

        self.rc.max_payload_size = 0x1  # 256 bytes
        self.rc.max_read_request_size = 0x2  # 512 bytes

        self.dev = UltraScalePlusPcieDevice(
            # configuration options
            pcie_generation=3,
            # pcie_link_width=16,
            user_clk_frequency=250e6,
            alignment="dword",
            cq_straddle=len(dut.pcie_if_inst.pcie_us_if_cq_inst.rx_req_tlp_valid_reg) > 1,
            cc_straddle=len(dut.pcie_if_inst.pcie_us_if_cc_inst.out_tlp_valid) > 1,
            rq_straddle=len(dut.pcie_if_inst.pcie_us_if_rq_inst.out_tlp_valid) > 1,
            rc_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 1,
            rc_4tlp_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 2,
            pf_count=1,
            max_payload_size=1024,
            enable_client_tag=True,
            enable_extended_tag=True,
            enable_parity=False,
            enable_rx_msg_interface=False,
            enable_sriov=False,
            enable_extended_configuration=False,

            pf0_msi_enable=False,
            pf0_msi_count=32,
            pf1_msi_enable=False,
            pf1_msi_count=1,
            pf2_msi_enable=False,
            pf2_msi_count=1,
            pf3_msi_enable=False,
            pf3_msi_count=1,
            pf0_msix_enable=True,
            pf0_msix_table_size=msix_count-1,
            pf0_msix_table_bir=0,
            pf0_msix_table_offset=0x00010000,
            pf0_msix_pba_bir=0,
            pf0_msix_pba_offset=0x00018000,
            pf1_msix_enable=False,
            pf1_msix_table_size=0,
            pf1_msix_table_bir=0,
            pf1_msix_table_offset=0x00000000,
            pf1_msix_pba_bir=0,
            pf1_msix_pba_offset=0x00000000,
            pf2_msix_enable=False,
            pf2_msix_table_size=0,
            pf2_msix_table_bir=0,
            pf2_msix_table_offset=0x00000000,
            pf2_msix_pba_bir=0,
            pf2_msix_pba_offset=0x00000000,
            pf3_msix_enable=False,
            pf3_msix_table_size=0,
            pf3_msix_table_bir=0,
            pf3_msix_table_offset=0x00000000,
            pf3_msix_pba_bir=0,
            pf3_msix_pba_offset=0x00000000,

            # signals
            # Clock and Reset Interface
            user_clk=dut.clk,
            user_reset=dut.rst,
            # user_lnk_up
            # sys_clk
            # sys_clk_gt
            # sys_reset
            # phy_rdy_out

            # Requester reQuest Interface
            rq_bus=AxiStreamBus.from_prefix(dut, "m_axis_rq"),
            pcie_rq_seq_num0=dut.s_axis_rq_seq_num_0,
            pcie_rq_seq_num_vld0=dut.s_axis_rq_seq_num_valid_0,
            pcie_rq_seq_num1=dut.s_axis_rq_seq_num_1,
            pcie_rq_seq_num_vld1=dut.s_axis_rq_seq_num_valid_1,
            # pcie_rq_tag0
            # pcie_rq_tag1
            # pcie_rq_tag_av
            # pcie_rq_tag_vld0
            # pcie_rq_tag_vld1

            # Requester Completion Interface
            rc_bus=AxiStreamBus.from_prefix(dut, "s_axis_rc"),

            # Completer reQuest Interface
            cq_bus=AxiStreamBus.from_prefix(dut, "s_axis_cq"),
            # pcie_cq_np_req
            # pcie_cq_np_req_count

            # Completer Completion Interface
            cc_bus=AxiStreamBus.from_prefix(dut, "m_axis_cc"),

            # Transmit Flow Control Interface
            # pcie_tfc_nph_av=dut.pcie_tfc_nph_av,
            # pcie_tfc_npd_av=dut.pcie_tfc_npd_av,

            # Configuration Management Interface
            cfg_mgmt_addr=dut.cfg_mgmt_addr,
            cfg_mgmt_function_number=dut.cfg_mgmt_function_number,
            cfg_mgmt_write=dut.cfg_mgmt_write,
            cfg_mgmt_write_data=dut.cfg_mgmt_write_data,
            cfg_mgmt_byte_enable=dut.cfg_mgmt_byte_enable,
            cfg_mgmt_read=dut.cfg_mgmt_read,
            cfg_mgmt_read_data=dut.cfg_mgmt_read_data,
            cfg_mgmt_read_write_done=dut.cfg_mgmt_read_write_done,
            # cfg_mgmt_debug_access

            # Configuration Status Interface
            # cfg_phy_link_down
            # cfg_phy_link_status
            # cfg_negotiated_width
            # cfg_current_speed
            cfg_max_payload=dut.cfg_max_payload,
            cfg_max_read_req=dut.cfg_max_read_req,
            # cfg_function_status
            # cfg_vf_status
            # cfg_function_power_state
            # cfg_vf_power_state
            # cfg_link_power_state
            # cfg_err_cor_out
            # cfg_err_nonfatal_out
            # cfg_err_fatal_out
            # cfg_local_error_out
            # cfg_local_error_valid
            # cfg_rx_pm_state
            # cfg_tx_pm_state
            # cfg_ltssm_state
            cfg_rcb_status=dut.cfg_rcb_status,
            # cfg_obff_enable
            # cfg_pl_status_change
            # cfg_tph_requester_enable
            # cfg_tph_st_mode
            # cfg_vf_tph_requester_enable
            # cfg_vf_tph_st_mode

            # Configuration Received Message Interface
            # cfg_msg_received
            # cfg_msg_received_data
            # cfg_msg_received_type

            # Configuration Transmit Message Interface
            # cfg_msg_transmit
            # cfg_msg_transmit_type
            # cfg_msg_transmit_data
            # cfg_msg_transmit_done

            # Configuration Flow Control Interface
            cfg_fc_ph=dut.cfg_fc_ph,
            cfg_fc_pd=dut.cfg_fc_pd,
            cfg_fc_nph=dut.cfg_fc_nph,
            cfg_fc_npd=dut.cfg_fc_npd,
            cfg_fc_cplh=dut.cfg_fc_cplh,
            cfg_fc_cpld=dut.cfg_fc_cpld,
            cfg_fc_sel=dut.cfg_fc_sel,

            # Configuration Control Interface
            # cfg_hot_reset_in
            # cfg_hot_reset_out
            # cfg_config_space_enable
            # cfg_dsn
            # cfg_bus_number
            # cfg_ds_port_number
            # cfg_ds_bus_number
            # cfg_ds_device_number
            # cfg_ds_function_number
            # cfg_power_state_change_ack
            # cfg_power_state_change_interrupt
            cfg_err_cor_in=dut.status_error_cor,
            cfg_err_uncor_in=dut.status_error_uncor,
            # cfg_flr_in_process
            # cfg_flr_done
            # cfg_vf_flr_in_process
            # cfg_vf_flr_func_num
            # cfg_vf_flr_done
            # cfg_pm_aspm_l1_entry_reject
            # cfg_pm_aspm_tx_l0s_entry_disable
            # cfg_req_pm_transition_l23_ready
            # cfg_link_training_enable

            # Configuration Interrupt Controller Interface
            # cfg_interrupt_int
            # cfg_interrupt_sent
            # cfg_interrupt_pending
            # cfg_interrupt_msi_enable
            # cfg_interrupt_msi_mmenable
            # cfg_interrupt_msi_mask_update
            # cfg_interrupt_msi_data
            # cfg_interrupt_msi_select
            # cfg_interrupt_msi_int
            # cfg_interrupt_msi_pending_status
            # cfg_interrupt_msi_pending_status_data_enable
            # cfg_interrupt_msi_pending_status_function_num
            # cfg_interrupt_msi_sent
            # cfg_interrupt_msi_fail
            cfg_interrupt_msix_enable=dut.cfg_interrupt_msix_enable,
            cfg_interrupt_msix_mask=dut.cfg_interrupt_msix_mask,
            cfg_interrupt_msix_vf_enable=dut.cfg_interrupt_msix_vf_enable,
            cfg_interrupt_msix_vf_mask=dut.cfg_interrupt_msix_vf_mask,
            cfg_interrupt_msix_address=dut.cfg_interrupt_msix_address,
            cfg_interrupt_msix_data=dut.cfg_interrupt_msix_data,
            cfg_interrupt_msix_int=dut.cfg_interrupt_msix_int,
            cfg_interrupt_msix_vec_pending=dut.cfg_interrupt_msix_vec_pending,
            cfg_interrupt_msix_vec_pending_status=dut.cfg_interrupt_msix_vec_pending_status,
            cfg_interrupt_msix_sent=dut.cfg_interrupt_msix_sent,
            cfg_interrupt_msix_fail=dut.cfg_interrupt_msix_fail,
            # cfg_interrupt_msi_attr
            # cfg_interrupt_msi_tph_present
            # cfg_interrupt_msi_tph_type
            # cfg_interrupt_msi_tph_st_tag
            cfg_interrupt_msi_function_number=dut.cfg_interrupt_msi_function_number,

            # Configuration Extend Interface
            # cfg_ext_read_received
            # cfg_ext_write_received
            # cfg_ext_register_number
            # cfg_ext_function_number
            # cfg_ext_write_data
            # cfg_ext_write_byte_enable
            # cfg_ext_read_data
            # cfg_ext_read_data_valid
        )

        # self.dev.log.setLevel(logging.DEBUG)

        self.rc.make_port().connect(self.dev)

        self.driver = mqnic.Driver()

        self.dev.functions[0].configure_bar(0, 2**len(dut.core_pcie_inst.axil_ctrl_araddr), ext=True, prefetch=True)
        if hasattr(dut.core_pcie_inst, 'pcie_app_ctrl'):
            self.dev.functions[0].configure_bar(2, 2**len(dut.core_pcie_inst.axil_app_ctrl_araddr), ext=True, prefetch=True)

        core_inst = dut.core_pcie_inst.core_inst

        # Ethernet
        self.port_mac = []

        eth_int_if_width = len(core_inst.m_axis_tx_tdata) / len(core_inst.m_axis_tx_tvalid)
        eth_clock_period = 6.4
        eth_speed = 10e9

        if eth_int_if_width == 64:
            # 10G
            eth_clock_period = 6.4
            eth_speed = 10e9
        elif eth_int_if_width == 128:
            # 25G
            eth_clock_period = 2.56
            eth_speed = 25e9
        elif eth_int_if_width == 512:
            # 100G
            eth_clock_period = 3.102
            eth_speed = 100e9

        for iface in core_inst.iface:
            for k in range(len(iface.port)):
                cocotb.start_soon(Clock(iface.port[k].port_rx_clk, eth_clock_period, units="ns").start())
                cocotb.start_soon(Clock(iface.port[k].port_tx_clk, eth_clock_period, units="ns").start())

                iface.port[k].port_rx_rst.setimmediatevalue(0)
                iface.port[k].port_tx_rst.setimmediatevalue(0)

                mac = EthMac(
                    tx_clk=iface.port[k].port_tx_clk,
                    tx_rst=iface.port[k].port_tx_rst,
                    tx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_tx_inst, "m_axis_tx"),
                    tx_ptp_time=iface.port[k].port_tx_ptp_ts_tod,
                    tx_ptp_ts=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_ts,
                    tx_ptp_ts_tag=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_tag,
                    tx_ptp_ts_valid=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_valid,
                    rx_clk=iface.port[k].port_rx_clk,
                    rx_rst=iface.port[k].port_rx_rst,
                    rx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_rx_inst, "s_axis_rx"),
                    rx_ptp_time=iface.port[k].port_rx_ptp_ts_tod,
                    ifg=12, speed=eth_speed
                )

                self.port_mac.append(mac)

        dut.eth_tx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_tx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_lfc_req.setimmediatevalue(0)
        dut.eth_rx_pfc_req.setimmediatevalue(0)
        dut.eth_rx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)

        # DDR
        self.ddr_group_size = core_inst.DDR_GROUP_SIZE.value
        self.ddr_ram = []
        self.ddr_axi_if = []
        if hasattr(core_inst, 'ddr'):
            ram = None
            for i, ch in enumerate(core_inst.ddr.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 3.332, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.ddr_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.ddr_ram.append(ram)
                self.ddr_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        # HBM
        self.hbm_group_size = core_inst.HBM_GROUP_SIZE.value
        self.hbm_ram = []
        self.hbm_axi_if = []
        if hasattr(core_inst, 'hbm'):
            ram = None
            for i, ch in enumerate(core_inst.hbm.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 2.222, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.hbm_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.hbm_ram.append(ram)
                self.hbm_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        dut.ctrl_reg_wr_wait.setimmediatevalue(0)
        dut.ctrl_reg_wr_ack.setimmediatevalue(0)
        dut.ctrl_reg_rd_data.setimmediatevalue(0)
        dut.ctrl_reg_rd_wait.setimmediatevalue(0)
        dut.ctrl_reg_rd_ack.setimmediatevalue(0)

        cocotb.start_soon(Clock(dut.ptp_clk, 6.4, units="ns").start())
        dut.ptp_rst.setimmediatevalue(0)
        cocotb.start_soon(Clock(dut.ptp_sample_clk, 8, units="ns").start())

        dut.s_axis_stat_tdata.setimmediatevalue(0)
        dut.s_axis_stat_tid.setimmediatevalue(0)
        dut.s_axis_stat_tvalid.setimmediatevalue(0)

        self.loopback_enable = False
        cocotb.start_soon(self._run_loopback())

    async def init(self):

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(1)
            mac.tx.reset.setimmediatevalue(1)

        self.dut.ptp_rst.setimmediatevalue(1)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(1)

        await FallingEdge(self.dut.rst)
        await Timer(100, 'ns')

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await self.rc.enumerate()

    async def _run_loopback(self):
        while True:
            await RisingEdge(self.dut.clk)

            if self.loopback_enable:
                for mac in self.port_mac:
                    if not mac.tx.empty():
                        await mac.rx.send(await mac.tx.recv())

def jigsaw_pkt_generator(jigsaw_id_width, jigsaw_op_width, jigsaw_addr_width, jigsaw_len_width, jigsaw_data_width):
    id_bits = bitarray([random.choice([0, 1]) for _ in range(jigsaw_id_width)])
    op_bits = bitarray([random.choice([0, 1]) for _ in range(jigsaw_op_width)])
    addr_bits = bitarray([random.choice([0, 1]) for _ in range(jigsaw_addr_width)])
    # len_bits = bitarray([random.choice([0, 1]) for _ in range(jigsaw_len_width)])
    len_bits = bitarray(bin(int(jigsaw_data_width/8))[2:].zfill(jigsaw_len_width))
    data_bits = bitarray([random.choice([0, 1]) for _ in range(jigsaw_data_width)])

    payload_bits = bitarray()
    payload_bits.extend(id_bits)
    payload_bits.extend(op_bits)
    payload_bits.extend(addr_bits)
    payload_bits.extend(len_bits)
    payload_bits.extend(data_bits)

    rev_payload_header_bits = bitarray()
    rev_payload_header_bits.extend(len_bits)
    rev_payload_header_bits.extend(addr_bits)
    rev_payload_header_bits.extend(op_bits)
    rev_payload_header_bits.extend(id_bits)

    rev_payload_data_bits = bitarray()
    rev_payload_data_bits.extend(data_bits)

    return (payload_bits, rev_payload_header_bits, rev_payload_data_bits)

def int_to_bitarray(num, width):
    """Convert integer to bitarray of fixed width (MSB first)."""
    if num >= (1 << width) or num < 0:
        raise ValueError(f"Number {num} cannot fit in {width} bits.")
    bin_str = bin(num)[2:].zfill(width)
    return bitarray(bin_str)

def int_to_little_endian_bitarray(value, bit_length):
    num_bytes = bit_length // 8
    b = value.to_bytes(num_bytes, byteorder='little')
    bits = bitarray()
    bits.frombytes(b)
    return bits

def jigsaw_mmio_packet_gen(op, addr, data_len, data):
    op_bits = int_to_little_endian_bitarray(op, 8)
    addr_bits = int_to_little_endian_bitarray(addr, 64)
    len_bits = int_to_little_endian_bitarray(data_len, 64)
    data_bits = int_to_little_endian_bitarray(data, data_len*8)
    
    payload_bits = bitarray()
    payload_bits.extend(op_bits)
    payload_bits.extend(addr_bits)
    payload_bits.extend(len_bits)
    payload_bits.extend(data_bits)

    if op == 0:  # mmio read
        return bytearray(payload_bits), None

    if op == 1:  # mmio write
        return bytearray(payload_bits), bytearray(data_bits)

def jigsaw_mmio_emu(addr, len):
    if addr == 8:
        b = bitarray(len)
        b.setall(0)

        return bytearray(b)


async def jigsaw_mmio_read(tb, dut, pkt_proc, jhs, mmio_vaddr, reg_addr, verify_sq=True):
    """
    Perform an MMIO read operation.
    
    Args:
        tb: Test bench object
        dut: DUT object
        pkt_proc: jigsaw_pkt_processor instance
        jhs: jigsaw_host_side instance
        mmio_vaddr: Virtual address for MMIO
        reg_addr: Register address to read (0x00, 0x08, 0x10, etc.)
        verify_sq: Whether to verify SQ signals
    
    Returns:
        64-bit value read from the register
    """
    from cocotb.triggers import RisingEdge
    
    # Step 1: Set mmio_ctrl high to trigger the MMIO flow
    jhs.mmio_vaddr.value = mmio_vaddr
    jhs.mmio_ctrl.value = 1
    
    # Step 2: Wait for sq_valid_read and capture values
    while True:
        sq_valid = pkt_proc.sq_valid_read.value
        if sq_valid == 1:
            sq_addr = int(pkt_proc.sq_addr_read.value)
            sq_len = int(pkt_proc.sq_len_read.value)
            mmio_clear = pkt_proc.mmio_clear.value
            if mmio_clear == 1:
                jhs.mmio_ctrl.value = 0
            break
        await RisingEdge(dut.clk)
    
    # Verify SQ read values if requested
    if verify_sq:
        assert sq_addr == mmio_vaddr + 24, f"Expected sq_addr_read=0x{mmio_vaddr + 24:x}, got 0x{sq_addr:x}"
        assert sq_len == 25, f"Expected sq_len_read=25, got {sq_len}"
    
    # Step 3: Ensure mmio_ctrl is low, then send read request
    jhs.mmio_ctrl.value = 0
    await RisingEdge(dut.clk)
    
    # Step 4: Send MMIO read payload (op=0)
    send_payload, _ = jigsaw_mmio_packet_gen(0, reg_addr, 8, 0)
    await tb.port_mac[0].rx.send(send_payload)
    
    # Step 5: Wait for sq_valid_write and capture values (also check mmio_read_done)
    while True:
        sq_wr_valid = pkt_proc.sq_valid_write.value
        if sq_wr_valid == 1:
            sq_wr_addr = int(pkt_proc.sq_addr_write.value)
            sq_wr_len = int(pkt_proc.sq_len_write.value)
            mmio_rd_done = pkt_proc.mmio_read_done.value
            break
        await RisingEdge(dut.clk)
    
    # Verify SQ write values if requested
    if verify_sq:
        assert sq_wr_addr == mmio_vaddr + 16, f"Expected sq_addr_write=0x{mmio_vaddr + 16:x}, got 0x{sq_wr_addr:x}"
        assert sq_wr_len == 8, f"Expected sq_len_write=8, got {sq_wr_len}"
    
    # Verify mmio_read_done (always check)
    assert mmio_rd_done == 1, f"Expected mmio_read_done=1, got {mmio_rd_done}"
    
    # Step 6: Receive response
    echo_tx_pkt = await tb.port_mac[0].tx.recv()
    assert len(echo_tx_pkt.data) == 8, f"Expected 8 bytes, got {len(echo_tx_pkt.data)}"
    
    # Parse and return the value
    response_value = int.from_bytes(echo_tx_pkt.data[0:8], 'little')
    return response_value


async def jigsaw_mmio_write(tb, dut, pkt_proc, jhs, mmio_vaddr, reg_addr, value, verify_sq=True):
    """
    Perform an MMIO write operation.
    
    Args:
        tb: Test bench object
        dut: DUT object
        pkt_proc: jigsaw_pkt_processor instance
        jhs: jigsaw_host_side instance
        mmio_vaddr: Virtual address for MMIO
        reg_addr: Register address to write (0x00, 0x08, 0x10, etc.)
        value: 64-bit value to write
        verify_sq: Whether to verify SQ signals
    """
    from cocotb.triggers import RisingEdge
    
    # Step 1: Set mmio_ctrl high to trigger the MMIO flow
    jhs.mmio_vaddr.value = mmio_vaddr
    jhs.mmio_ctrl.value = 1
    
    # Step 2: Wait for sq_valid_read and capture values
    while True:
        sq_valid = pkt_proc.sq_valid_read.value
        if sq_valid == 1:
            sq_addr = int(pkt_proc.sq_addr_read.value)
            sq_len = int(pkt_proc.sq_len_read.value)
            mmio_clear = pkt_proc.mmio_clear.value
            if mmio_clear == 1:
                jhs.mmio_ctrl.value = 0
            break
        await RisingEdge(dut.clk)
    
    # Verify SQ read values if requested
    if verify_sq:
        assert sq_addr == mmio_vaddr + 24, f"Expected sq_addr_read=0x{mmio_vaddr + 24:x}, got 0x{sq_addr:x}"
        assert sq_len == 25, f"Expected sq_len_read=25, got {sq_len}"
    
    # Step 3: Ensure mmio_ctrl is low, then send write data
    jhs.mmio_ctrl.value = 0
    await RisingEdge(dut.clk)
    
    # Step 4: Send MMIO write payload (op=1)
    send_payload, _ = jigsaw_mmio_packet_gen(1, reg_addr, 8, value)
    await tb.port_mac[0].rx.send(send_payload)
    
    # Step 5: Wait for mmio_write_done to go high
    while True:
        mmio_wr_done = pkt_proc.mmio_write_done.value
        if mmio_wr_done == 1:
            break
        await RisingEdge(dut.clk)
    
    # Verify mmio_write_done (always check, not just when verify_sq is True)
    assert mmio_wr_done == 1, f"Expected mmio_write_done=1, got {mmio_wr_done}"


@cocotb.test()
async def run_test_nic(dut):

    tb = TB(dut, msix_count=2**len(dut.core_pcie_inst.irq_index))

    await tb.init()

    tb.log.info("Init driver")
    await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
    for interface in tb.driver.interfaces:
        await interface.open()

    tb.log.info("Init complete")

    tb.log.info("Jigsaw E2E")

    # Access internal signals from jigsaw_pkt_processor
    # Navigate through hierarchy: dut -> core_pcie_inst -> core_inst -> app (generate block) -> app_block_inst -> pkt_proc
    core_inst = dut.core_pcie_inst.core_inst
    
    # Access jigsaw_pkt_processor instance (inside app generate block)
    # The app_block is inside a generate block named 'app'
    try:
        pkt_proc = core_inst.app.app_block_inst.pkt_proc
        
        # Log internal wire values
        tb.log.info("=== Jigsaw Internal Signals ===")
        
        # Network to txn_generator interface
        tb.log.info(f"network_to_txn_tvalid: {pkt_proc.network_to_txn_tvalid.value}")
        tb.log.info(f"network_to_txn_tready: {pkt_proc.network_to_txn_tready.value}")
        tb.log.info(f"network_to_txn_tlast: {pkt_proc.network_to_txn_tlast.value}")
        
        # Txn_generator to network interface  
        tb.log.info(f"txn_to_network_tvalid: {pkt_proc.txn_to_network_tvalid.value}")
        tb.log.info(f"txn_to_network_tready: {pkt_proc.txn_to_network_tready.value}")
        tb.log.info(f"txn_to_network_tlast: {pkt_proc.txn_to_network_tlast.value}")
        
        # Submission queue WRITE signals (outputs from jigsaw_host_side)
        tb.log.info(f"sq_valid_write: {pkt_proc.sq_valid_write.value}")
        tb.log.info(f"sq_addr_write: {pkt_proc.sq_addr_write.value}")
        tb.log.info(f"sq_len_write: {pkt_proc.sq_len_write.value}")
        
        # Submission queue READ signals (outputs from jigsaw_host_side)
        tb.log.info(f"sq_valid_read: {pkt_proc.sq_valid_read.value}")
        tb.log.info(f"sq_addr_read: {pkt_proc.sq_addr_read.value}")
        tb.log.info(f"sq_len_read: {pkt_proc.sq_len_read.value}")
        
        # Note: mmio_* signals are inputs to jigsaw_host_side, skipping
        
        # Access deeper hierarchy - jigsaw_host_side_inst
        jhs = pkt_proc.jigsaw_host_side_inst
        tb.log.info(f"jigsaw_host_side instance found: {jhs}")
        
        # Access txn_generator instance
        txner = pkt_proc.txner
        tb.log.info(f"txn_generator instance found: {txner}")
        
    except AttributeError as e:
        tb.log.warning(f"Could not access internal signal: {e}")
        tb.log.info("Trying to discover hierarchy...")
        # Print available attributes to help discover the correct path
        tb.log.info(f"core_inst attributes with 'app': {[a for a in dir(core_inst) if 'app' in a.lower()]}")

    # ========================================
    # Test: MMIO control -> Submission Queue Read
    # ========================================
    tb.log.info("=== Testing MMIO -> SQ Read Interface ===")
    
    # Get access to jigsaw_host_side instance for driving inputs
    try:
        pkt_proc = core_inst.app.app_block_inst.pkt_proc
        jhs = pkt_proc.jigsaw_host_side_inst
        
        # Test parameters
        test_mmio_vaddr = 0x1000  # Test virtual address
        
        # Register map from payload_to_mmio.v:
        #   0x00 - DMA_CMD_REG
        #   0x08 - DMA_SRC_ADDR_REG
        #   0x10 - DMA_DST_ADDR_REG 
        #   0x18 - DMA_LEN_REG
        #   0x20 - DMA_STATUS_REG
        #   0x28 - START_COMPUTATION_REG
        #   0x30 - CYCLES_PER_COMPUTATION_REG
        #   0x38 - DMA_TX_LEN_REG
        
        # Test 1: MMIO Read from DMA_STATUS_REG
        tb.log.info("Test 1: MMIO Read from DMA_STATUS_REG (0x20)")
        status_value = await jigsaw_mmio_read(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x20)
        tb.log.info(f"DMA_STATUS_REG value: 0x{status_value:x}")
        tb.log.info("MMIO Read test PASSED!")
        
        # Test 2: MMIO Write to DMA_SRC_ADDR_REG and Read Back
        tb.log.info("=== Test 2: MMIO Write and Read Back ===")
        test_write_value = 0xDEADBEEF12345678
        
        tb.log.info(f"Writing 0x{test_write_value:x} to DMA_SRC_ADDR_REG (0x08)")
        await jigsaw_mmio_write(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x08, test_write_value)
        tb.log.info("MMIO Write completed")
        
        tb.log.info("Reading back from DMA_SRC_ADDR_REG (0x08)")
        read_back_value = await jigsaw_mmio_read(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x08)
        tb.log.info(f"Read back value: 0x{read_back_value:x} (expected: 0x{test_write_value:x})")
        
        assert read_back_value == test_write_value, f"Expected 0x{test_write_value:x}, got 0x{read_back_value:x}"
        tb.log.info("MMIO Write/Read test PASSED!")
        
        # Test 3: Write to DMA_LEN_REG and Read Back
        tb.log.info("=== Test 3: MMIO Write/Read DMA_LEN_REG ===")
        test_len_value = 0x1000  # 4096 bytes
        
        await jigsaw_mmio_write(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x18, test_len_value)
        read_back_len = await jigsaw_mmio_read(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x18)
        
        assert read_back_len == test_len_value, f"Expected 0x{test_len_value:x}, got 0x{read_back_len:x}"
        tb.log.info(f"DMA_LEN_REG: wrote 0x{test_len_value:x}, read back 0x{read_back_len:x} - PASSED!")
        
        # ========================================
        # Test 4: D2H DMA (Device to Host)
        # ========================================
        tb.log.info("=== Test 4: D2H DMA Transfer ===")
        
        # DMA Register map from payload_to_mmio.v:
        #   0x00 - DMA_CMD_REG (bit 0 = start, bit 1 = direction: 0=H2D, 1=D2H)
        #   0x08 - DMA_SRC_ADDR_REG
        #   0x10 - DMA_DST_ADDR_REG
        #   0x18 - DMA_LEN_REG
        
        dma_dst_addr = 0x3000  # Destination address on host
        dma_len = 512          # Transfer length in bytes
        dma_cmd = 0x03         # bit 0=1 (start), bit 1=1 (D2H direction)
        
        # Step 1: Write DMA destination address
        tb.log.info(f"Writing DMA_DST_ADDR_REG = 0x{dma_dst_addr:x}")
        await jigsaw_mmio_write(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x10, dma_dst_addr)
        
        # Step 2: Write DMA length
        tb.log.info(f"Writing DMA_LEN_REG = {dma_len}")
        await jigsaw_mmio_write(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x18, dma_len)
        
        # Step 3: Write DMA command to start transfer (D2H direction)
        tb.log.info(f"Writing DMA_CMD_REG = 0x{dma_cmd:x} (start D2H)")
        await jigsaw_mmio_write(tb, dut, pkt_proc, jhs, test_mmio_vaddr, 0x00, dma_cmd)
        
        # Step 4: Wait for sq_valid_write to go high (DMA write to host)
        tb.log.info("Waiting for D2H DMA sq_valid_write...")
        while True:
            sq_wr_valid = pkt_proc.sq_valid_write.value
            if sq_wr_valid == 1:
                sq_wr_addr = int(pkt_proc.sq_addr_write.value)
                sq_wr_len = int(pkt_proc.sq_len_write.value)
                break
            await RisingEdge(dut.clk)
        
        tb.log.info(f"sq_valid_write went high")
        tb.log.info(f"sq_addr_write: 0x{sq_wr_addr:x} (expected: 0x{dma_dst_addr:x})")
        tb.log.info(f"sq_len_write: {sq_wr_len} (expected: {dma_len})")
        
        # Verify SQ write values match DMA configuration
        assert sq_wr_addr == dma_dst_addr, f"Expected sq_addr_write=0x{dma_dst_addr:x}, got 0x{sq_wr_addr:x}"
        assert sq_wr_len == dma_len, f"Expected sq_len_write={dma_len}, got {sq_wr_len}"
        
        # Step 5: Receive the DMA data via tx.recv
        tb.log.info("Waiting for D2H DMA data via TX...")
        echo_tx_pkt = await tb.port_mac[0].tx.recv()
        
        tb.log.info(f"Received D2H DMA packet, length: {len(echo_tx_pkt.data)}")
        tb.log.info(f"D2H DMA data (first 32 bytes hex): {echo_tx_pkt.data[:32].hex()}")
        
        # Verify received data length matches DMA length
        assert len(echo_tx_pkt.data) == dma_len, f"Expected {dma_len} bytes, got {len(echo_tx_pkt.data)}"
        
        tb.log.info("D2H DMA test PASSED!")
        
        await RisingEdge(dut.clk)
        
    except AttributeError as e:
        tb.log.error(f"Could not access jigsaw_host_side signals: {e}")
    except AssertionError as e:
        tb.log.error(f"Test FAILED: {e}")

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# cocotb-test

tests_dir = os.path.dirname(__file__)
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(rtl_dir, '..', 'lib'))
axi_rtl_dir = os.path.abspath(os.path.join(lib_dir, 'axi', 'rtl'))
axis_rtl_dir = os.path.abspath(os.path.join(lib_dir, 'axis', 'rtl'))
eth_rtl_dir = os.path.abspath(os.path.join(lib_dir, 'eth', 'rtl'))
pcie_rtl_dir = os.path.abspath(os.path.join(lib_dir, 'pcie', 'rtl'))


@pytest.mark.parametrize(("if_count", "ports_per_if", "axis_pcie_data_width",
        "axis_eth_data_width", "axis_eth_sync_data_width", "ptp_ts_enable"), [
            (1, 1, 256, 64, 64, 1),
            (1, 1, 256, 64, 64, 0),
            (2, 1, 256, 64, 64, 1),
            (1, 2, 256, 64, 64, 1),
            (1, 1, 256, 64, 128, 1),
            (1, 1, 512, 64, 64, 1),
            (1, 1, 512, 64, 128, 1),
            (1, 1, 512, 512, 512, 1),
        ])
def test_mqnic_core_pcie_us(request, if_count, ports_per_if, axis_pcie_data_width,
        axis_eth_data_width, axis_eth_sync_data_width, ptp_ts_enable):
    dut = "mqnic_core_pcie_us"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, "common", f"{dut}.v"),
        os.path.join(rtl_dir, "common", "mqnic_core_pcie.v"),
        os.path.join(rtl_dir, "common", "mqnic_core.v"),
        os.path.join(rtl_dir, "common", "mqnic_dram_if.v"),
        os.path.join(rtl_dir, "common", "mqnic_interface.v"),
        os.path.join(rtl_dir, "common", "mqnic_interface_tx.v"),
        os.path.join(rtl_dir, "common", "mqnic_interface_rx.v"),
        os.path.join(rtl_dir, "common", "mqnic_port.v"),
        os.path.join(rtl_dir, "common", "mqnic_port_tx.v"),
        os.path.join(rtl_dir, "common", "mqnic_port_rx.v"),
        os.path.join(rtl_dir, "common", "mqnic_egress.v"),
        os.path.join(rtl_dir, "common", "mqnic_ingress.v"),
        os.path.join(rtl_dir, "common", "mqnic_l2_egress.v"),
        os.path.join(rtl_dir, "common", "mqnic_l2_ingress.v"),
        os.path.join(rtl_dir, "common", "mqnic_rx_queue_map.v"),
        os.path.join(rtl_dir, "common", "mqnic_ptp.v"),
        os.path.join(rtl_dir, "common", "mqnic_ptp_clock.v"),
        os.path.join(rtl_dir, "common", "mqnic_ptp_perout.v"),
        os.path.join(rtl_dir, "common", "mqnic_rb_clk_info.v"),
        os.path.join(rtl_dir, "common", "cpl_write.v"),
        os.path.join(rtl_dir, "common", "cpl_op_mux.v"),
        os.path.join(rtl_dir, "common", "desc_fetch.v"),
        os.path.join(rtl_dir, "common", "desc_op_mux.v"),
        os.path.join(rtl_dir, "common", "queue_manager.v"),
        os.path.join(rtl_dir, "common", "cpl_queue_manager.v"),
        os.path.join(rtl_dir, "common", "tx_fifo.v"),
        os.path.join(rtl_dir, "common", "rx_fifo.v"),
        os.path.join(rtl_dir, "common", "tx_req_mux.v"),
        os.path.join(rtl_dir, "common", "tx_engine.v"),
        os.path.join(rtl_dir, "common", "rx_engine.v"),
        os.path.join(rtl_dir, "common", "tx_checksum.v"),
        os.path.join(rtl_dir, "common", "rx_hash.v"),
        os.path.join(rtl_dir, "common", "rx_checksum.v"),
        os.path.join(rtl_dir, "common", "stats_counter.v"),
        os.path.join(rtl_dir, "common", "stats_collect.v"),
        os.path.join(rtl_dir, "common", "stats_pcie_if.v"),
        os.path.join(rtl_dir, "common", "stats_pcie_tlp.v"),
        os.path.join(rtl_dir, "common", "stats_dma_if_pcie.v"),
        os.path.join(rtl_dir, "common", "stats_dma_latency.v"),
        os.path.join(rtl_dir, "common", "mqnic_tx_scheduler_block_rr.v"),
        os.path.join(rtl_dir, "common", "tx_scheduler_rr.v"),
        os.path.join(rtl_dir, "mqnic_app_block.v"),
        os.path.join(eth_rtl_dir, "mac_ctrl_rx.v"),
        os.path.join(eth_rtl_dir, "mac_ctrl_tx.v"),
        os.path.join(eth_rtl_dir, "mac_pause_ctrl_rx.v"),
        os.path.join(eth_rtl_dir, "mac_pause_ctrl_tx.v"),
        os.path.join(eth_rtl_dir, "ptp_td_phc.v"),
        os.path.join(eth_rtl_dir, "ptp_td_leaf.v"),
        os.path.join(eth_rtl_dir, "ptp_perout.v"),
        os.path.join(axi_rtl_dir, "axil_crossbar.v"),
        os.path.join(axi_rtl_dir, "axil_crossbar_addr.v"),
        os.path.join(axi_rtl_dir, "axil_crossbar_rd.v"),
        os.path.join(axi_rtl_dir, "axil_crossbar_wr.v"),
        os.path.join(axi_rtl_dir, "axil_ram.v"),
        os.path.join(axi_rtl_dir, "axil_reg_if.v"),
        os.path.join(axi_rtl_dir, "axil_reg_if_rd.v"),
        os.path.join(axi_rtl_dir, "axil_reg_if_wr.v"),
        os.path.join(axi_rtl_dir, "axil_register_rd.v"),
        os.path.join(axi_rtl_dir, "axil_register_wr.v"),
        os.path.join(axi_rtl_dir, "arbiter.v"),
        os.path.join(axi_rtl_dir, "priority_encoder.v"),
        os.path.join(axis_rtl_dir, "axis_adapter.v"),
        os.path.join(axis_rtl_dir, "axis_arb_mux.v"),
        os.path.join(axis_rtl_dir, "axis_async_fifo.v"),
        os.path.join(axis_rtl_dir, "axis_async_fifo_adapter.v"),
        os.path.join(axis_rtl_dir, "axis_demux.v"),
        os.path.join(axis_rtl_dir, "axis_fifo.v"),
        os.path.join(axis_rtl_dir, "axis_fifo_adapter.v"),
        os.path.join(axis_rtl_dir, "axis_pipeline_fifo.v"),
        os.path.join(axis_rtl_dir, "axis_register.v"),
        os.path.join(pcie_rtl_dir, "pcie_axil_master.v"),
        os.path.join(pcie_rtl_dir, "pcie_tlp_demux.v"),
        os.path.join(pcie_rtl_dir, "pcie_tlp_demux_bar.v"),
        os.path.join(pcie_rtl_dir, "pcie_tlp_mux.v"),
        os.path.join(pcie_rtl_dir, "pcie_tlp_fifo.v"),
        os.path.join(pcie_rtl_dir, "pcie_tlp_fifo_raw.v"),
        os.path.join(pcie_rtl_dir, "pcie_msix.v"),
        os.path.join(pcie_rtl_dir, "irq_rate_limit.v"),
        os.path.join(pcie_rtl_dir, "dma_if_pcie.v"),
        os.path.join(pcie_rtl_dir, "dma_if_pcie_rd.v"),
        os.path.join(pcie_rtl_dir, "dma_if_pcie_wr.v"),
        os.path.join(pcie_rtl_dir, "dma_if_mux.v"),
        os.path.join(pcie_rtl_dir, "dma_if_mux_rd.v"),
        os.path.join(pcie_rtl_dir, "dma_if_mux_wr.v"),
        os.path.join(pcie_rtl_dir, "dma_if_desc_mux.v"),
        os.path.join(pcie_rtl_dir, "dma_ram_demux_rd.v"),
        os.path.join(pcie_rtl_dir, "dma_ram_demux_wr.v"),
        os.path.join(pcie_rtl_dir, "dma_psdpram.v"),
        os.path.join(pcie_rtl_dir, "dma_client_axis_sink.v"),
        os.path.join(pcie_rtl_dir, "dma_client_axis_source.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_if.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_if_rc.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_if_rq.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_if_cc.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_if_cq.v"),
        os.path.join(pcie_rtl_dir, "pcie_us_cfg.v"),
        os.path.join(pcie_rtl_dir, "pulse_merge.v"),
    ]

    parameters = {}

    # Structural configuration
    parameters['IF_COUNT'] = if_count
    parameters['PORTS_PER_IF'] = ports_per_if
    parameters['SCHED_PER_IF'] = ports_per_if

    # Clock configuration
    parameters['CLK_PERIOD_NS_NUM'] = 4
    parameters['CLK_PERIOD_NS_DENOM'] = 1

    # PTP configuration
    parameters['PTP_CLK_PERIOD_NS_NUM'] = 32
    parameters['PTP_CLK_PERIOD_NS_DENOM'] = 5
    parameters['PTP_CLOCK_PIPELINE'] = 0
    parameters['PTP_CLOCK_CDC_PIPELINE'] = 0
    parameters['PTP_SEPARATE_TX_CLOCK'] = 0
    parameters['PTP_SEPARATE_RX_CLOCK'] = 0
    parameters['PTP_PORT_CDC_PIPELINE'] = 0
    parameters['PTP_PEROUT_ENABLE'] = 0
    parameters['PTP_PEROUT_COUNT'] = 1

    # Queue manager configuration
    parameters['EVENT_QUEUE_OP_TABLE_SIZE'] = 32
    parameters['TX_QUEUE_OP_TABLE_SIZE'] = 32
    parameters['RX_QUEUE_OP_TABLE_SIZE'] = 32
    parameters['CQ_OP_TABLE_SIZE'] = 32
    parameters['EQN_WIDTH'] = 6
    parameters['TX_QUEUE_INDEX_WIDTH'] = 13
    parameters['RX_QUEUE_INDEX_WIDTH'] = 8
    parameters['CQN_WIDTH'] = max(parameters['TX_QUEUE_INDEX_WIDTH'], parameters['RX_QUEUE_INDEX_WIDTH']) + 1
    parameters['EQ_PIPELINE'] = 3
    parameters['TX_QUEUE_PIPELINE'] = 3 + max(parameters['TX_QUEUE_INDEX_WIDTH']-12, 0)
    parameters['RX_QUEUE_PIPELINE'] = 3 + max(parameters['RX_QUEUE_INDEX_WIDTH']-12, 0)
    parameters['CQ_PIPELINE'] = 3 + max(parameters['CQN_WIDTH']-12, 0)

    # TX and RX engine configuration
    parameters['TX_DESC_TABLE_SIZE'] = 32
    parameters['RX_DESC_TABLE_SIZE'] = 32
    parameters['RX_INDIR_TBL_ADDR_WIDTH'] = min(parameters['RX_QUEUE_INDEX_WIDTH'], 8)

    # Scheduler configuration
    parameters['TX_SCHEDULER_OP_TABLE_SIZE'] = parameters['TX_DESC_TABLE_SIZE']
    parameters['TX_SCHEDULER_PIPELINE'] = parameters['TX_QUEUE_PIPELINE']
    parameters['TDMA_INDEX_WIDTH'] = 6

    # Interface configuration
    parameters['PTP_TS_ENABLE'] = ptp_ts_enable
    parameters['TX_CPL_ENABLE'] = parameters['PTP_TS_ENABLE']
    parameters['TX_CPL_FIFO_DEPTH'] = 32
    parameters['TX_TAG_WIDTH'] = 16
    parameters['TX_CHECKSUM_ENABLE'] = 1
    parameters['RX_HASH_ENABLE'] = 1
    parameters['RX_CHECKSUM_ENABLE'] = 1
    parameters['LFC_ENABLE'] = 1
    parameters['PFC_ENABLE'] = parameters['LFC_ENABLE']
    parameters['MAC_CTRL_ENABLE'] = 1
    parameters['TX_FIFO_DEPTH'] = 32768
    parameters['RX_FIFO_DEPTH'] = 131072
    parameters['MAX_TX_SIZE'] = 9214
    parameters['MAX_RX_SIZE'] = 9214
    parameters['TX_RAM_SIZE'] = 131072
    parameters['RX_RAM_SIZE'] = 131072

    # RAM configuration
    parameters['DDR_CH'] = 1
    parameters['DDR_ENABLE'] = 0
    parameters['DDR_GROUP_SIZE'] = 1
    parameters['AXI_DDR_DATA_WIDTH'] = 256
    parameters['AXI_DDR_ADDR_WIDTH'] = 32
    parameters['AXI_DDR_ID_WIDTH'] = 8
    parameters['AXI_DDR_MAX_BURST_LEN'] = 256
    parameters['HBM_CH'] = 1
    parameters['HBM_ENABLE'] = 0
    parameters['HBM_GROUP_SIZE'] = parameters['HBM_CH']
    parameters['AXI_HBM_DATA_WIDTH'] = 256
    parameters['AXI_HBM_ADDR_WIDTH'] = 32
    parameters['AXI_HBM_ID_WIDTH'] = 6
    parameters['AXI_HBM_MAX_BURST_LEN'] = 16

    # Application block configuration
    parameters['APP_ID'] = 0x12340001
    parameters['APP_ENABLE'] = 1
    parameters['APP_CTRL_ENABLE'] = 1
    parameters['APP_DMA_ENABLE'] = 1
    parameters['APP_AXIS_DIRECT_ENABLE'] = 1
    parameters['APP_AXIS_SYNC_ENABLE'] = 1
    parameters['APP_AXIS_IF_ENABLE'] = 1
    parameters['APP_STAT_ENABLE'] = 1

    # DMA interface configuration
    parameters['DMA_IMM_ENABLE'] = 0
    parameters['DMA_IMM_WIDTH'] = 32
    parameters['DMA_LEN_WIDTH'] = 16
    parameters['DMA_TAG_WIDTH'] = 16
    parameters['RAM_ADDR_WIDTH'] = (max(parameters['TX_RAM_SIZE'], parameters['RX_RAM_SIZE'])-1).bit_length()
    parameters['RAM_PIPELINE'] = 2

    # PCIe interface configuration
    parameters['AXIS_PCIE_DATA_WIDTH'] = axis_pcie_data_width
    parameters['PF_COUNT'] = 1
    parameters['VF_COUNT'] = 0

    # Interrupt configuration
    parameters['IRQ_INDEX_WIDTH'] = parameters['EQN_WIDTH']

    # AXI lite interface configuration (control)
    parameters['AXIL_CTRL_DATA_WIDTH'] = 32
    parameters['AXIL_CTRL_ADDR_WIDTH'] = 24
    parameters['AXIL_CSR_PASSTHROUGH_ENABLE'] = 0

    # AXI lite interface configuration (application control)
    parameters['AXIL_APP_CTRL_DATA_WIDTH'] = parameters['AXIL_CTRL_DATA_WIDTH']
    parameters['AXIL_APP_CTRL_ADDR_WIDTH'] = 24

    # Ethernet interface configuration
    parameters['AXIS_ETH_DATA_WIDTH'] = axis_eth_data_width
    parameters['AXIS_ETH_SYNC_DATA_WIDTH'] = axis_eth_sync_data_width
    parameters['AXIS_ETH_RX_USE_READY'] = 0
    parameters['AXIS_ETH_TX_PIPELINE'] = 0
    parameters['AXIS_ETH_TX_FIFO_PIPELINE'] = 2
    parameters['AXIS_ETH_TX_TS_PIPELINE'] = 0
    parameters['AXIS_ETH_RX_PIPELINE'] = 0
    parameters['AXIS_ETH_RX_FIFO_PIPELINE'] = 2

    # Statistics counter subsystem
    parameters['STAT_ENABLE'] = 1
    parameters['STAT_DMA_ENABLE'] = 1
    parameters['STAT_PCIE_ENABLE'] = 1
    parameters['STAT_INC_WIDTH'] = 24
    parameters['STAT_ID_WIDTH'] = 12

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, "sim_build",
        request.node.name.replace('[', '-').replace(']', ''))

    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
    )
