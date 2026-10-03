SHELL := /bin/bash

.PHONY: help validate syntax lint test contracts golden integration adversarial security ci

help:
	@echo "Autonomous SRE RCA Platform"
	@echo
	@echo "Available targets:"
	@echo "  make validate      Run repository validation"
	@echo "  make syntax        Validate Bash syntax"
	@echo "  make lint          Run ShellCheck"
	@echo "  make test          Run all tests"
	@echo "  make contracts     Run contract tests"
	@echo "  make golden        Run golden tests"
	@echo "  make integration   Run integration tests"
	@echo "  make adversarial   Run adversarial tests"
	@echo "  make security      Run public repository security checks"
	@echo "  make ci            Run the complete CI validation pipeline"

validate:
	@./scripts/validate.sh

syntax:
	@./scripts/check-bash-syntax.sh

lint:
	@./scripts/run-shellcheck.sh

contracts:
	@./scripts/run-tests.sh contracts

golden:
	@./scripts/run-tests.sh golden

integration:
	@./scripts/run-tests.sh integration

adversarial:
	@./scripts/run-tests.sh adversarial

security:
	@./scripts/security-audit.sh

test: contracts golden integration adversarial

ci: validate syntax lint test security
	@echo "CI_PIPELINE_STATUS=PASS"
