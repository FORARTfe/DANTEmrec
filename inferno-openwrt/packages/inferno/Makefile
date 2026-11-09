# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk

PKG_NAME:=inferno-openwrt
PKG_VERSION:=0.0.unprepared
PKG_RELEASE:=1
-include $(CURDIR)/source.mk
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DEPENDS:=rust/host $(if $(CONFIG_PACKAGE_alsa-lib-pcm-inferno),alsa-lib)
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16
PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_inferno2pipe CONFIG_PACKAGE_alsa-lib-pcm-inferno

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

# Deliberately override the feed's size-only profile without replacing its linker flags.
CARGO_PKG_PROFILE:=release
CARGO_PKG_VARS+= CARGO_PROFILE_RELEASE_OPT_LEVEL=2 \
 CARGO_PROFILE_RELEASE_LTO=thin CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
 CARGO_PROFILE_RELEASE_PANIC=abort CARGO_PROFILE_RELEASE_DEBUG=0 \
 CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=true \
 CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=$(PKG_BUILD_DIR)/target

INFERNO_ARCH_DEPENDS:=@(aarch64||x86_64)

define Package/inferno2pipe
  SECTION:=sound
  CATEGORY:=Sound
  TITLE:=Unofficial Dante capture with bounded output buffering
  DEPENDS:=$(RUST_ARCH_DEPENDS) $(INFERNO_ARCH_DEPENDS) +inferno-statime +libpthread +librt +libgcc
endef

define Package/inferno2pipe/description
  Experimental Inferno capture frontend for OpenWrt. Outputs interleaved S32_LE.
  Includes procd/UCI integration, reduced owned RX buffers and fail-stop output.
  Not an Audinate product and not suitable for critical audio without validation.
endef

define Package/inferno2pipe/conffiles
/etc/config/inferno
endef

define Package/alsa-lib-pcm-inferno
  SECTION:=sound
  CATEGORY:=Sound
  TITLE:=Inferno ALSA PCM plugin (optional bidirectional audio)
  DEPENDS:=$(RUST_ARCH_DEPENDS) $(INFERNO_ARCH_DEPENDS) +inferno-statime +alsa-lib +libpthread +librt +libgcc
endef

define Package/alsa-lib-pcm-inferno/description
  Optional upstream Inferno ALSA virtual PCM device for Dante transmit/receive.
  The host ALSA application supplies buffering and runs the protocol endpoint.
endef

define Build/Prepare
	@test -f $(CURDIR)/source.mk || { echo 'Run tools/prepare_sources.py first'; exit 1; }
	$(call Build/Prepare/Default)
endef

define Build/Configure
endef

define Build/Compile
	+if [ -n "$(CONFIG_PACKAGE_inferno2pipe)" ]; then \
		cd $(PKG_BUILD_DIR) && $(CARGO_PKG_VARS) cargo build --frozen --release \
		-p inferno2pipe --bin inferno2pipe $(if $(filter --jobserver%,$(PKG_JOBS)),,-j1); \
	fi
	+if [ -n "$(CONFIG_PACKAGE_alsa-lib-pcm-inferno)" ]; then \
		cd $(PKG_BUILD_DIR) && $(CARGO_PKG_VARS) CARGO_PROFILE_RELEASE_PANIC=unwind \
		PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_SYSROOT_DIR=$(STAGING_DIR) \
		PKG_CONFIG_LIBDIR=$(STAGING_DIR)/usr/lib/pkgconfig \
		cargo build --frozen --release -p alsa_pcm_inferno --lib \
		$(if $(filter --jobserver%,$(PKG_JOBS)),,-j1); \
	fi
endef

define Package/inferno2pipe/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/inferno2pipe $(1)/usr/bin/
	$(INSTALL_BIN) ./files/inferno.init $(1)/etc/init.d/inferno
	$(INSTALL_CONF) ./files/inferno.config $(1)/etc/config/inferno
endef

define Package/alsa-lib-pcm-inferno/install
	$(INSTALL_DIR) $(1)/usr/lib/alsa-lib $(1)/usr/share/inferno
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/libasound_module_pcm_inferno.so $(1)/usr/lib/alsa-lib/
	$(INSTALL_DATA) ./files/asound.conf.example $(1)/usr/share/inferno/
endef

$(eval $(call BuildPackage,inferno2pipe))
$(eval $(call BuildPackage,alsa-lib-pcm-inferno))
