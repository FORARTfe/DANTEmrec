# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk
PKG_NAME:=inferno-statime
PKG_VERSION:=0.0.unprepared
PKG_RELEASE:=1
-include $(CURDIR)/source.mk
PKG_LICENSE:=Apache-2.0 MIT
PKG_LICENSE_FILES:=LICENSE-APACHE LICENSE-MIT
PKG_BUILD_DEPENDS:=rust/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

CARGO_PKG_PROFILE:=release
CARGO_PKG_VARS+= CARGO_PROFILE_RELEASE_OPT_LEVEL=2 \
 CARGO_PROFILE_RELEASE_LTO=thin CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
 CARGO_PROFILE_RELEASE_PANIC=abort CARGO_PROFILE_RELEASE_DEBUG=0 \
 CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=true \
 CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=$(PKG_BUILD_DIR)/target

define Package/inferno-statime
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Inferno-compatible Statime PTP clock daemon
  DEPENDS:=$(RUST_ARCH_DEPENDS) @(aarch64||x86_64) +libpthread +librt +libgcc
  USERID:=inferno:inferno
endef

define Package/inferno-statime/description
  Experimental Statime fork providing PTPv1 and exported virtual-clock support.
  Dedicated daemon name avoids replacing the distribution's ordinary PTP tools.
  Do not run another PTP listener on the same interface/ports.
endef

define Package/inferno-statime/conffiles
/etc/config/inferno-clock
endef

define Build/Prepare
	@test -f $(CURDIR)/source.mk || { echo 'Run tools/prepare_sources.py first'; exit 1; }
	$(call Build/Prepare/Default)
endef

define Build/Configure
endef

define Build/Compile
	+cd $(PKG_BUILD_DIR) && $(CARGO_PKG_VARS) cargo build --frozen --release \
		-p statime-linux --bin statime $(if $(filter --jobserver%,$(PKG_JOBS)),,-j1)
endef

define Package/inferno-statime/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/libexec $(1)/usr/lib/inferno $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/statime $(1)/usr/sbin/inferno-statime
	$(INSTALL_BIN) ./files/inferno-clock.init $(1)/etc/init.d/inferno-clock
	$(INSTALL_BIN) ./files/inferno-clock-run $(1)/usr/libexec/inferno-clock-run
	$(INSTALL_DATA) ./files/common.sh $(1)/usr/lib/inferno/common.sh
	$(INSTALL_CONF) ./files/inferno-clock.config $(1)/etc/config/inferno-clock
endef

$(eval $(call BuildPackage,inferno-statime))
