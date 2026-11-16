.PHONY: all precommit

all:
	swift test
	scripts/build-app.sh

precommit:
	mkdir -p "$$(git rev-parse --git-path hooks)"
	install -m 755 scripts/pre-commit "$$(git rev-parse --git-path hooks)/pre-commit"
