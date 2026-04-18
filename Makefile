.PHONY: help deps check backup restore interactive clean distclean

SCRIPT  := ./customize-clonezilla.sh
CONFIG  := config/settings.conf

# ---- Help -------------------------------------------------------------------
help:
	@echo ""
	@echo "CustomCloneZilla — Makefile targets"
	@echo "------------------------------------"
	@echo "  make deps         Install required system packages (xorriso wget)"
	@echo "  make check        Validate config and show dry-run output"
	@echo "  make backup       Build ISO configured for NFS backup  (reads \$$(CONFIG))"
	@echo "  make restore      Build ISO configured for NFS restore (reads \$$(CONFIG))"
	@echo "  make interactive  Build ISO with custom locale/keyboard only"
	@echo "  make clean        Remove the generated output ISO (keeps cached source ISO)"
	@echo "  make distclean    Remove entire build/ directory (including cached ISO)"
	@echo ""
	@echo "Override any setting from the command line, e.g.:"
	@echo "  make restore NFS_SERVER=10.0.0.5 NFS_SHARE=/backups DISK=nvme0n1"
	@echo ""

# ---- Dependencies -----------------------------------------------------------
deps:
	sudo apt-get update -qq
	sudo apt-get install -y xorriso wget

# ---- Configurable overrides (pass on the make command line) -----------------
LANGUAGE         ?=
KEYBOARD         ?=
KEYBOARD_VARIANT ?=
TIMEZONE         ?=
NFS_SERVER       ?=
NFS_SHARE        ?=
NFS_OPTS         ?=
NFS_VERSION      ?=
NFS_WAIT         ?=
DISK             ?=
IMAGE            ?=
COMPRESS         ?=
POST_ACTION      ?=
OUTPUT           ?=
CZ_VERSION       ?=
LOCAL_ISO        ?=

# Build extra flags from non-empty make variables (evaluated at recipe time)
define extra_flags
$(if $(LANGUAGE),         --language         "$(LANGUAGE)")         \
$(if $(KEYBOARD),         --keyboard         "$(KEYBOARD)")         \
$(if $(KEYBOARD_VARIANT), --keyboard-variant "$(KEYBOARD_VARIANT)") \
$(if $(TIMEZONE),         --timezone         "$(TIMEZONE)")         \
$(if $(NFS_SERVER),       --nfs-server       "$(NFS_SERVER)")       \
$(if $(NFS_SHARE),        --nfs-share        "$(NFS_SHARE)")        \
$(if $(NFS_OPTS),         --nfs-opts         "$(NFS_OPTS)")         \
$(if $(NFS_VERSION),      --nfs-version      "$(NFS_VERSION)")      \
$(if $(NFS_WAIT),         --nfs-wait         "$(NFS_WAIT)")         \
$(if $(DISK),             --disk             "$(DISK)")             \
$(if $(IMAGE),            --image            "$(IMAGE)")            \
$(if $(COMPRESS),         --compress         "$(COMPRESS)")         \
$(if $(POST_ACTION),      --post-action      "$(POST_ACTION)")      \
$(if $(OUTPUT),           --output           "$(OUTPUT)")           \
$(if $(CZ_VERSION),       --czversion        "$(CZ_VERSION)")       \
$(if $(LOCAL_ISO),        --iso              "$(LOCAL_ISO)")
endef

BASE_CMD := $(SCRIPT) --config $(CONFIG)

# ---- Dry-run / check --------------------------------------------------------
check:
	$(BASE_CMD) $(extra_flags) --dry-run --verbose

# ---- ISO build targets ------------------------------------------------------
backup:
	$(BASE_CMD) $(extra_flags) --mode backup

restore:
	$(BASE_CMD) $(extra_flags) --mode restore

interactive:
	$(BASE_CMD) $(extra_flags) --mode interactive

# ---- Cleanup ----------------------------------------------------------------
clean:
	rm -f build/custom-clonezilla.iso

distclean:
	rm -rf build/
