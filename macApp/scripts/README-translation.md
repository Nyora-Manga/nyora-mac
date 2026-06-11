# Japanese translation in Nyora-mac

## What works (May 2026)

End-to-end side-by-side translation sheet. Press ⌘T in the reader and a
panel opens with:

- Left: the manga page image
- Right: every text region we could OCR + its translation (one row per line)

Pipeline per page:

1. **Download** the page image through the helper proxy.
2. **Apple Vision** ensemble OCR (4 language passes: `ja-JP`, `zh-Hans`,
   `ko-KR`, `en-US`) catches all horizontal text + most Latin captions.
3. **manga-ocr CoreML** (bundled, ~210 MB) reads vertical Japanese
   (tategaki) — Vision can't handle that on its own. A 4×5 grid of
   overlapping tiles is OCR'd; tiles without a strong luminance signature
   are skipped (saves ~30% of the work).
4. Both result sets are deduped (IoU + similar-text matching) and
   pre-filtered for runaway repetition / scanlator credits / empty
   `....` outputs / pure-number garbage.
5. **Google Translate** (unofficial endpoint, free, no key) translates
   every surviving line into your target language.

Settings → AI Translation:

- **Source language** — set to `Japanese` for the manga-ocr path to kick in.
- **Target language** — defaults to English; Hindi works.
- **Use bundled manga-ocr model for Japanese** — keep this ON.
- **LLM Provider (BYOK)** — optional. If you paste a Mistral / OpenAI key
  it'll polish the Google Translate output into manga-quality English.
  Without a key, you just see the raw Google translation.

## How to run during development

`swift run` and direct invocation of the SwiftPM binary doesn't open a
window (raw Mach-O without an .app bundle gets treated as a headless
background process by macOS launchd on recent OS versions). Use:

```
./scripts/dev-launch.sh
```

This builds, wraps the binary in `/tmp/Nyora-dev.app` (full with Info.plist,
CoreML models, helper jar, ad-hoc signed) and `open`s it. Re-run any time
after a code change — it's idempotent.

## How to ship a release build

```
./scripts/build-dmg.sh
```

Produces a notarisable `.dmg` containing `Nyora.app` with the bundled
Java runtime and the manga-ocr CoreML model.

## Debug log

Every step of the translation pipeline writes to `/tmp/nyora_translate.log`:

```
[Sheet] openTranslationSheet called, chapterId=…, pageIdx=N
[Sheet] image decoded WxH
[Sheet] Vision OCR → N lines (after dedupe/credits filter)
[Sheet] Reading bubbles (k/20)…
[CoreMLMangaOcr] decoded N tokens → 'それは、'
[Sheet] manga-ocr tile pass → M new lines
[Sheet] starting translation of K total lines, target=en
[Sheet] complete — K entries displayed
```

Tail it while pressing ⌘T to see exactly what each stage produced.

## Known limits

- Vision's text detection misses speech bubbles entirely on some pages.
  The 4×5 grid pass catches most of those, but very small bubbles
  between panels may still be skipped.
- manga-ocr occasionally hallucinates short repeating tokens
  ("くっくっくっ…"); the decoder bails after 4× same-token repetition.
- All Latin captions get OCR'd via Vision too — useful for already-
  translated chapters but produces some noise on pages with no original
  Latin text.
