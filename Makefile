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

.DEFAULT_GOAL := help
.PHONY: help install uninstall link unlink test list-tests lint deps check-version dist

T ?=

help: ## Show this help
	@printf 'ferry — targets\n\n'
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\nPREFIX is %s (override with make install PREFIX=...)\n' '$(PREFIX)'

install: ## Copy ferry, its man page and completions into PREFIX
	@mkdir -p $(BINDIR) $(MANDIR) $(ZSHDIR) $(BASHDIR)
	install -m 0755 ferry                  $(BINDIR)/ferry
	install -m 0644 doc/ferry.1            $(MANDIR)/ferry.1
	install -m 0644 completions/_ferry     $(ZSHDIR)/_ferry
	install -m 0644 completions/ferry.bash $(BASHDIR)/ferry
	@printf '\ninstalled to %s\n' '$(PREFIX)'
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
		*) printf '\n  NOTE: %s/bin is not on your PATH. Add:\n    export PATH="%s/bin:$$PATH"\n' '$(PREFIX)' '$(PREFIX)' ;; \
	esac
	@printf '\n  Next: %s\n' 'ferry setup'

uninstall: ## Remove all four installed files
	rm -f $(BINDIR)/ferry $(MANDIR)/ferry.1 $(ZSHDIR)/_ferry $(BASHDIR)/ferry
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

lint: ## shellcheck ferry and the suite (skips cleanly if not installed)
	@command -v shellcheck >/dev/null 2>&1 \
		|| { printf 'shellcheck not installed, skipping\n'; exit 0; }
	shellcheck ferry tests/run.sh

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
	tar czf dist/ferry-$$v.tar.gz ferry doc completions Makefile README.md LICENSE; \
	cp ferry dist/ferry; \
	printf 'dist/ferry-%s.tar.gz\n' "$$v"
