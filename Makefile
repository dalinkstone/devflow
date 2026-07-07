PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: install uninstall lint test test-docker all

all: lint test

install:
	install -d $(BINDIR)
	install -m 0755 bin/devflow $(BINDIR)/devflow
	ln -sf $(BINDIR)/devflow $(BINDIR)/dv
	@echo "installed: $(BINDIR)/devflow (alias: dv)"

uninstall:
	rm -f $(BINDIR)/devflow $(BINDIR)/dv

lint:
	bash -n bin/devflow
	bash -n install.sh
	shellcheck -S warning bin/devflow install.sh tests/run-tests.sh tests/docker-provision-test.sh
	bin/devflow __provision-script > /tmp/devflow-provision-lint.sh
	bash -n /tmp/devflow-provision-lint.sh
	shellcheck -S warning /tmp/devflow-provision-lint.sh
	@echo "lint OK"

test:
	bash tests/run-tests.sh

test-docker:
	bash tests/docker-provision-test.sh
