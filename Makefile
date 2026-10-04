.PHONY: bootstrap link status pull

WORKSPACE ?= $(HOME)/workspace
INFRA ?=
BIOINFO ?=
OPTIONAL = $(if $(INFRA),--infra $(INFRA)) $(if $(BIOINFO),--bioinfo $(BIOINFO))

bootstrap: ## Clone core repos; asks about each optional repo (INFRA=, BIOINFO=all|none|ask)
	./scripts/bootstrap.sh $(OPTIONAL)

link: ## Symlink existing clones from WORKSPACE instead of cloning
	./scripts/bootstrap.sh --link $(WORKSPACE) $(OPTIONAL)

status: ## Branch and state of every checked-out repo
	./scripts/status.sh

pull: ## git pull --ff-only in every clean repo
	./scripts/status.sh --pull
