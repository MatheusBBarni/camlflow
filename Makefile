.PHONY: help build test clean cli-help completion-bash completion-zsh completion-fish parse-basic check-basic compile-basic run run-basic run-orchestrator run-project-config run-provider-hooks all

DUNE ?= opam exec -- dune
BINARY ?= ./bin/main.exe
FILE ?= examples/basic/main.cml
ENTRY ?= main
INPUT_JSON ?= "Ada"
INPUT_FILE ?=
SKILLS ?=
INCLUDE_DIRS ?=
BASIC_INPUT ?= "Ada"
ORCHESTRATOR_INPUT ?= examples/orchestrator-session/input.json
PROJECT_CONFIG_INPUT ?= examples/project-config/input.json

help:
	@printf "CamlFlow Make targets\n\n"
	@printf "  make build                Build library, CLI, and examples\n"
	@printf "  make test                 Run test suite\n"
	@printf "  make cli-help             Show CLI help\n"
	@printf "  make completion-bash      Print bash completion script\n"
	@printf "  make completion-zsh       Print zsh completion script\n"
	@printf "  make completion-fish      Print fish completion script\n"
	@printf "  make run FILE=...         Generic runner for source/artifact inputs\n"
	@printf "  make run-basic            Run examples/basic/main.cml\n"
	@printf "  make run-orchestrator     Run examples/orchestrator-session/main.cml\n"
	@printf "  make run-project-config   Run examples/project-config/main.cml\n"
	@printf "  make run-provider-hooks   Run Node JSON-RPC provider-hooks host example\n"
	@printf "  make clean                Clean dune build artifacts\n\n"
	@printf "Generic run variables:\n"
	@printf "  FILE=examples/basic/main.cml INPUT_JSON='\"Ada\"'\n"
	@printf "  ENTRY=main INPUT_FILE=input.json SKILLS=examples/provider-hooks/skills\n"
	@printf "  INCLUDE_DIRS='dir1 dir2'\n"

all: build test

build:
	$(DUNE) build

test:
	$(DUNE) test

clean:
	$(DUNE) clean

cli-help:
	$(DUNE) exec $(BINARY) -- --help

completion-bash:
	$(DUNE) exec $(BINARY) -- completion bash

completion-zsh:
	$(DUNE) exec $(BINARY) -- completion zsh

completion-fish:
	$(DUNE) exec $(BINARY) -- completion fish

run:
	@set -eu; \
	set -- run "$(FILE)"; \
	for dir in $(INCLUDE_DIRS); do \
		set -- "$$@" -I "$$dir"; \
	done; \
	if [ "$(ENTRY)" != "main" ]; then \
		set -- "$$@" --entry "$(ENTRY)"; \
	fi; \
	if [ -n "$(INPUT_FILE)" ]; then \
		set -- "$$@" --input "$(INPUT_FILE)"; \
	elif [ -n "$(INPUT_JSON)" ]; then \
		set -- "$$@" --input-json "$(INPUT_JSON)"; \
	fi; \
	if [ -n "$(SKILLS)" ]; then \
		set -- "$$@" --skills "$(SKILLS)"; \
	fi; \
	echo "$(DUNE) exec $(BINARY) -- $$*"; \
	$(DUNE) exec $(BINARY) -- "$$@"

parse-basic:
	$(DUNE) exec $(BINARY) -- parse examples/basic/main.cml

check-basic:
	$(DUNE) exec $(BINARY) -- check examples/basic/main.cml

compile-basic:
	$(DUNE) exec $(BINARY) -- compile examples/basic/main.cml -o /tmp/camlflow-basic.ir.json

run-basic:
	$(DUNE) exec $(BINARY) -- run examples/basic/main.cml --input-json '$(BASIC_INPUT)'

run-orchestrator:
	$(DUNE) exec $(BINARY) -- run examples/orchestrator-session/main.cml --input $(ORCHESTRATOR_INPUT)

run-project-config:
	$(DUNE) exec $(BINARY) -- run examples/project-config/main.cml --input $(PROJECT_CONFIG_INPUT)

run-provider-hooks:
	node examples/json-rpc-host/host.js
