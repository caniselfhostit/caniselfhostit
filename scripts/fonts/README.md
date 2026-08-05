# Vendored fonts — build-time only

These four files exist for exactly one reason: `satori` (see `scripts/generate-og.mjs`)
rasterises text itself and needs **static** TTF/OTF binaries handed to it as buffers.
It cannot read the `woff2` variable fonts the site ships to browsers via the
`@fontsource-variable/*` packages, and it does not instantiate variable axes — a
variable TTF renders at its default instance, so asking for weight 600 would
silently give you weight 400. Hence: static cuts, committed, one per weight we use.

Nothing here is served to a browser. The web pages load the same families through
`@fontsource-variable/newsreader`, `@fontsource-variable/inter` and
`@fontsource/ibm-plex-mono` (identical licences).

All four are **SIL Open Font License 1.1 (OFL-1.1)**, which permits redistribution
of the font files as long as the licence travels with them and they are not sold on
their own. Full licence texts live with each upstream, linked below.

## Provenance

Downloaded 2026-08-05. Each line is the exact URL the committed bytes came from,
plus the SHA-256 of the file as committed — re-run `shasum -a 256 *.ttf` to check
that what is in the repo is still what was fetched.

| File | Family / weight | Licence | Source URL | SHA-256 |
|---|---|---|---|---|
| `Newsreader-SemiBold.ttf` | Newsreader, 600 | OFL-1.1 | `https://raw.githubusercontent.com/productiontype/Newsreader/master/fonts/static/ttf/Newsreader16pt-SemiBold.ttf` | `9e29bad1d5022c1a3d1822469a62dc9fa66cc41ba553f352530f867f84ba1c8f` |
| `Inter-Regular.ttf` | Inter, 400 | OFL-1.1 | `https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuLyfMZg.ttf` | `1b08e7fc267a5c7e1d614100f604b83e7e8a0be241f0f288faa2b3ac93a683ba` |
| `Inter-SemiBold.ttf` | Inter, 600 | OFL-1.1 | `https://fonts.gstatic.com/s/inter/v20/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuGKYMZg.ttf` | `e7a1aaf7eda9f2fad4131725fa556265ec75ca7b2d756260173a040363e8d4f7` |
| `IBMPlexMono-Regular.ttf` | IBM Plex Mono, 400 | OFL-1.1 | `https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Regular.ttf` | `6a3412f058c7d8dfd9170c41e85ade48e5156ecb89356110ca57a0a27734af46` |

### Upstream projects and licence texts

- **Newsreader** — Production Type / The Newsreader Project Authors ·
  <https://github.com/productiontype/Newsreader> · licence:
  <https://github.com/productiontype/Newsreader/blob/master/OFL.txt>
- **Inter** — Rasmus Andersson · <https://github.com/rsms/inter> · licence:
  <https://github.com/rsms/inter/blob/master/LICENSE.txt>
- **IBM Plex Mono** — IBM · <https://github.com/IBM/plex> · licence:
  <https://github.com/IBM/plex/blob/master/LICENSE.txt>

### Two notes on the choices, because they are not obvious

**Newsreader is the 16 pt optical cut, filed here under the plain name.** Newsreader
carries an `opsz` axis and Production Type ships static instances at 6 pt, 16 pt and
72 pt. A browser rendering the variable font at a 60 px heading picks something near
the 72 pt cut, whose hairlines are thinner. On an OG card those hairlines have to
survive PNG palette quantisation and then a third party's CDN re-encode, so the
sturdier 16 pt text cut is the deliberate choice. It is the same typeface; only the
optical size differs.

**Inter comes from `fonts.gstatic.com`, not from a GitHub path.** The upstream
`rsms/inter` repository ships only `woff2` in-tree — the TTFs are inside a release
zip — and `google/fonts` carries Inter only as a variable TTF. The two URLs above are
the static 400 and 600 instances that Google Fonts itself serves, obtained by asking
the CSS API for the families with a user agent that predates `woff2`:

```sh
curl -A "Mozilla/5.0 (Windows NT 5.1)" \
  "https://fonts.googleapis.com/css2?family=Inter:wght@400;600"
```

Those URLs carry a content hash and will change when Google reissues the family; the
SHA-256 column above is what pins the bytes we actually shipped. Re-derive the URLs
with the command above if a refresh is ever needed.
