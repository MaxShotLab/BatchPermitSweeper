.PHONY: deps build test test-ci tooling-test smoke check fmt abi

deps:
	git submodule update --init

build:
	forge build --sizes --skip test --skip script
	forge build

test:
	forge test --no-match-path 'test/Fork.t.sol' -vvv

test-ci:
	FOUNDRY_PROFILE=ci forge test --no-match-path 'test/Fork.t.sol' -vvv

tooling-test:
	python3 -m unittest discover -s scripts -p 'test_*.py' -v
	bash -n scripts/install-foundry-linux.sh scripts/smoke.sh

smoke:
	bash scripts/smoke.sh

check: build test-ci tooling-test smoke

fmt:
	forge fmt

abi:
	forge inspect src/BatchPermitSweeper.sol:BatchPermitSweeper abi --json
