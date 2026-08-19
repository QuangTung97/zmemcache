.PHONY: test
test:
	zig build test

.PHONY: stat
stat:
	du -h -d0 .

.PHONY: clean
clean:
	rm -rf .zig-cache
