.PHONY: all
all: compile

.PHONY: compile
compile:
	@docker run \
		--rm \
		--interactive \
		--tty \
		--mount type="bind",source="$(PWD)/policies",target="/policies",readonly \
		--mount type="bind",source="$(PWD)/tests",target="/tests",readonly \
		ghcr.io/cerbos/cerbos:dev \
		compile \
		--tests /tests \
		/policies
