################################################################################
#
# netbird
#
################################################################################

# Client only (CLI + daemon, one binary). The repo also holds management,
# signal, relay and the desktop UI; none of them are built or installed.
NETBIRD_VERSION = 0.78.2
NETBIRD_SITE = $(call github,netbirdio,netbird,v$(NETBIRD_VERSION))
# The client is BSD-3-Clause; management/, signal/, relay/ and combined/ are
# AGPL-3.0 but are not built into this binary.
NETBIRD_LICENSE = BSD-3-Clause
NETBIRD_LICENSE_FILES = LICENSE LICENSES/BSD-3-Clause.txt
NETBIRD_GOMOD = github.com/netbirdio/netbird

# One build target, so the golang infra installs exactly BIN_NAME to
# /usr/bin (<pkg>_INSTALL_BINS was removed in Buildroot 2025.11).
NETBIRD_BUILD_TARGETS = client
NETBIRD_BIN_NAME = netbird

# Without this the binary reports "development", and the management server
# treats development clients differently from releases.
NETBIRD_LDFLAGS = \
	-X github.com/netbirdio/netbird/version.version=$(NETBIRD_VERSION)

# Upstream's release builds (.goreleaser.yaml, id "netbird") are CGO-free;
# match what they test rather than linking a different resolver/user lookup.
#
# GOPROXY: Buildroot vendors with GOPROXY=direct, i.e. a git clone of every
# dependency of the *whole* module (management and proxy included). One of
# them, github.com/davecgh/go-spew@v1.1.2-0.20180830191138-d8f796af33cc
# (via crowdsec), is a commit GitHub no longer serves, so direct vendoring
# fails with "could not read Username for 'https://github.com'". The module
# proxy still has it, and go.sum pins its hash, so integrity is unchanged.
# _GO_ENV is appended after Buildroot's GOPROXY=direct in the download env, so
# it wins there; at build time -mod=vendor means no network is used anyway.
NETBIRD_GO_ENV = \
	CGO_ENABLED=0 \
	GOPROXY=https://proxy.golang.org

# Kernel WireGuard is only usable together with a native firewall: with the
# kernel interface, netbird's firewall factory has no userspace fallback, and
# the engine refuses to start ("create firewall manager"). The native firewall
# is nftables via netlink (no nft binary needed). Policy routing is what
# netbird's "advanced routing" (fwmark + ip rules) needs; without it netbird
# falls back to legacy exclusion routes.
#
# NFT_COMPAT is deliberately absent: it is only used for xtables DNAT on
# forwarding rules (`netbird expose`), which a TV box does not do.
define NETBIRD_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_TUN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIREGUARD)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IP_ADVANCED_ROUTER)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IP_MULTIPLE_TABLES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPV6_MULTIPLE_TABLES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NETFILTER)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_CONNTRACK)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_NAT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_TABLES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_TABLES_INET)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_TABLES_IPV4)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_TABLES_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_CT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_NAT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_MASQ)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_FIB_IPV4)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_FIB_IPV6)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NFT_FIB_INET)
endef

$(eval $(golang-package))
