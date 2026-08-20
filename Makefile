.PHONY: test
test:
	zig build test

.PHONY: test-race
test-race:
	zig build test -Dtsan --summary all

.PHONY: stat
stat:
	du -h -d0 .

.PHONY: clean
clean:
	rm -rf .zig-cache
