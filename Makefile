.PHONY: bootstrap link status pull

WORKSPACE ?= $(HOME)/workspace
INFRA ?=

bootstrap: ## Clone core repos; asks about each infra repo (INFRA=all|none|ask)
	./scripts/bootstrap.sh $(if $(INFRA),--infra $(INFRA))

link: ## Symlink existing clones from WORKSPACE instead of cloning
	./scripts/bootstrap.sh --link $(WORKSPACE) $(if $(INFRA),--infra $(INFRA))

status: ## Branch and state of every checked-out repo
	./scripts/status.sh

pull: ## git pull --ff-only in every clean repo
	./scripts/status.sh --pull
