# ferry — install, uninstall, test
#
# Everything installs under PREFIX, which defaults to ~/.local so no sudo is
# needed. Override for a system install:
#
#   make install PREFIX=/opt/homebrew
#   sudo make install PREFIX=/usr/local

PREFIX  ?= $(HOME)/.local
BINDIR   = $(DESTDIR)$(PREFIX)/bin
MANDIR   = $(DESTDIR)$(PREFIX)/share/man/man1
ZSHDIR   = $(DESTDIR)$(PREFIX)/share/zsh/site-functions
BASHDIR  = $(DESTDIR)$(PREFIX)/share/bash-completion/completions
SHAREDIR = $(DESTDIR)$(PREFIX)/share/ferry

.DEFAULT_GOAL := help
.PHONY: help install uninstall link unlink test list-tests lint lint-tools deps check-version dist hooks unhooks app app-clean

T ?=

help: ## Show this help
	@printf 'ferry — targets\n\n'
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\nPREFIX is %s (override with make install PREFIX=...)\n' '$(PREFIX)'

install: ## Copy ferry, its man page and completions into PREFIX
	@mkdir -p $(BINDIR) $(MANDIR) $(ZSHDIR) $(BASHDIR) $(SHAREDIR)
	install -m 0755 ferry                  $(BINDIR)/ferry
	install -m 0644 doc/ferry.1            $(MANDIR)/ferry.1
	install -m 0644 completions/_ferry     $(ZSHDIR)/_ferry
	install -m 0644 completions/ferry.bash $(BASHDIR)/ferry
	@if [ -d $(APP_BUNDLE) ]; then \
		rm -rf $(SHAREDIR)/Ferry.app; \
		cp -R $(APP_BUNDLE) $(SHAREDIR)/Ferry.app; \
		printf '  installed Ferry.app into %s\n' '$(SHAREDIR)'; \
	else \
		printf '  (Ferry.app not built — run make app first if you want it)\n'; \
	fi
	@printf '\ninstalled to %s\n' '$(PREFIX)'
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
		*) printf '\n  NOTE: %s/bin is not on your PATH. Add:\n    export PATH="%s/bin:$$PATH"\n' '$(PREFIX)' '$(PREFIX)' ;; \
	esac
	@printf '\n  Next: %s\n' 'ferry setup'

uninstall: ## Remove all four installed files
	rm -f $(BINDIR)/ferry $(MANDIR)/ferry.1 $(ZSHDIR)/_ferry $(BASHDIR)/ferry
	rm -rf $(SHAREDIR)
	@printf 'removed from %s\n' '$(PREFIX)'

link: ## Symlink instead of copying, for development
	@mkdir -p $(BINDIR)
	ln -sf $(CURDIR)/ferry $(BINDIR)/ferry
	@printf 'linked %s -> %s\n' '$(BINDIR)/ferry' '$(CURDIR)/ferry'

unlink: ## Remove the development symlink
	rm -f $(BINDIR)/ferry

test: ## Run the suite; T="5 9" runs groups, T="-k conflict" filters by name
	@./tests/run.sh $(T)

list-tests: ## List the test groups
	@./tests/run.sh -l

SHELL_FILES = ferry tests/run.sh

# One entry point for static analysis, run byte-identically here and in CI.
# Suppressions live in .shellcheckrc, not on this command line, so there is
# nothing to keep in sync between the two.
#
# A missing tool is an ERROR, not a skip. A linter that quietly does nothing is
# worse than no linter: CI stays green while checking less than you think.
# Use `make lint SKIP_MISSING=1` to downgrade that to a warning.
lint: ## Static analysis — bash -n, shellcheck, actionlint (what CI runs)
	@fail=0; \
	for f in $(SHELL_FILES); do bash -n "$$f" || fail=1; done; \
	printf '  ok       bash -n (%s)\n' '$(SHELL_FILES)'; \
	if command -v shellcheck >/dev/null 2>&1; then \
		if shellcheck $(SHELL_FILES); then \
			printf '  ok       shellcheck %s\n' \
				"$$(shellcheck --version | awk '/^version:/{print $$2}')"; \
		else fail=1; fi; \
	elif [ -n "$(SKIP_MISSING)" ]; then printf '  skipped  shellcheck (not installed)\n'; \
	else printf '  MISSING  shellcheck — brew install shellcheck\n' >&2; fail=1; fi; \
	if command -v actionlint >/dev/null 2>&1; then \
		if actionlint; then \
			printf '  ok       actionlint %s\n' "$$(actionlint --version | head -1)"; \
		else fail=1; fi; \
	elif [ -n "$(SKIP_MISSING)" ]; then printf '  skipped  actionlint (not installed)\n'; \
	else printf '  MISSING  actionlint — brew install actionlint\n' >&2; fail=1; fi; \
	if [ $$fail -eq 0 ]; then printf 'static analysis clean\n'; \
	else printf 'static analysis FAILED\n' >&2; fi; \
	exit $$fail

lint-tools: ## Install the static analysis tools
	brew install shellcheck actionlint

# core.hooksPath is per-clone git config, not something a checkout can carry, so
# this has to be run once per machine. The hooks themselves are committed.
hooks: ## Enable the committed git hooks (once per clone)
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@printf 'hooks enabled — pre-commit runs lint, pre-push runs the full suite\n'

unhooks: ## Disable the committed git hooks
	@git config --unset core.hooksPath || true
	@printf 'hooks disabled\n'

# The bundle is assembled by hand because this machine (and any brew build)
# may have only the Command Line Tools — no xcodebuild. SwiftPM produces the
# binary; the plist and layout are ours. Ad-hoc signing is enough for a
# locally built app; there is no Developer ID here.
APP_BUILD = app/.build/release/Ferry
APP_BUNDLE = app/.build/Ferry.app

app: ## Build Ferry.app (SwiftPM + hand-assembled bundle)
	@command -v swift >/dev/null 2>&1 || { printf 'swift not found — install the Xcode Command Line Tools\n' >&2; exit 1; }
	swift build -c release --package-path app
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@v=$$(grep -m1 '^VERSION=' ferry | cut -d= -f2); \
	sed "s/@VERSION@/$$v/g" app/Info.plist.in > $(APP_BUNDLE)/Contents/Info.plist
	@cp $(APP_BUILD) $(APP_BUNDLE)/Contents/MacOS/Ferry
	@codesign --force --sign - $(APP_BUNDLE) 2>/dev/null
	@printf 'built %s\n' '$(APP_BUNDLE)'

app-clean: ## Remove app build products
	rm -rf app/.build

deps: ## Verify rclone is present and new enough
	@command -v rclone >/dev/null 2>&1 || { printf 'rclone not found: brew install rclone\n'; exit 1; }
	@rclone bisync --help 2>/dev/null | grep -q -- --backup-dir1 \
		|| { printf 'rclone is too old: --backup-dir1 is required (need >= 1.66)\n'; exit 1; }
	@printf 'rclone %s — ok\n' "$$(rclone version | head -1 | awk '{print $$2}')"

check-version: ## VERSION= in ferry must equal the .TH line in doc/ferry.1
	@s=$$(grep -m1 '^VERSION=' ferry | cut -d= -f2); \
	m=$$(grep -m1 '^\.TH' doc/ferry.1 | sed 's/.*"ferry \([0-9.]*\)".*/\1/'); \
	if [ "$$s" != "$$m" ]; then \
		printf 'version mismatch: ferry=%s man=%s\n' "$$s" "$$m"; exit 1; fi; \
	printf 'version %s consistent\n' "$$s"

dist: check-version ## Build release artifacts into dist/
	@rm -rf dist && mkdir -p dist
	@v=$$(grep -m1 '^VERSION=' ferry | cut -d= -f2); \
	tar czf dist/ferry-$$v.tar.gz ferry doc completions app Makefile README.md LICENSE; \
	cp ferry dist/ferry; \
	printf 'dist/ferry-%s.tar.gz\n' "$$v"
