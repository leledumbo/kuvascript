# kuvascript - build with Free Pascal (https://www.freepascal.org/)
#
#   make            build bin/kuvascript
#   make test       build and run the unit tests
#   make example    build examples/hello into examples/hello/output
#   make install    install under $(PREFIX) (default /usr/local)
#   make clean

FPC      ?= fpc
PREFIX   ?= /usr/local
FPCFLAGS  = -Mobjfpc -Sh -Se -O2 -FUbuild -FEbin -Fusrc

SOURCES = $(wildcard src/*.pas src/*.lpr)

all: bin/kuvascript

bin/kuvascript: $(SOURCES)
	@mkdir -p bin build
	$(FPC) $(FPCFLAGS) -Xs src/kuvascript.lpr

bin/kvtests: $(SOURCES) $(wildcard tests/*.pas tests/*.lpr)
	@mkdir -p bin build
	$(FPC) -Mobjfpc -Sh -g -FUbuild -FEbin -Fusrc -Futests tests/kvtests.lpr

# the tests read examples/ and template/, so they run from the repository root
test: bin/kvtests
	./bin/kvtests --all --format=plain

example: bin/kuvascript
	bin/kuvascript examples/hello

install: bin/kuvascript
	install -D -m 755 bin/kuvascript $(DESTDIR)$(PREFIX)/bin/kuvascript
	install -D -m 644 template/viewer.html $(DESTDIR)$(PREFIX)/share/kuvascript/viewer.html

clean:
	rm -rf bin build examples/*/output

.PHONY: all test example install clean
