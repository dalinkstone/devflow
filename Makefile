PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: install uninstall lint test test-docker all tui test-tui release-assets

all: lint test

install: tui
	install -d $(BINDIR)
	install -m 0755 bin/devflow $(BINDIR)/devflow
	install -m 0755 bin/devflow-tui $(BINDIR)/devflow-tui
	ln -sf $(BINDIR)/devflow $(BINDIR)/dv
	@echo "installed: $(BINDIR)/devflow (alias: dv)"

uninstall:
	rm -f $(BINDIR)/devflow $(BINDIR)/dv $(BINDIR)/devflow-tui

VERSION := $(shell sed -n 's/^DEVFLOW_VERSION="\(.*\)"/\1/p' bin/devflow)

tui:
	CGO_ENABLED=0 go build -trimpath -ldflags '-s -w -X main.version=$(VERSION)' -o bin/devflow-tui ./cmd/devflow-tui

test-tui: tui
	go test -race ./cmd/devflow-tui
	go vet ./cmd/devflow-tui
	DEVFLOW_TEST_CHARM=1 python3 tests/test_session_console.py

release-assets:
	mkdir -p dist
	@for os in darwin linux; do for arch in arm64 amd64; do \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags '-s -w -X main.version=$(VERSION)' -o dist/devflow-tui-$$os-$$arch ./cmd/devflow-tui || exit 1; \
	done; done
	cd dist && shasum -a 256 devflow-tui-* > checksums.txt

lint:
	sh -n i
	bash -n bin/devflow
	bash -n install.sh
	shellcheck -S warning i bin/devflow install.sh tests/run-tests.sh tests/docker-provision-test.sh
	bin/devflow __provision-script > /tmp/devflow-provision-lint.sh
	bash -n /tmp/devflow-provision-lint.sh
	shellcheck -S warning /tmp/devflow-provision-lint.sh
	@echo "lint OK"

test:
	bash tests/run-tests.sh
	python3 tests/test_bus.py
	python3 tests/test_console.py
	python3 tests/test_demo.py
	python3 tests/test_bugfix.py
	python3 tests/test_agents.py
	python3 tests/test_sessions.py
	python3 tests/test_session_console.py
	python3 tests/test_tui_installer.py
	$(MAKE) test-tui

test-docker:
	bash tests/docker-provision-test.sh
