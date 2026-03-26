include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mynet
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-mynet
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for MyNet
  DEPENDS:=+luci-base +curl +luci-lib-jsonc
  PKGARCH:=all
endef

define Package/luci-app-mynet/description
  MyNet management interface for OpenWrt.
  Provides zone/node management, config sync, and service control
  through the LuCI web interface.
endef

define Build/Compile
endef

define Package/luci-app-mynet/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/mynet.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/mynet
	$(INSTALL_DATA) ./luasrc/model/mynet/*.lua $(1)/usr/lib/lua/luci/model/mynet/

	$(INSTALL_DIR) $(1)/usr/share/luci/view/mynet
	$(INSTALL_DATA) ./luasrc/view/mynet/*.htm $(1)/usr/share/luci/view/mynet/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/mynet/css
	$(INSTALL_DATA) ./htdocs/luci-static/resources/mynet/css/mynet.css \
		$(1)/www/luci-static/resources/mynet/css/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/mynet/js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/mynet/js/mynet.js \
		$(1)/www/luci-static/resources/mynet/js/

	$(INSTALL_DIR) $(1)/etc/mynet/conf
	$(INSTALL_CONF) ./root/etc/mynet/conf/config.json $(1)/etc/mynet/conf/
endef

$(eval $(call BuildPackage,luci-app-mynet))
