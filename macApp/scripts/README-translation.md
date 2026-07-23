<div align="center">

<img src="https://nyora.xyz/icon.png" width="120" alt="Nyora icon" />

# Nyora — TRANSLATE Pipeline (macOS)

### Read like the world can wait.

**Read any manga page in your own language.** Press <kbd>⌘T</kbd> and Nyora finds the text on the page, translates it, and shows the original art beside its translation — text recognition runs entirely on your Mac, no account, no subscription, no per-page billing.

[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://www.swift.org)
[![Core ML](https://img.shields.io/badge/Core_ML-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/documentation/coreml)
[![Apple](https://img.shields.io/badge/Apple-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/documentation/vision)

[![Website](https://img.shields.io/badge/Website-nyora.xyz-FF4655?style=for-the-badge&logo=githubpages&logoColor=white)](https://nyora.xyz)
[![Open Web App](https://img.shields.io/badge/Open-Web_App-5A0FC8?style=for-the-badge&logo=pwa&logoColor=white)](https://nyora.xyz)
[![Download DMG](https://img.shields.io/badge/Download-.dmg-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Nyora-Manga/nyora-mac/releases/latest)

[![License](https://img.shields.io/badge/License-Apache_2.0-D22128?style=for-the-badge&logo=apache&logoColor=white)](#license)
[![Status](https://img.shields.io/badge/Status-Shipping_May_2026-2EA44F?style=for-the-badge)](#what-works-may-2026)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-0A84FF?style=for-the-badge&logo=github&logoColor=white)](#contributing)

</div>

---

> The honest, technical reference for the macOS Japanese TRANSLATE pipeline — exactly what runs when you press <kbd>⌘T</kbd>, with no marketing and no overstatement. For the consumer overview of Nyora and the other four pillars (DOWNLOAD, SOURCES, SYNC, OPEN-SOURCE), see the [product site](https://nyora.xyz).

## What you get

A side-by-side translation sheet for the page you are reading: the original art on the left, every recognised line paired with its translation on the right. Recognition happens on your Mac with Apple Vision and a bundled CoreML model; only the short translation step touches the network, through a free, keyless endpoint. **It is open-source and auditable, there are no ads, no tracking, and no account is needed to read.** You can have it running in about a minute — see [Install](#install).

## Why you'll love it

- **It reads the page for you.** Whole-page translation, not one bubble at a time — including vertical Japanese (tategaki), the script most OCR tools choke on.
- **It respects your privacy.** The page image is never uploaded for translation; only the cleaned text lines leave your machine. No analytics live in the pipeline.
- **It costs nothing to use.** No key, no account, no subscription. An optional bring-your-own-key LLM polish exists if you want manga-quality phrasing — but it is never required.
- **You can verify every claim here.** The whole pipeline is open-source under Apache-2.0, and every stage writes to a log you can read yourself.

## Install

> [![Download DMG](https://img.shields.io/badge/Download-.dmg-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Nyora-Manga/nyora-mac/releases/latest) — grab the latest `.dmg` from the [Releases page](https://github.com/Nyora-Manga/nyora-mac/releases/latest), open it, and drag **Nyora** to your Applications folder. That's it.

**"Nyora can't be opened because Apple cannot check it for malware" — this is expected, and it's safe.** Nyora ships as an open-source app that is not signed through Apple's paid notarisation service, so Gatekeeper shows that warning on first launch. It does not mean anything is wrong — it means macOS hasn't been told who the developer is. Because the entire source tree is public, you can audit exactly what the app does before trusting it. To open it the first time:

1. In **Finder**, open your **Applications** folder and find **Nyora**.
2. **Right-click** (or Control-click) the app and choose **Open**.
3. Click **Open** in the dialog that appears.

You only need to do this once; after the first launch the app opens normally. (If you prefer Homebrew, you can install and update via `brew` from the [release page](https://github.com/Nyora-Manga/nyora-mac/releases/latest).)

Once installed, open a chapter, press <kbd>⌘T</kbd>, and the translation sheet opens.

## About

TRANSLATE is one of Nyora's five pillars: whole-page AI translation typeset over the original art. On macOS, text recognition runs **entirely on-device**, and only the language-conversion step touches the network — through a free, keyless endpoint, with no account, no subscription and no per-page billing. Press <kbd>⌘T</kbd> in the reader and Nyora opens a side-by-side sheet: the manga page on the left, every recognised text region paired with its translation on the right, one row per line.

This document is the engineering deep-dive into that pipeline — image fetch, the Apple Vision ensemble OCR, the bundled manga-ocr CoreML pass for vertical Japanese, dedupe and filtering, the Google Translate call, and the optional bring-your-own-key LLM polish — followed by the developer workflow, the debug log and the pipeline's current limits. Everything reflects the macOS build as of **May 2026**.

## Table of Contents

- [What you get](#what-you-get)
- [Why you'll love it](#why-youll-love-it)
- [Install](#install)
- [What Works (May 2026)](#what-works-may-2026)
- [The Translation Pipeline](#the-translation-pipeline)
  - [Stage 1 — Image Fetch](#stage-1--image-fetch)
  - [Stage 2 — Apple Vision Ensemble OCR](#stage-2--apple-vision-ensemble-ocr)
  - [Stage 3 — manga-ocr CoreML Tile Pass](#stage-3--manga-ocr-coreml-tile-pass)
  - [Stage 4 — Dedupe & Pre-filter](#stage-4--dedupe--pre-filter)
  - [Stage 5 — Google Translate](#stage-5--google-translate)
  - [Stage 6 — Optional BYOK LLM Polish](#stage-6--optional-byok-llm-polish)
- [Settings](#settings)
- [Developer Workflow](#developer-workflow)
  - [Running During Development](#running-during-development)
  - [Shipping a Release Build](#shipping-a-release-build)
- [Debug Log](#debug-log)
- [Known Limits](#known-limits)
- [FAQ](#faq)
- [Tech Stack](#tech-stack)
- [Architecture](#architecture)
- [Translation Across Platforms](#translation-across-platforms)
- [Nyora on Every Platform](#nyora-on-every-platform)
- [Contributing](#contributing)
  - [Ways to contribute](#ways-to-contribute)
  - [Help wanted — port a source](#help-wanted--port-a-source)
  - [Development setup](#development-setup)
  - [Where things live](#where-things-live)
  - [Good first contributions](#good-first-contributions)
  - [PR and issue etiquette](#pr-and-issue-etiquette)
- [License](#license)
- [Credits](#credits)

## What Works (May 2026)

The end-to-end side-by-side translation sheet is functional and shipping. Press <kbd>⌘T</kbd> in the reader and a panel opens with:

- **Left** — the manga page image.
- **Right** — every text region we could OCR plus its translation, one row per line.

The pipeline is wired end-to-end from image fetch through translation, with an optional LLM polish stage gated behind a user-supplied API key. The recognition half runs on-device (Apple Vision + a bundled CoreML model); only the translation call leaves the machine, and it does so through a free, keyless endpoint.

## The Translation Pipeline

Each page passes through the following stages in order. The numbers below correspond one-to-one with the stages emitted to the [debug log](#debug-log), so you can follow along live. The pipeline is **fail-soft**: if a later stage produces nothing, you still get whatever earlier stages recovered rather than an empty sheet.

### Stage 1 — Image Fetch

The page image is downloaded through the helper proxy. Routing through the proxy keeps the request identical to how the reader already loads pages — headers, referers and source-specific quirks are handled in one place — and hands the decode step a clean, fully-buffered image before OCR begins. Recognition runs on this decoded bitmap, so once the page is in memory the OCR half needs no further network access.

### Stage 2 — Apple Vision Ensemble OCR

Nyora runs Apple Vision text recognition as a four-pass **ensemble**, one pass per language hint:

- `ja-JP` — Japanese
- `zh-Hans` — Simplified Chinese
- `ko-KR` — Korean
- `en-US` — English

Each pass biases Vision's recogniser toward a different script, then the results are pooled. A single-language pass tends to mis-segment or skip text outside its hint; running four catches all horizontal text plus most Latin captions in one sweep. Vision is fast, on-device, and carries the bulk of horizontal and Latin recognition. What it does *not* handle well on its own is vertical Japanese — which is what Stage 3 exists for.

### Stage 3 — manga-ocr CoreML Tile Pass

Vertical Japanese (**tategaki**) is the failure mode for general-purpose OCR, so Nyora bundles a dedicated **manga-ocr** model converted to **CoreML** (~210 MB, shipped inside the app). The model is purpose-built to read the stylised, vertically-set text in speech bubbles, and running it through Core ML keeps recognition on-device with no network round-trip.

To feed it, Nyora tiles the page into a **4×5 grid of overlapping tiles** and OCRs each tile. The overlap matters: a bubble that straddles a tile boundary still lands fully inside at least one neighbouring tile, so it isn't cut in half. As an optimisation, tiles whose luminance signature is too weak to plausibly contain text are skipped — this drops roughly **30%** of the tile work with no meaningful loss in recall, since blank art and flat backgrounds never carried text to begin with.

### Stage 4 — Dedupe & Pre-filter

The Vision result set and the manga-ocr result set are merged. Because the two recognisers overlap (and the tile grid itself overlaps internally), the merged set is **deduped** using a combination of:

- **IoU** (intersection-over-union of bounding boxes) — collapses regions that occupy the same place on the page, and
- **similar-text matching** — collapses near-identical strings that don't perfectly overlap geometrically.

Surviving lines are then **pre-filtered** to strip the kinds of garbage that pollute a translation sheet:

- Runaway repetition — the same token repeating without end.
- Scanlator credits baked into the page.
- Empty or placeholder outputs such as `....`.
- Pure-number garbage with no linguistic content.

The goal is a clean, one-row-per-line set before anything is sent off-device — fewer junk lines mean fewer wasted translation calls and a tidier sheet.

### Stage 5 — Google Translate

Every surviving line is translated into your target language using the **unofficial Google Translate endpoint** — free, no API key required. This is the default translation path and produces a usable, literal translation of each line. Because it is keyless and unofficial, it is best-effort: there is no SLA, and very large pages translate line by line rather than as one batch.

### Stage 6 — Optional BYOK LLM Polish

The translation can optionally be **polished by an LLM** if you supply your own API key (BYOK — bring your own key). Paste a **Mistral** or **OpenAI** key in settings and Nyora feeds the raw Google Translate output to that model, which refines it into manga-quality English — smoothing literal phrasing, fixing pronoun and tense drift, and reading more like natural dialogue. Without a key you simply see the raw Google translation; the pipeline still works end-to-end, just without the polish pass. The key is yours, used only for your own requests, and is never required.

## Settings

All translation behaviour is controlled under **Settings → AI Translation**:

| Setting | What it does |
|---|---|
| **Source language** | Set to `Japanese` for the manga-ocr (Stage 3) path to engage. Without this, the vertical-Japanese model won't be invoked. |
| **Target language** | The language each line is translated into. Defaults to English; Hindi works. |
| **Use bundled manga-ocr model for Japanese** | Keep this **ON**. It enables the CoreML tile pass that reads vertical Japanese. Turning it off limits you to the Apple Vision passes. |
| **LLM Provider (BYOK)** | Optional. Paste a Mistral / OpenAI key to polish the Google Translate output into manga-quality English. Without a key, you see the raw Google translation. |

## Developer Workflow

### Running During Development

`swift run` and direct invocation of the SwiftPM binary **does not open a window** — on recent macOS versions, a raw Mach-O without an `.app` bundle is treated by launchd as a headless background process. Use the dev launcher instead:

```
./scripts/dev-launch.sh
```

This builds the app, wraps the binary in `/tmp/Nyora-dev.app` (a full bundle complete with `Info.plist`, the CoreML models, the helper jar and ad-hoc signing), and `open`s it. The script is **idempotent** — re-run it after any code change to pick up the new build.

### Shipping a Release Build

To produce a distributable build:

```
./scripts/build-dmg.sh
```

This produces a **notarisable** `.dmg` containing `Nyora.app` with the bundled Java runtime and the manga-ocr CoreML model.

## Debug Log

Every step of the translation pipeline writes to `/tmp/nyora_translate.log`. Tail it while pressing <kbd>⌘T</kbd> to see exactly what each stage produced:

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

Each line maps to a pipeline stage: the image decode, the Vision ensemble pass, the per-tile manga-ocr reads (the `(k/20)` counter tracks the 4×5 tile grid), the merged line count, and the final translation. If a page produces an unexpected result, the log tells you precisely which stage is responsible — read top to bottom, and the first stage with a surprising count is your suspect.

## Known Limits

This is an honest engineering doc — here is where the pipeline still falls short:

- **Vision misses some bubbles entirely.** On certain pages, Vision's text detection fails to find speech bubbles at all. The 4×5 grid pass catches most of those, but very small bubbles wedged between panels may still be skipped.
- **manga-ocr can hallucinate.** It occasionally produces short repeating tokens (`くっくっくっ…`). The decoder bails out after 4× repetition of the same token to contain this, but the artefact can still leak through.
- **Latin captions add noise.** All Latin captions are OCR'd via Vision too. This is useful for already-translated chapters, but on pages with no original Latin text it produces some noise on the translation sheet.
- **Translation quality is best-effort.** The default path is the unofficial Google Translate endpoint and is literal; the BYOK LLM polish (Stage 6) is the lever for cleaner phrasing.
- **First page is slower.** The Vision passes and the CoreML model warm up on first use; subsequent pages in a session are faster.

## FAQ

**Is it really free?**
Yes. Text recognition runs on-device, and the default translation path uses a free, keyless endpoint. There is no account, no subscription and no per-page billing. The optional Stage 6 LLM polish uses your own key, on your own requests, and is never required.

**Is it safe — and why does macOS say it can't check it for malware?**
It is safe, and that warning is expected. Nyora is open-source and not signed through Apple's paid notarisation service, so Gatekeeper flags it on first launch — that means macOS doesn't recognise the developer, not that anything is wrong. Because the source is public, you can read exactly what it does. See [Install](#install) for the one-time right-click-Open steps.

**Do I need an account?**
No. You never need an account to read or to translate. (Optional library sync across devices is a separate, opt-in pillar — TRANSLATE doesn't require it.)

**Will my data be private?**
Yes. The page image is never uploaded for translation. Recognition runs entirely on your Mac; only the cleaned text lines are sent to the keyless Google Translate endpoint. There are no ads and no analytics in the pipeline. If you opt into BYOK polish, those lines also go to your chosen LLM provider using your own key.

**Are there ads or trackers?**
No. There are no ads and no analytics in the pipeline. The only outbound request is the translation call in Stage 5 (and, if you opt in, your own BYOK LLM request in Stage 6).

**Where do the manga and sources come from?**
Nyora is a reader, not a content host — the pages it translates come from the online sources you browse. It is not affiliated with any of those sources. TRANSLATE simply recognises and translates whatever page is already on screen.

**Does translation work offline?**
Recognition (Stages 2–4) is fully on-device, so it needs no connection once the page is loaded. The translation call in Stage 5 does require network access. In short: OCR offline, translation online.

**What leaves my machine?**
Only the cleaned text lines, sent to the keyless Google Translate endpoint. The page image is never uploaded for translation. If you enable BYOK polish, the translated lines are also sent to your chosen LLM provider using your own key.

**Do I need an API key?**
No. The pipeline runs end-to-end without one. A key only unlocks the optional Stage 6 LLM polish.

**Which languages can it translate?**
The OCR ensemble targets Japanese, Simplified Chinese, Korean and English scripts, with the bundled model specialised for Japanese (including vertical tategaki). Translation targets are whatever the Google Translate endpoint supports; English is the default and Hindi is confirmed working.

**Why a separate manga-ocr model — isn't Apple Vision enough?**
Vision is excellent at horizontal and Latin text but weak at vertical Japanese. The bundled manga-ocr CoreML model (~210 MB) exists specifically to read tategaki in speech bubbles, which is why it ships alongside Vision rather than replacing it.

**Can I contribute to the shared engine?**
Yes. The shared Kotlin engine, [nyora-shared](https://github.com/Nyora-Manga/nyora-shared), is open-source and public under Apache-2.0. Contributions are welcome — the source/parser runtime, the loopback REST server, the SQLDelight store, Supabase sync, and the downloads manager all live there, and PRs are reviewed like any other open repo. See [Development setup](#development-setup) for how it links into the macOS build.

**How do I update?**
Grab the latest `.dmg` from the [releases page](https://github.com/Nyora-Manga/nyora-mac/releases/latest) and replace the app in Applications, or update via Homebrew with `brew upgrade` if you installed that way.

**It missed a bubble or produced junk — what do I do?**
Tail `/tmp/nyora_translate.log` while pressing <kbd>⌘T</kbd>, find the stage whose line count looks wrong, and open an issue or PR with the page and the log. See [Contributing](#contributing).

## Tech Stack

[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://www.swift.org)
[![Core ML](https://img.shields.io/badge/Core_ML-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/documentation/coreml)
[![Apple](https://img.shields.io/badge/Apple-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/documentation/vision)

- **Swift** — the macOS app and the entire translation orchestration are written in Swift, built with SwiftPM.
- **Apple Vision** — the on-device, four-language ensemble OCR that carries horizontal and Latin text recognition.
- **Core ML** — runs the bundled manga-ocr model on-device for vertical Japanese, with no network round-trip for recognition.

## Architecture

The TRANSLATE pillar on macOS is a staged, fail-soft pipeline. Recognition is split across two complementary engines — Apple Vision for breadth (four language passes, all horizontal/Latin text) and a bundled manga-ocr CoreML model for the one thing Vision can't do well (vertical Japanese, read via an overlapping 4×5 tile grid). Their outputs are merged and cleaned with IoU + similar-text dedupe and a pre-filter that removes repetition, scanlator credits, empty outputs and number garbage.

Only after recognition does anything leave the machine: the cleaned lines are sent to the free, keyless Google Translate endpoint. The optional BYOK LLM polish is the final, user-gated stage — if no key is present, the pipeline returns the raw translation rather than failing. The whole flow is wrapped in an `.app` bundle (so macOS treats it as a real GUI app), carries its own CoreML models and helper jar, and emits a full trace of every stage to `/tmp/nyora_translate.log` for debugging.

## Translation Across Platforms

Every Nyora app translates whole pages, but each uses the OCR engine native to its platform. This pipeline — Apple Vision + bundled manga-ocr CoreML — is the macOS implementation; the table below maps how TRANSLATE is realised elsewhere. Capability claims come straight from each platform's own README; cells marked **—** are simply not stated for that platform.

| Platform | OCR engine | Vertical-JP model | On-device recognition | LLM polish |
|---|---|---|---|---|
| **macOS** *(this doc)* | Apple Vision (4-pass ensemble) | Bundled manga-ocr CoreML (~210 MB) | Yes | Optional BYOK (Mistral / OpenAI) |
| Windows | Built-in Windows OCR | — | Yes | — |
| Linux | Tesseract OCR | — | Yes | — |
| Android | On-device ML (offline fallback) | — | Yes | — |
| iOS / iPadOS | On-device OCR | — | Yes | Apple Intelligence on supported devices |
| Web | — *(uses the native apps)* | — | — | — |

All platforms typeset the translation back over the original art and translate the **whole page** at once, not just a selected bubble.

## Nyora on Every Platform

| Platform | Repo | Get it |
|---|---|---|
| Android | [nyora-android](https://github.com/Nyora-Manga/nyora-android) | [APK](https://github.com/Nyora-Manga/nyora-android/releases/latest) |
| macOS | [nyora-mac](https://github.com/Nyora-Manga/nyora-mac) *(you are here)* | [.dmg / brew](https://github.com/Nyora-Manga/nyora-mac/releases/latest) |
| Windows | [nyora-windows](https://github.com/Nyora-Manga/nyora-windows) | [.exe (x64/ARM64)](https://github.com/Nyora-Manga/nyora-windows/releases/latest) |
| Linux | [nyora-linux](https://github.com/Nyora-Manga/nyora-linux) | [deb · rpm · curl](https://github.com/Nyora-Manga/nyora-linux/releases/latest) |
| iOS / iPadOS | [nyora-ios](https://github.com/Nyora-Manga/nyora-ios) | [sideload IPA](https://github.com/Nyora-Manga/nyora-ios/releases/latest) |
| Web | [nyora-web](https://github.com/Nyora-Manga/nyora-web) | [nyora.xyz](https://nyora.xyz) |

## Contributing

Nyora is built in the open, and contributions are genuinely welcome — whether you write Swift, design, translate, test, or just file a good bug report. You do not need to understand the whole pipeline to help; most useful contributions touch one stage, one setting, or one heuristic. If you have read this far, you already know more about how TRANSLATE works than most people who could improve it. We would love to have you.

This pipeline is a particularly friendly place to start: it is small, observable (every stage prints to a log), and there is no shortage of concrete improvements — sharper bubble detection, better dedupe heuristics, new target languages, and BYOK LLM polish prompts that read more naturally.

### Ways to contribute

You can help no matter your background:

- **Report a bug.** Found a page that translates badly? Open an issue with the source, the page, and a snippet of `/tmp/nyora_translate.log` so we can see which stage misbehaved. Bug reports with a log are the single most useful thing you can send.
- **Improve OCR or translation quality.** Tune bubble detection, the IoU/similar-text dedupe, the pre-filter, or the BYOK polish prompts. These are self-contained and easy to A/B against a real page.
- **Add or test a target language.** English is the default and Hindi is confirmed working; help us confirm and document more.
- **Improve the docs.** Spot something unclear or outdated in this README? A small wording fix is a perfectly good first PR.
- **Test releases.** Download a `.dmg`, run it on your hardware, and report back. Real-world testing across Mac models is invaluable.
- **Star and share.** If TRANSLATE saved you a translation tab, starring [nyora-mac](https://github.com/Nyora-Manga/nyora-mac) and telling a friend genuinely helps the project grow.

### Help wanted — port a source

The single biggest place to make an impact across Nyora is **porting sources** in the iOS engine, [NyoraEngine](https://github.com/Nyora-Manga/nyora-ios). The engine framework is built and the porting pattern is established, but roughly **1,331 parsers** out of **3,659 catalogued classes** still need porting — and so far the framework plus **one** template subclass are done. Most of the remaining work is **mechanical**: each source is a small template subclass that follows the same shape, so the work is highly parallelisable and ideal for a first contribution. If you would like to claim one, open an issue on the [iOS repo](https://github.com/Nyora-Manga/nyora-ios) so we don't double up.

### Development setup

This setup is for working on the macOS **app and translate pipeline** — distinct from simply installing the released app. The macOS app depends on the shared engine, [`nyora-shared`](https://github.com/Nyora-Manga/nyora-shared), which is vendored as a **public** git submodule (Apache-2.0). You can clone, read, edit and iterate on the Swift app and the TRANSLATE pipeline freely — that is where almost all the interesting OCR/translation work lives. Because the engine is open, a full from-scratch build that links the shared engine helper works for everyone: clone with `--recurse-submodules` (or run `git submodule update --init --recursive` afterwards) and you can build everything, engine included.

What you need:

- **macOS 15+** and **Xcode** (the package targets `swift-tools-version: 6.0`, Swift language mode v6).

Clone and build:

```
git clone --recurse-submodules https://github.com/Nyora-Manga/nyora-mac.git
cd nyora-mac/macApp
./scripts/dev-launch.sh
```

`dev-launch.sh` builds the app, wraps the binary in a proper `/tmp/Nyora-dev.app` bundle (with `Info.plist`, the CoreML models, the helper jar and ad-hoc signing) and `open`s a real window — remember that a raw `swift run` will not open one. The script is idempotent: re-run it after every change.

To iterate on the pipeline itself, run `dev-launch.sh`, then in a second terminal tail the [debug log](#debug-log):

```
tail -f /tmp/nyora_translate.log
```

Press <kbd>⌘T</kbd> on a page and watch each stage's counts scroll past — that is your feedback loop for any OCR, dedupe, or translation change.

> Maintainers' note on the submodule: the shared engine is pinned as a git submodule (`https://github.com/Nyora-Manga/nyora-shared.git`). When the shared layer moves forward, bump the pin with `git submodule update --remote nyora-shared` and commit the new reference alongside the change that needs it. The engine itself is open-source and public at [nyora-shared](https://github.com/Nyora-Manga/nyora-shared) (Apache-2.0) — contributions to it are welcome too, whether that is the source/parser runtime, the loopback REST server, the SQLDelight store, Supabase sync, or the downloads manager. PRs against the engine are reviewed there like any other open repo.

#### Configuration

Sync defaults are bundled with the engine so the from-scratch build works out of the box. The bundled defaults include a Google **desktop (installed-app)** OAuth client. By Google's own design, the client secret for a desktop/installed-app client is **not confidential** — installed-app secrets are embedded in distributed applications and are not treated as secret — so shipping it in an open repo is acceptable. If you would rather point sync at your own backend, drop a local `.env.sync` override beside the engine to supply your own Supabase project and credentials; the local override takes precedence over the bundled defaults. No part of this requires the repository to be private.

### Where things live

The translate pipeline lives entirely under `macApp/Nyora/NyoraApp/`:

| Path | What's there |
|---|---|
| `AI/MangaTranslator.swift` | Orchestrates the staged pipeline end to end |
| `AI/OcrProvider.swift` | Apple Vision ensemble + the manga-ocr CoreML tile pass |
| `AI/GoogleTranslate.swift` | The keyless Google Translate call (Stage 5) |
| `AI/AppleIntelligenceRefiner.swift`, `AI/AiRepository.swift` | LLM-polish path and BYOK plumbing (Stage 6) |
| `AI/TranslationModels.swift` | The data types passed between stages |
| `Views/TranslationSheet.swift`, `Views/TranslationDebugBar.swift` | The side-by-side sheet UI and the debug bar |
| `macApp/scripts/` | `dev-launch.sh`, `build-dmg.sh` and this README |

If you are improving recognition, start in `AI/OcrProvider.swift`; if you are improving phrasing, start in the Stage 6 refiner files; if you are touching the sheet UI, start in `Views/TranslationSheet.swift`.

### Good first contributions

Grounded in the actual layout above, here are real places to start:

- **Tune a heuristic.** The dedupe (IoU + similar-text) and the pre-filter (repetition, scanlator credits, number garbage) in the pipeline are small, testable, and have clear failure cases — pick a page that produces junk and improve the filter that should have caught it.
- **Add a target language.** Confirm and document another Google Translate target beyond the default English / Hindi.
- **Improve the BYOK polish prompt.** The Stage 6 refiner turns literal output into natural dialogue — better prompting is a self-contained, high-value change.
- **Fix a small UI detail** in `Views/TranslationSheet.swift` or the debug bar.
- **Improve these docs** — a clearer sentence or a corrected step is a real contribution.
- **Contribute to the shared engine.** [nyora-shared](https://github.com/Nyora-Manga/nyora-shared) is open under Apache-2.0 — the source/parser runtime, the loopback REST server, the SQLDelight store, Supabase sync and the downloads manager all welcome PRs.
- **Port a source** in the iOS engine (see [Help wanted](#help-wanted--port-a-source)) if you would rather work mechanically and in parallel.

### PR and issue etiquette

A few simple things keep reviews fast and friendly:

- **Keep PRs focused.** One change per PR is much easier to review than a grab-bag.
- **Describe the change.** Say what you changed and why; for pipeline fixes, attach the page and the relevant `/tmp/nyora_translate.log` lines that show the before/after.
- **Be kind.** Reviews are a conversation, not a gate. Questions are welcome, and "I'm not sure this is right" is a fine way to open a PR.
- **Start a discussion if unsure.** Not ready for a PR? Open an issue on the [nyora-mac Issues page](https://github.com/Nyora-Manga/nyora-mac/issues) and we'll figure it out together.

Thank you for being here. Whether you ship a parser, sharpen a heuristic, fix a typo, file a thoughtful bug, or simply star the repo and tell a friend — it all moves Nyora forward, and it is all appreciated.

## License

nyora-mac is licensed under **Apache-2.0**. (The Android app is licensed under GPLv3.)

## Credits

Built and maintained by **Md Hasan Raza** — [GitHub](https://github.com/Hasan72341) · [Instagram](https://instagram.com/md_hasan_raza____) · [LinkedIn](https://www.linkedin.com/in/md-hasan-raza) · hasanraza96@outlook.com

Standing on the shoulders of [Apple Vision](https://developer.apple.com/documentation/vision), [manga-ocr](https://github.com/kha-white/manga-ocr), CoreML, and the open-source manga-reader community.

> Nyora is not affiliated with any of the manga sources it can access.