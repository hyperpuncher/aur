# aur

my AUR package templates and update automation.
generated `PKGBUILD` and `.SRCINFO` files live in AUR.

the workflow checks releases daily at 06:23 UTC and publishes version bumps.
unchanged recipes are not pushed. publication uses the `AUR_KEY` secret.

## maintenance

- templates: `<package-name>/PKGBUILD.in`
- upstream: the template's GitHub `url`
- placeholders: `@VERSION@`, `@SHA256_X86_64@`, `@SHA256_AARCH64@`
- supported releases: `vX.Y.Z` tags with a `SHA256SUMS` asset
- packaging-only changes: increase `pkgrel`

local generation, without publication:

```sh
bash scripts/prepare-aur.sh build/aur
```

checks:

```sh
bash scripts/prepare-aur.test.sh
shellcheck scripts/*.sh
actionlint
```
