SHELL := bash
DB ?= dynamodb

.PHONY: build tools up down sam-up test test-e2e test-lambda test-sync test-iac verify \
	migrate sync-backfill sync-rebuild sync-replay benchmark benchmark-native native-smoke

build:
	./scripts/gradle.sh assemble installDist lambdaZip

tools:
	./scripts/tools.sh install sam
	./scripts/tools.sh install terraform

up:
	./scripts/local.sh up $(DB)

down:
ifeq ($(origin DB),file)
	@if [[ -n "$${COMPOSE_PROJECT_NAME:-}" ]]; then \
		./scripts/local.sh down $(DB); \
	else \
		set -e; for db in dynamodb aurora hybrid; do ./scripts/local.sh down $$db; done; \
	fi
else
	./scripts/local.sh down $(DB)
endif

sam-up:
	./scripts/local.sh sam-start $(DB)

test:
	./scripts/gradle.sh test

test-e2e:
	./scripts/local.sh e2e $(DB)

test-lambda:
	./scripts/local.sh sam-test $(DB)

test-sync:
	python3 tests/sync.py

test-iac:
	@tf=$$(./scripts/tools.sh install terraform) && \
		CHECKPOINT_DISABLE=1 "$$tf" -chdir=terraform fmt -check -recursive && \
		CHECKPOINT_DISABLE=1 "$$tf" -chdir=terraform init -backend=false -input=false && \
		CHECKPOINT_DISABLE=1 "$$tf" -chdir=terraform validate && \
		CHECKPOINT_DISABLE=1 "$$tf" -chdir=terraform test -filter=tests/modes.tftest.hcl

verify:
	$(MAKE) test
	@set -e; for db in dynamodb aurora hybrid; do $(MAKE) test-e2e DB=$$db; done
	@set -e; for db in dynamodb aurora hybrid; do $(MAKE) test-lambda DB=$$db; done
	$(MAKE) test-sync
	$(MAKE) test-iac

migrate:
	./scripts/local.sh exec $(DB) cookbook.api.db.PostgresAdmin migrate

sync-backfill:
	./scripts/local.sh sync-maintenance hybrid backfill

sync-rebuild:
	./scripts/local.sh sync-maintenance hybrid rebuild

export FILE
sync-replay:
	./scripts/local.sh sync hybrid replay $${FILE:+"$$FILE"}

benchmark:
	./benchmarks/run.sh suite

benchmark-native:
	./benchmarks/run.sh native

native-smoke:
	./benchmarks/run.sh smoke
