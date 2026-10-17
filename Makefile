.PHONY: test lint format

test:
	busted < /dev/null

lint:
	stylua --check .

format:
	stylua .
