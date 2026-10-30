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
export TEST_RELEASE_DIR="$work/release" TEST_AUR_INFO="$work/aur.json"
export TERM=dumb

# Only remote boundaries are replaced; pkgctl, nvchecker, and makepkg are real.
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == *https://aur.archlinux.org/rpc/v5/info* ]]
cat "$TEST_AUR_INFO"
CURL
cat > "$work/aur.json" <<'JSON'
{"results":[
  {"Name":"nemo-speech-cpu-bin","Version":"0.2.0-5"},
  {"Name":"nemo-speech-cpu-nightly-bin","Version":"20261028.203448-3"}
]}
JSON
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == release && $2 == download ]]
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
chmod +x "$work/bin/curl" "$work/bin/gh"

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

# nvchecker's manual source supplies local upstream fixtures without HTTP.
for entry in 'nemo-speech-cpu-bin 0.2.1' 'nemo-speech-cpu-nightly-bin 20261028.203448'; do
	read -r package version <<< "$entry"
	printf '["%s"]\nsource = "manual"\nmanual = "%s"\n' "$package" "$version" \
		> "$work/repo/$package/.nvchecker.toml"
done
prepare

for template in "$work/repo"/*/PKGBUILD.in; do
	package=${template%/PKGBUILD.in}
	package=${package##*/}
	directory="$work/output/$package"
	version=0.2.1 rel=1
	if [[ $package == *-nightly-bin ]]; then version=20261028.203448; rel=3; fi
	(
		# shellcheck source=/dev/null
		source "$directory/PKGBUILD"
		[[ $pkgname == "$package" && $pkgver == "$version" && $pkgrel == "$rel" ]]
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
		done
	)
done
cp -a "$work/output" "$work/expected"
printf 'ok: published revisions preserved; pkgctl resets a new upstream version to 1\n'

reject() {
	if prepare > "$work/failure.log" 2>&1; then
		printf 'expected failure: %s\n' "$1" >&2
		exit 1
	fi
	grep -Fq -- "$1" "$work/failure.log"
	diff -r "$work/expected" "$work/output"
}

# A pending stable change exposes partial writes on failure.
sed -i "s/^pkgdesc=.*/pkgdesc='pending packaging change'/" "$work/repo/nemo-speech-cpu-bin/PKGBUILD.in"
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
printf 'ok: invalid downloads preserve existing output\n'

mv "$work/repo/nemo-speech-cpu-bin" "$work/pending-stable"
sed -i 's/20261028.203448/20261029.203448/' "$work/repo/nemo-speech-cpu-nightly-bin/.nvchecker.toml"
prepare
snapshot="$work/output/nemo-speech-cpu-nightly-bin"
(
	# shellcheck source=/dev/null
	source "$snapshot/PKGBUILD"
	[[ $pkgver == 20261029.203448 && $pkgrel == 1 && ${source_aarch64[0]} == *"$pkgver"*::* ]]
)
cp "$snapshot/PKGBUILD" "$snapshot/.SRCINFO" "$snapshot/.nvchecker.toml" "$work/expected/nemo-speech-cpu-nightly-bin/"
diff -r "$work/expected" "$work/output"
printf 'ok: pkgctl resets a new snapshot to 1 without changing stable recipes\n'
