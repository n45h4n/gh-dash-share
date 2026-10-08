.DEFAULT_GOAL := help

.PHONY: help setup doctor test
help:
	@printf '%s\n' 'make setup   Install or update the runtime and guide authentication' 'make doctor  Check installation, authentication, and current Herdr context' 'make test    Run isolated tests with mocked external tools'

setup:
	@./scripts/setup.sh

doctor:
	@./scripts/doctor.sh

test:
	@python3 -B -m unittest discover -s tests -p 'test_*.py' -v
