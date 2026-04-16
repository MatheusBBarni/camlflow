.PHONY: help build test clean cli-help completion-bash completion-zsh completion-fish parse-basic check-basic compile-basic run run-basic run-local-skill run-qualified run-recursion run-inline-agent run-provider-hooks all

DUNE ?= dune
BINARY ?= camlflow
FILE ?= examples/basic/main.cml
ENTRY ?= main
INPUT_JSON ?= "Ada"
INPUT_FILE ?=
SKILLS ?=
INCLUDE_DIRS ?=
BASIC_INPUT ?= "Ada"
RECURSION_INPUT ?= 4
LOCAL_SKILL_INPUT ?= "hello"
INLINE_AGENT_INPUT ?= "code"

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
	@printf "  make run-local-skill      Run examples/local-skill/main.cml\n"
	@printf "  make run-qualified        Run examples/qualified-imports/main.cml\n"
	@printf "  make run-recursion        Run examples/recursion/main.cml\n"
	@printf "  make run-inline-agent     Run examples/inline-agent/main.cml\n"
	@printf "  make run-provider-hooks   Run embedded OCaml provider-hooks host example\n"
	@printf "  make clean                Clean dune build artifacts\n\n"
	@printf "Generic run variables:\n"
	@printf "  FILE=examples/basic/main.cml INPUT_JSON='\"Ada\"'\n"
	@printf "  ENTRY=main INPUT_FILE=input.json SKILLS=examples/local-skill/skills\n"
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

run-local-skill:
	$(DUNE) exec $(BINARY) -- run examples/local-skill/main.cml --skills examples/local-skill/skills --input-json '$(LOCAL_SKILL_INPUT)'

run-qualified:
	$(DUNE) exec $(BINARY) -- run examples/qualified-imports/main.cml --input-json '$(BASIC_INPUT)'

run-recursion:
	$(DUNE) exec $(BINARY) -- run examples/recursion/main.cml --input-json '$(RECURSION_INPUT)'

run-inline-agent:
	$(DUNE) exec $(BINARY) -- run examples/inline-agent/main.cml --input-json '$(INLINE_AGENT_INPUT)'

run-provider-hooks:
	$(DUNE) exec examples/provider-hooks/host.exe
