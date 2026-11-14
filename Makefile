.PHONY: help check test lint lint-stylua lint-selene format

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  check        lint and test"
	@echo "  test         run specs with busted"
	@echo "  lint         run stylua and selene checks"
	@echo "  lint-stylua  check formatting with stylua"
	@echo "  lint-selene  lint with selene"
	@echo "  format       format with stylua"

check: lint test

test:
	busted

lint: lint-stylua lint-selene

lint-stylua:
	stylua --check lua spec

lint-selene:
	selene lua spec

format:
	stylua lua spec
