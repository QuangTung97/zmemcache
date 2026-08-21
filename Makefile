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

.PHONY: perf
perf:
	perf record --call-graph dwarf ./zig-out/bin/zmemcach

.PHONY: enable-perf
enable-perf:
	sudo sysctl kernel.perf_event_paranoid=-1
	sudo sysctl kernel.kptr_restrict=0
