# Makefile — invoked by elixir_make to build the peer_cred NIF.
#
# Targets one .so: priv/peer_cred.so. ERTS_INCLUDE_DIR is exported by
# elixir_make so we don't have to probe for the BEAM headers.

PRIV_DIR    = $(MIX_APP_PATH)/priv
NIF_NAME    = peer_cred
NIF_SO      = $(PRIV_DIR)/$(NIF_NAME).so

CFLAGS     ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS     += -fPIC -std=c11

UNAME_S    := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LDFLAGS  += -dynamiclib -undefined dynamic_lookup
else
  LDFLAGS  += -shared
endif

ERTS_INCLUDE_DIR ?= $(shell erl -eval 'io:format("~ts", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])])' -s init stop -noshell)

SRC := c_src/peer_cred.c

all: $(NIF_SO)

$(NIF_SO): $(SRC)
	@test -d $(PRIV_DIR) || mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
