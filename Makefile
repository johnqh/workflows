# Makefile for @0xmail/workflows

.PHONY: lint-workflows help

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint-workflows: ## Run actionlint on all workflow YAML files
	@./scripts/lint-workflows.sh
