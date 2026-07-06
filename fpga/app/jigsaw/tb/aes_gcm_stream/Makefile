TOPLEVEL_LANG = verilog
SIM ?= icarus

RTLDIR = ../../rtl/jigsaw_modules

VERILOG_SOURCES += $(RTLDIR)/aes_gcm_encryption.v
VERILOG_SOURCES += $(RTLDIR)/aes_gcm_decryption.v
VERILOG_SOURCES += $(RTLDIR)/aes_gcm_stream.v
VERILOG_SOURCES += $(RTLDIR)/endian_swap.v
VERILOG_SOURCES += $(RTLDIR)/top_aes_gcm.v

# encrypt: make
# decrypt: make TOPLEVEL=aes_gcm_decryption MODULE=test_aes_dec_unit
TOPLEVEL ?= aes_gcm_encryption
MODULE ?= test_aes_enc_unit

include $(shell cocotb-config --makefiles)/Makefile.sim
