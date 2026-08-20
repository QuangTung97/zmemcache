.PHONY: test
test:
	zig build test

.PHONY: test-race
test-race:
	zig build test -Dtsan

.PHONY: stat
stat:
	du -h -d0 .

.PHONY: clean
clean:
	rm -rf .zig-cache
