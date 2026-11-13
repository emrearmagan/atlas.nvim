.PHONY: check test lint lint-stylua lint-selene format

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
