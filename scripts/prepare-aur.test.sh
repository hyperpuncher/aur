#!/usr/bin/env bash
set -euo pipefail

root=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/repo" "$work/bin" "$work/release"
cp -a "$root"/nemo-speech-*-bin "$work/repo/"
export TEST_RELEASE_DIR="$work/release"
export TEST_TAG=v0.2.1
export TEST_OTHER_TAG=v1.2.3

# Replace only the GitHub boundary. Use real makepkg and checksum tools.
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == api ]]; then
	if [[ $2 == repos/example/other/releases/latest ]]; then
		printf '%s\n' "$TEST_OTHER_TAG"
	else
		printf '%s\n' "$TEST_TAG"
	fi
	exit 0
fi
pattern= directory= repo=
while (( $# )); do
	case $1 in
		--pattern) pattern=$2; shift ;;
		--dir) directory=$2; shift ;;
		--repo) repo=$2; shift ;;
	esac
	shift
done
cp "$TEST_RELEASE_DIR/$repo/$pattern" "$directory/"
GH
chmod +x "$work/bin/gh"

prepare() {
	(cd "$work/repo"; PATH="$work/bin:$PATH" bash "$root/scripts/prepare-aur.sh" "$work/output")
}

export TEST_TAG=unexpected-tag
if prepare; then
	printf 'expected unsupported tag rejection\n' >&2
	exit 1
fi
test ! -e "$work/output"
export TEST_TAG=v0.2.1
printf 'ok: unsupported release creates no output\n'

release="$work/release/NVIDIA/NeMo-Speech.cpp"
mkdir -p "$release"
for platform in x86_64-cpu x86_64-cuda x86_64-vulkan aarch64-cpu aarch64-cuda12 aarch64-cuda13 aarch64-vulkan; do
	printf '%s\n' "$platform" > "$work/marker"
	tar -czf "$release/nemo-speech-0.2.1-linux-${platform}.tar.gz" -C "$work" marker
done
(cd "$release"; sha256sum ./*.tar.gz) > "$work/checksums"
while read -r hash filename; do
	printf '%s  %s\n' "$hash" "${filename#./}"
done < "$work/checksums" > "$work/complete-checksums"

touch "$release/SHA256SUMS"
if prepare; then
	printf 'expected missing checksum rejection\n' >&2
	exit 1
fi
test ! -e "$work/output"
printf 'ok: missing checksums create no output\n'
cp "$work/complete-checksums" "$release/SHA256SUMS"

asset="$release/nemo-speech-0.2.1-linux-x86_64-vulkan.tar.gz"
cp "$asset" "$work/original-asset"
printf 'corrupt\n' >> "$asset"
if prepare; then
	printf 'expected corrupt archive rejection\n' >&2
	exit 1
fi
test ! -e "$work/output"
printf 'ok: a checksum failure creates no partial output\n'
cp "$work/original-asset" "$asset"

# A second upstream uses a different release version and its own checksum list.
mkdir -p "$work/release/example/other" "$work/repo/example-bin"
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
printf 'other project\n' > "$work/marker"
tar -czf "$work/release/example/other/example-1.2.3.tar.gz" -C "$work" marker
(cd "$work/release/example/other"; sha256sum example-1.2.3.tar.gz > SHA256SUMS)
cp -a "$work/repo" "$work/templates"
prepare
bash -c 'source "$1"; [[ $pkgver == 1.2.3 ]]' bash "$work/output/example-bin/PKGBUILD"
SRCDEST="$work/release/example/other" makepkg --dir "$work/output/example-bin" --verifysource
for package in "$work/output"/nemo-speech-*-bin; do
	bash -c 'source "$1"; [[ $pkgver == 0.2.1 && $pkgrel == 1 ]]' bash "$package/PKGBUILD"
	diff -u "$package/.SRCINFO" <(makepkg --dir "$package" --printsrcinfo)
	while read -r architecture; do
		printf 'source /etc/makepkg.conf\nCARCH=%s\n' "$architecture" > "$work/makepkg.conf"
		SRCDEST="$release" makepkg --config "$work/makepkg.conf" --dir "$package" --verifysource
	done < <(bash -c 'source "$1"; printf "%s\n" "${arch[@]}"' bash "$package/PKGBUILD")
done
printf 'ok: all generated recipes and architecture checksums pass makepkg\n'
cp -a "$work/output" "$work/previous-output"
prepare
diff -r "$work/previous-output" "$work/output"
diff -r "$work/templates" "$work/repo"
printf 'ok: repeated generation is identical and templates stay unchanged\n'
