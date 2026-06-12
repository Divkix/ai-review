.PHONY: check lint test contract pins

check: lint test contract pins

lint:
	actionlint .github/workflows/*.yml
	shellcheck scripts/*.sh scripts/lib/*.sh

test:
	bats tests/

contract:
	python3 scripts/check-contract.py

pins:
	CHECK_PINS_OFFLINE=1 bash scripts/check-pins.sh
