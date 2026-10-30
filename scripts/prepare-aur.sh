#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root as a non-root user.
out=${1:?output directory required}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/downloads" "$work/packages"

# AUR is the source of the current version and packaging revision.
query=()
for template in */PKGBUILD.in; do
	query+=(--data-urlencode "arg[]=${template%/PKGBUILD.in}")
done
published=$(curl --fail --silent --show-error --get \
	https://aur.archlinux.org/rpc/v5/info "${query[@]}")
declare -A checksums

for template in */PKGBUILD.in; do
	package=${template%/PKGBUILD.in}
	directory="$work/packages/$package"
	mkdir "$directory"
	current=$(jq -r --arg name "$package" \
		'[.results[] | select(.Name == $name)][0].Version // "0-1"' <<< "$published")
	version=${current%-*}
	revision=${current##*-}
	pkgbuild="$directory/PKGBUILD"
	sed -e "s/@VERSION@/${version#*:}/g" -e "s/^pkgrel=.*/pkgrel=$revision/" \
		"$template" > "$pkgbuild"
	cp "$package/.nvchecker.toml" "$directory/"
	pkgctl version upgrade --no-update-checksums "$directory"

	metadata=$(bash -c 'source "$1"; printf "%s\t%s" "$url" "${_release:-v$pkgver}"' bash "$pkgbuild")
	IFS=$'\t' read -r url tag <<< "$metadata"
	if [[ ! $url =~ ^https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$ ]]; then
		printf 'template url must identify a GitHub repository: %s\n' "$template" >&2
		exit 1
	fi
	repo=${BASH_REMATCH[1]}
	downloads="$work/downloads/$repo/$tag"
	if [[ ! -f $downloads/SHA256SUMS ]]; then
		mkdir -p "$downloads"
		gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --dir "$downloads"
	fi
	checksums=()
	while read -r checksum filename; do
		checksums["$filename"]=$checksum
	done < "$downloads/SHA256SUMS"

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
	makepkg --dir "$directory" --printsrcinfo > "$directory/.SRCINFO"
	printf 'prepared %s from %s %s\n' "$package" "$repo" "$tag"
done

# Do not expose partial output if a check fails.
mkdir -p "$out"
cp -a "$work/packages/." "$out/"
printf 'generated AUR recipes in %s\n' "$out"
