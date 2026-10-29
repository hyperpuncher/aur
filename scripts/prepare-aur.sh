#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root as a non-root user. Requires gh and makepkg.
out=${1:?output directory required}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/downloads" "$work/packages"
declare -A releases checksums

for template in */PKGBUILD.in; do
	metadata=$(bash -c 'source "$1"; printf "%s\t%s" "$url" "${_release:-latest}"' bash "$template")
	IFS=$'\t' read -r url release <<< "$metadata"
	if [[ ! $url =~ ^https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$ ]]; then
		printf 'template url must identify a GitHub repository: %s\n' "$template" >&2
		exit 1
	fi
	repo=${BASH_REMATCH[1]}
	key="$repo/$release"
	if [[ ! -v releases[$key] ]]; then
		endpoint=latest
		if [[ $release != latest ]]; then
			endpoint="tags/$release"
		fi
		releases[$key]=$(gh api "repos/${repo}/releases/$endpoint" \
			--jq '[.tag_name, (.assets[]? | select(.name == "SHA256SUMS") | .updated_at)] | @tsv')
	fi
	IFS=$'\t' read -r tag built <<< "${releases[$key]}"
	if [[ $release == latest ]]; then
		if [[ ! $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
			printf 'unsupported release tag for %s: %s\n' "$repo" "$tag" >&2
			exit 1
		fi
		version=${BASH_REMATCH[1]}
	else
		if [[ -z $built ]]; then
			printf 'missing snapshot build time for %s %s\n' "$repo" "$tag" >&2
			exit 1
		fi
		version=$(date --utc --date "$built" +%Y%m%d.%H%M%S)
	fi
	downloads="$work/downloads/$key"
	mkdir -p "$downloads"
	if [[ ! -f $downloads/SHA256SUMS ]]; then
		gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --dir "$downloads"
	fi
	checksums=()
	while read -r checksum filename; do
		checksums["$filename"]=$checksum
	done < "$downloads/SHA256SUMS"

	package=${template%/PKGBUILD.in}
	directory="$work/packages/$package"
	mkdir "$directory"
	pkgbuild="$directory/PKGBUILD"
	sed "s/@VERSION@/$version/g" "$template" > "$pkgbuild"
	while read -r architecture url; do
		filename=${url##*/}
		checksum=${checksums[$filename]:-}
		if [[ ! $checksum =~ ^[[:xdigit:]]{64}$ ]]; then
			printf 'missing or invalid upstream checksum: %s\n' "$filename" >&2
			exit 1
		fi
		if [[ ! -f $downloads/$filename ]]; then
			gh release download "$tag" --repo "$repo" --pattern "$filename" --dir "$downloads"
		fi
		printf '%s  %s\n' "$checksum" "$downloads/$filename" | sha256sum --check
		sed -i "s/@SHA256_${architecture^^}@/$checksum/g" "$pkgbuild"
	done < <(bash -c '
		source "$1"
		for architecture in "${arch[@]}"; do
			declare -n sources="source_${architecture}"
			printf "%s %s\n" "$architecture" "${sources[0]}"
		done
	' bash "$pkgbuild")
	if [[ $(<"$pkgbuild") =~ @(VERSION|SHA256_[A-Z0-9_]+)@ ]]; then
		printf 'unfilled template: %s\n' "$template" >&2
		exit 1
	fi
	bash -n "$pkgbuild"
	makepkg --dir "$directory" --printsrcinfo > "$directory/.SRCINFO"
	printf 'prepared %s from %s %s\n' "$package" "$repo" "$tag"
done

# Publish no output until every required download has passed verification.
mkdir -p "$out"
cp -a "$work/packages/." "$out/"
printf 'generated AUR recipes in %s\n' "$out"
