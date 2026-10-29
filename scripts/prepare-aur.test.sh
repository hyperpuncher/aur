#!/usr/bin/env bash
# Package variables are loaded from sourced recipes.
# shellcheck disable=SC2154
set -euo pipefail

root=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/repo" "$work/bin" "$work/release"
for template in "$root"/*/PKGBUILD.in; do bash -n "$template"; done
cp -a "$root"/nemo-speech-cpu{,-nightly}-bin "$work/repo/"
export TEST_RELEASE_DIR="$work/release"
export TEST_TAG=v0.2.1 TEST_OTHER_TAG=v1.2.3 TEST_NIGHTLY_TIME=2026-10-28T20:34:48Z

# Only GitHub is replaced. Generation uses the real makepkg and checksum tools.
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == api ]]; then
	case $2 in
		*/releases/tags/nightly) printf 'nightly\t%s\n' "$TEST_NIGHTLY_TIME" ;;
		repos/example/other/releases/latest) printf '%s\n' "$TEST_OTHER_TAG" ;;
		*) printf '%s\n' "$TEST_TAG" ;;
	esac
	exit 0
fi
tag=$3
pattern= directory= repo=
while (( $# )); do
	case $1 in
		--pattern) pattern=$2; shift ;;
		--dir) directory=$2; shift ;;
		--repo) repo=$2; shift ;;
	esac
	shift
done
cp "$TEST_RELEASE_DIR/$repo/$tag/$pattern" "$directory/"
GH
chmod +x "$work/bin/gh"

prepare() {
	(cd "$work/repo"; PATH="$work/bin:$PATH" bash "$root/scripts/prepare-aur.sh" "$work/output")
}

for channel in 0.2.1 nightly; do
	tag=v$channel
	if [[ $channel == nightly ]]; then tag=nightly; fi
	directory="$work/release/NVIDIA/NeMo-Speech.cpp/$tag"
	mkdir -p "$directory"
	for platform in x86_64-cpu aarch64-cpu; do
		printf '%s %s\n' "$channel" "$platform" > "$work/marker"
		tar -czf "$directory/nemo-speech-${channel}-linux-${platform}.tar.gz" -C "$work" marker
	done
	(cd "$directory"; sha256sum -- *.tar.gz > SHA256SUMS)
done

# A second upstream proves that versions and checksums are not shared by project.
mkdir -p "$work/release/example/other/v1.2.3" "$work/repo/example-bin"
cat > "$work/repo/example-bin/PKGBUILD.in" <<'TEMPLATE'
pkgname=example-bin
pkgver=@VERSION@
pkgrel=1
arch=('x86_64')
url='https://github.com/example/other'
source_x86_64=("${url}/releases/download/v${pkgver}/example-${pkgver}.tar.gz")
sha256sums_x86_64=('@SHA256_X86_64@')
package() { :; }
TEMPLATE
other="$work/release/example/other/v1.2.3"
printf 'other project\n' > "$work/marker"
tar -czf "$other/example-1.2.3.tar.gz" -C "$work" marker
(cd "$other"; sha256sum -- *.tar.gz > SHA256SUMS)
cp -a "$work/repo" "$work/templates"
prepare

# Cover stable, nightly, both architectures, and a different upstream.
for template in "$work/templates"/*/PKGBUILD.in; do
	package=${template%/PKGBUILD.in}
	package=${package##*/}
	directory="$work/output/$package"
	version=0.2.1
	if [[ $package == *-nightly-bin ]]; then version=20261028.203448; fi
	if [[ $package == example-bin ]]; then version=1.2.3; fi
	(
		# shellcheck source=/dev/null
		source "$template"
		rel=$pkgrel
		# shellcheck source=/dev/null
		source "$directory/PKGBUILD"
		[[ $pkgname == "$package" && $pkgver == "$version" && $pkgrel == "$rel" ]]
		grep -Fxq "pkgname = $package" "$directory/.SRCINFO"
		grep -Fxq "$(printf '\tpkgver = %s' "$version")" "$directory/.SRCINFO"
		grep -Fxq "$(printf '\tpkgrel = %s' "$rel")" "$directory/.SRCINFO"
		for architecture in "${arch[@]}"; do
			declare -n sources="source_$architecture" hashes="sha256sums_$architecture"
			entry=${sources[0]}
			url=${entry#*::}
			asset="$work/release/${url#https://github.com/}"
			asset=${asset/\/releases\/download/}
			hash=$(sha256sum "$asset")
			[[ ${hashes[0]} == "${hash%% *}" ]]
			grep -Fxq "$(printf '\tsource_%s = %s' "$architecture" "$entry")" "$directory/.SRCINFO"
			grep -Fxq "$(printf '\tsha256sums_%s = %s' "$architecture" "${hash%% *}")" "$directory/.SRCINFO"
			if [[ $package == *-nightly-bin ]]; then
				[[ $entry == *"$version"*::* && $url == */nightly/nemo-speech-nightly-* ]]
			fi
		done
	)
done
diff -r "$work/templates" "$work/repo"
cp -a "$work/output" "$work/expected"
printf 'ok: stable, nightly, architectures, metadata, and upstreams verified\n'

# Snapshot checks need only the nightly template.
mv "$work/repo" "$work/all-templates"
mkdir "$work/repo"
cp -a "$work/all-templates/nemo-speech-cpu-nightly-bin" "$work/repo/"

reject() {
	if prepare > "$work/failure.log" 2>&1; then
		printf 'expected failure: %s\n' "$1" >&2
		exit 1
	fi
	grep -Fq -- "$1" "$work/failure.log"
	diff -r "$work/expected" "$work/output"
}

# A pending stable change makes partial writes visible if nightly generation fails.
cp -a "$work/all-templates/nemo-speech-cpu-bin" "$work/repo/"
sed -i 's/^pkgrel=1$/pkgrel=9/' "$work/repo/nemo-speech-cpu-bin/PKGBUILD.in"
export TEST_TAG=unexpected-tag
reject 'unsupported release tag'
export TEST_TAG=v0.2.1
manifest="$work/release/NVIDIA/NeMo-Speech.cpp/v0.2.1/SHA256SUMS"
cp "$manifest" "$work/checksums"
printf '' > "$manifest"
reject 'missing or invalid upstream checksum'
cp "$work/checksums" "$manifest"
asset="$work/release/NVIDIA/NeMo-Speech.cpp/nightly/nemo-speech-nightly-linux-x86_64-cpu.tar.gz"
cp "$asset" "$work/archive"
printf 'corrupt\n' >> "$asset"
reject 'computed checksum did NOT match'
cp "$work/archive" "$asset"
mv "$work/repo/nemo-speech-cpu-bin" "$work/pending-stable"
export TEST_NIGHTLY_TIME=
reject 'missing snapshot build time'
export TEST_NIGHTLY_TIME=2026-10-29T20:34:48Z
printf 'ok: each failure reports its cause and preserves existing output\n'

prepare
snapshot="$work/output/nemo-speech-cpu-nightly-bin"
(
	# shellcheck source=/dev/null
	source "$snapshot/PKGBUILD"
	[[ $pkgver == 20261029.203448 && ${source_aarch64[0]} == *"$pkgver"*::* ]]
)
# Only this nightly package should change; compare everything else byte for byte.
cp "$snapshot/PKGBUILD" "$snapshot/.SRCINFO" "$work/expected/nemo-speech-cpu-nightly-bin/"
diff -r "$work/expected" "$work/output"
diff -r "$work/templates" "$work/all-templates"
printf 'ok: a new nightly changes its version and cache name, not stable recipes\n'
