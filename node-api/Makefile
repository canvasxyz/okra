FLAGS=-dynamic -fallow-shlib-undefined -lc -O ReleaseSafe
MODULES=--deps okra --mod okra:lmdb:../src/lib.zig --mod lmdb::../lmdb/lib.zig
INCLUDES=-isystem /usr/local/include/node -I../libs/openldap/libraries/liblmdb
SOURCES=../libs/openldap/libraries/liblmdb/mdb.c ../libs/openldap/libraries/liblmdb/midl.c src/lib.zig

all: build/x64-linux-glibc build/x64-linux-musl build/arm64-linux-glibc build/arm64-linux-musl build/x64-darwin build/arm64-darwin

build/x64-linux-glibc:
	mkdir -p build/x64-linux-glibc
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target x86_64-linux-gnu -femit-bin=build/x64-linux-glibc/okra.node

build/x64-linux-musl:
	mkdir -p build/x64-linux-musl
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target x86_64-linux-musl -femit-bin=build/x64-linux-musl/okra.node

build/arm64-linux-glibc:
	mkdir -p build/arm64-linux-glibc
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target aarch64-linux-gnu -femit-bin=build/arm64-linux-glibc/okra.node

build/arm64-linux-musl:
	mkdir -p build/arm64-linux-musl
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target aarch64-linux-musl -femit-bin=build/arm64-linux-musl/okra.node

build/x64-darwin:
	mkdir -p build/x64-darwin
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target x86_64-macos -femit-bin=build/x64-darwin/okra.node

build/arm64-darwin:
	mkdir -p build/arm64-darwin
	zig build-lib ${FLAGS} ${MODULES} ${INCLUDES} ${SOURCES} -target aarch64-macos -femit-bin=build/arm64-darwin/okra.node

clean:
	rm -rf build/