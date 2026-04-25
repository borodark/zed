# Makefile — invoked by elixir_make to build the peer_cred NIF.
#
# elixir_make exports ERTS_INCLUDE_DIR and MIX_APP_PATH for us, so we
# don't have to probe the BEAM headers; both GNU make (Linux) and BSD
# make (FreeBSD/illumos) handle the constructs below identically.
#
# The Linux/FreeBSD link line uses -shared. macOS needs
# -dynamiclib -undefined dynamic_lookup; on Darwin the operator must
# export LDFLAGS with those flags before running mix compile, OR the
# Mac Pro CI box uses Linux (we don't ship Darwin in CI yet).

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_NAME = peer_cred
NIF_SO   = $(PRIV_DIR)/$(NIF_NAME).so

CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -fPIC -std=c11

LDFLAGS += -shared

SRC = c_src/peer_cred.c

all: $(NIF_SO)

$(NIF_SO): $(SRC)
	@test -d $(PRIV_DIR) || mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
