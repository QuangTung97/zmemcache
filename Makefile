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

.PHONY: build
build:
	zig build -Doptimize=Debug

.PHONY: perf
perf:
	perf record --call-graph fp ./zig-out/bin/zmemcache

.PHONY: enable-perf
enable-perf:
	sudo sysctl kernel.perf_event_paranoid=-1
	sudo sysctl kernel.kptr_restrict=0

.PHONY: release
release:
	zig build -Doptimize=ReleaseFast -Dcpu=native
