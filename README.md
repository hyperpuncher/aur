# aur

my AUR package templates and daily update automation.
generated recipes and version history live in AUR.

`pkgctl` and `nvchecker` check upstream versions and reset `pkgrel` on upgrades.
AUR supplies the current revision. packaging-only changes increment it automatically.
unchanged recipes are not pushed.

## maintenance

- `<package-name>/PKGBUILD.in`: package instructions
- `<package-name>/.nvchecker.toml`: upstream version checks
- placeholders: `@VERSION@`, `@SHA256_X86_64@`, `@SHA256_AARCH64@`
- templates keep `pkgrel=1`; published revisions are managed automatically
- publication: daily at 06:23 UTC, using the `AUR_KEY` secret

local generation, without publication, needs `devtools`, `nvchecker`, `python-jq`,
and `github-cli`:

```sh
bash scripts/prepare-aur.sh build/aur
```

nightly downloads use versioned cache names. older recipes can fail verification
when upstream replaces the files.

checks:

```sh
bash scripts/prepare-aur.test.sh
shellcheck scripts/*.sh
actionlint
```
