# Mac Belt
#   make install     build, install to ~/Applications, and open it
#   make update      git pull + install
#   make uninstall   remove the app (keeps settings; PURGE=1 removes them too)
#   make test        run the tests
#   ADHOC=1 make install   skip the local signing identity (see README)

APP_NAME   := MacBelt.app
BUILD_APP  := build/$(APP_NAME)
PREFIX     ?= $(HOME)/Applications
DEST       := $(PREFIX)/$(APP_NAME)
SETTINGS   := $(HOME)/Library/Application Support/MacBelt

.PHONY: all app build test run install uninstall update signing-identity remove-signing-identity clean quit

all: app

build:
	swift build

test:
	swift test

app:
ifeq ($(ADHOC),1)
	MACBELT_ADHOC=1 scripts/build-app.sh
else
	scripts/build-app.sh
endif

signing-identity:
	scripts/signing-identity.sh

remove-signing-identity:
	rm -rf "$(SETTINGS)/signing"
	@echo "✓ removed the Mac Belt Local signing keychain"

run: app
	open "$(BUILD_APP)"

quit:
	@osascript -e 'tell application id "io.github.macbelt.app" to quit' >/dev/null 2>&1 || true
	@pkill -x MacBelt >/dev/null 2>&1 || true

install:
ifneq ($(ADHOC),1)
	@scripts/signing-identity.sh
endif
	@$(MAKE) --no-print-directory app
	@$(MAKE) --no-print-directory quit
	@mkdir -p "$(PREFIX)"
	@rm -rf "$(DEST)"
	@ditto "$(BUILD_APP)" "$(DEST)"
	@echo "✓ installed $(DEST)"
	@open "$(DEST)"
	@echo "  Mac Belt is in your menu bar. Settings ▸ \"Open Mac Belt at login\" to keep it there."

update:
	git pull --ff-only
	@$(MAKE) --no-print-directory install

uninstall: quit
	rm -rf "$(DEST)"
ifeq ($(PURGE),1)
	rm -rf "$(SETTINGS)"   # includes the signing keychain
	@echo "✓ removed Mac Belt and its settings"
else
	@echo "✓ removed Mac Belt. Settings kept in: $(SETTINGS) (make uninstall PURGE=1 removes them)"
endif

clean:
	rm -rf .build build
