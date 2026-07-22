// core/translate/tl-worker.js — the on-device vision half of the in-image
// translator. Runs OFF the main thread as a module worker and entirely in the
// browser: no Nyora server is involved at any point.
//
//   detection  Kiuyha/Manga-Bubble-YOLO yolo26n.onnx (6 MB, Apache-2.0).
//              End-to-end model: output is (1, 300, 6) [x1,y1,x2,y2,score,cls]
//              in input space — no NMS to decode. Shared by every language.
//
//   OCR        per-source-language engines, downloaded lazily on first use:
//     ja       kha-white/manga-ocr (ViT encoder + char-level Japanese BERT
//              decoder), quantized ONNX from onnx-community/manga-ocr-base-ONNX
//              (Apache-2.0, 87 + 30 MB), greedy-decoded by hand — the repo has
//              no tokenizer.json / merged decoder, so transformers.js can't
//              load it; a manual loop over onnxruntime-web is smaller anyway.
//     zh / en  PP-OCRv5_mobile_rec (PaddlePaddle official ONNX, Apache-2.0,
//              16 MB — one model covers Chinese + English + pinyin).
//     ko       korean_PP-OCRv5_mobile_rec (13 MB).
//              PP-OCR rec reads single text LINES; bubbles are split into
//              lines with a horizontal ink-projection profile first.
//
// Everything (runtime + models) is fetched from CORS-enabled public CDNs on
// first use and cached (Cache API), so later sessions start offline-fast.
// WebGPU is tried first for the heavy encoders; everything falls back to wasm.
//
// Protocol:  {type:'init'} → progress*/ready|init-error
//            {type:'page', id, bitmap, lang} →
//                page-result {id, blocks:[{x,y,w,h,text,bg}]}
//              | page-error {id, error}

const ORT_VERSION = '1.21.0';
const ORT_URL = `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ORT_VERSION}/dist/ort.min.mjs`;
const ORT_WASM_PATH = `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ORT_VERSION}/dist/`;

const DETECTOR_URL = 'https://huggingface.co/Kiuyha/Manga-Bubble-YOLO/resolve/main/onnx/yolo26n.onnx';
const DETECTOR_SIZE = 1280;      // yolo26n was trained at 1280×1280
// Bubbles score high (0.8+), but free text — credit pages, shouts, signs —
// often lands at 0.2–0.5. Keep the bar low and let IoU-dedupe + the
// empty-OCR filter clean up; a wrong box just repaints as an empty read.
const DETECTOR_THRESHOLD = 0.2;

// -- manga-ocr (ja). uint8 (QDQ) variants — the "quantized" (QOperator)
//    exports use ConvInteger, which onnxruntime-web's wasm EP has no kernel for.
const MANGA_OCR_BASE = 'https://huggingface.co/onnx-community/manga-ocr-base-ONNX/resolve/main/onnx/';
const MANGA_OCR_ENCODER_URL = MANGA_OCR_BASE + 'encoder_model_uint8.onnx';
const MANGA_OCR_DECODER_URL = MANGA_OCR_BASE + 'decoder_model_uint8.onnx';
const MANGA_OCR_VOCAB_URL = 'https://huggingface.co/kha-white/manga-ocr-base/resolve/main/vocab.txt';
const MANGA_OCR_SIZE = 224;      // ViTImageProcessor: 224×224, (x/255 − .5)/.5
const MANGA_OCR_START = 2n;      // [CLS] (decoder_start_token_id)
const MANGA_OCR_EOS = 3n;        // [SEP] (eos_token_id)
const MANGA_OCR_MAX_TOKENS = 64; // bubbles are short; generation cap

// -- PP-OCR line pipeline (zh/en/ko): a DB text-line DETECTOR runs on each
//    bubble crop (proper line boxes — far better than any projection split),
//    then a CTC recognizer reads each line. Rec input x=[1,3,48,W] BGR
//    (x/255−.5)/.5, output [1,W/8,C] softmaxed; table = ['blank']+dict+[' '].
//    zh/en use PP-OCRv6 small rec (Printed-EN 93.3 / CN 90.5 — the model
//    comic-translate ships); ko keeps korean_PP-OCRv5 (v6's dict has no Hangul).
const PADDLE_DET_URL = 'https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx/resolve/main/inference.onnx';
const PADDLE = {
  zh: {
    model: 'https://huggingface.co/ogkalu/ppocr-v6-onnx/resolve/main/PP-OCRv6_small_rec.onnx',
    dict: 'https://huggingface.co/ogkalu/ppocr-v6-onnx/resolve/main/PP-OCRv6_small_rec.txt',
    label: 'Chinese/English OCR model', size: 21_200_000, joiner: '',
  },
  ko: {
    model: 'https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.onnx',
    dict: 'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/ppocr/utils/dict/ppocrv5_korean_dict.txt',
    label: 'Korean OCR model', size: 13_400_000, joiner: ' ',
  },
};
PADDLE.en = { ...PADDLE.zh, joiner: ' ' };  // the v6 model covers English
const PADDLE_H = 48;
const PADDLE_MAX_W = 1536;
const DET_MAX_SIDE = 960;
// DB postprocess, comic-tuned (comic-translate's values): binarize 0.3, keep
// components with mean prob > 0.5, expand by unclip ratio 2.0.
const DET_BIN = 0.3;
const DET_BOX_SCORE = 0.5;
const DET_UNCLIP = 2.0;

const MODEL_CACHE = 'nyora-tl-models';

let ort = null;
let detector = null;
let lineDetP = null; // PP-OCR DB text-line detector, shared by zh/en/ko
const engines = new Map(); // 'ja' | 'zh' | 'ko' → Promise<engine>
let initPromise = null;
let queue = Promise.resolve(); // pages are processed strictly one at a time

const post = (m) => self.postMessage(m);

self.onmessage = (ev) => {
  const m = ev.data || {};
  if (m.type === 'init') {
    ensureInit()
      .then(() => post({ type: 'ready' }))
      .catch((e) => post({ type: 'init-error', error: String((e && e.message) || e) }));
  } else if (m.type === 'page') {
    queue = queue
      .then(() => ensureInit())
      .then(() => handlePage(m.id, m.bitmap, m.lang || 'ja'))
      .catch((e) => post({ type: 'page-error', id: m.id, error: String((e && e.message) || e) }));
  }
};

function ensureInit() {
  if (!initPromise) initPromise = init().catch((e) => { initPromise = null; throw e; });
  return initPromise;
}

async function createSession(buf, preferGpu) {
  if (preferGpu && typeof navigator !== 'undefined' && navigator.gpu) {
    try {
      return await ort.InferenceSession.create(buf, { executionProviders: ['webgpu', 'wasm'] });
    } catch { /* WebGPU unavailable/unsupported ops — wasm below */ }
  }
  return ort.InferenceSession.create(buf, { executionProviders: ['wasm'] });
}

async function init() {
  post({ type: 'progress', label: 'Loading AI runtime', pct: 0 });
  ort = await import(ORT_URL);
  ort.env.wasm.wasmPaths = ORT_WASM_PATH;
  // The service worker injects COOP/COEP, so the page is usually cross-origin
  // isolated → SharedArrayBuffer threads are available. Use most of the cores.
  if (self.crossOriginIsolated) {
    ort.env.wasm.numThreads = Math.min(8, Math.max(1, (navigator.hardwareConcurrency || 4) - 1));
  }
  detector = await createSession(await fetchWithProgress(DETECTOR_URL, 'bubble detector', 6_100_000), false);
}

// ---- per-language OCR engines (lazy) ---------------------------------------

function ensureEngine(lang) {
  const key = lang === 'en' ? 'zh' : lang; // en shares the zh model
  let p = engines.get(key);
  if (!p) {
    p = (key === 'ja' ? loadMangaOcr() : loadPaddle(key)).catch((e) => { engines.delete(key); throw e; });
    engines.set(key, p);
  }
  return p;
}

async function loadMangaOcr() {
  const encoder = await createSession(await fetchWithProgress(MANGA_OCR_ENCODER_URL, 'Japanese OCR model (1/2)', 87_000_000), true);
  const decoder = await createSession(await fetchWithProgress(MANGA_OCR_DECODER_URL, 'Japanese OCR model (2/2)', 30_000_000), false);
  const vres = await fetch(MANGA_OCR_VOCAB_URL);
  if (!vres.ok) throw new Error('vocab download failed');
  const vocab = (await vres.text()).split('\n').map((s) => s.replace(/\r$/, ''));
  return { kind: 'manga', encoder, decoder, vocab };
}

async function loadPaddle(key) {
  const cfg = PADDLE[key];
  if (!lineDetP) {
    lineDetP = fetchWithProgress(PADDLE_DET_URL, 'text-line detector', 4_900_000)
      .then((buf) => createSession(buf, false))
      .catch((e) => { lineDetP = null; throw e; });
  }
  const [lineDet, rec] = await Promise.all([
    lineDetP,
    fetchWithProgress(cfg.model, cfg.label, cfg.size).then((buf) => createSession(buf, true)),
  ]);
  const dres = await fetch(cfg.dict);
  if (!dres.ok) throw new Error('OCR dict download failed');
  const dict = (await dres.text()).split('\n').map((s) => s.replace(/\r$/, ''));
  if (dict.length && dict[dict.length - 1] === '') dict.pop();
  const table = ['', ...dict, ' ']; // CTC: blank + dict + space (use_space_char)
  return { kind: 'paddle', rec, lineDet, table };
}

async function fetchWithProgress(url, label, sizeHint) {
  const cache = await caches.open(MODEL_CACHE).catch(() => null);
  if (cache) {
    const hit = await cache.match(url).catch(() => null);
    if (hit) return hit.arrayBuffer();
  }
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${label} download failed (${res.status})`);
  const total = Number(res.headers.get('content-length')) || sizeHint || 0;
  const reader = res.body.getReader();
  const chunks = [];
  let got = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    got += value.length;
    if (total) post({ type: 'progress', label: `Downloading ${label}`, pct: Math.min(100, Math.round((got / total) * 100)) });
  }
  const blob = new Blob(chunks);
  if (cache) await cache.put(url, new Response(blob)).catch(() => { /* best-effort */ });
  return blob.arrayBuffer();
}

// ---- detection -----------------------------------------------------------

// Webtoon strips are extremely tall; squeezing 12000px into one 1280² square
// makes every bubble a few pixels. Detect on ~1.6:1 vertical tiles with 20%
// overlap instead, then dedupe boxes across the seams.
function tileRects(w, h) {
  const tileH = Math.min(h, Math.round(w * 1.6));
  if (tileH >= h) return [{ x: 0, y: 0, w, h }];
  const step = Math.max(1, Math.round(tileH * 0.8));
  const rects = [];
  for (let y = 0; ; y += step) {
    rects.push({ x: 0, y: Math.min(y, h - tileH), w, h: tileH });
    if (y + tileH >= h) break;
  }
  return rects;
}

async function detectTile(src, rect) {
  const size = DETECTOR_SIZE;
  const scale = Math.min(size / rect.w, size / rect.h);
  const dw = Math.max(1, Math.round(rect.w * scale));
  const dh = Math.max(1, Math.round(rect.h * scale));
  const cv = new OffscreenCanvas(size, size);
  const cx = cv.getContext('2d', { willReadFrequently: true });
  cx.fillStyle = 'rgb(114,114,114)';
  cx.fillRect(0, 0, size, size);
  cx.drawImage(src, rect.x, rect.y, rect.w, rect.h, 0, 0, dw, dh); // top-left letterbox
  const data = cx.getImageData(0, 0, size, size).data;
  const plane = size * size;
  const input = new Float32Array(3 * plane);
  for (let i = 0, p = 0; i < plane; i++, p += 4) {
    input[i] = data[p] / 255;
    input[i + plane] = data[p + 1] / 255;
    input[i + 2 * plane] = data[p + 2] / 255;
  }
  const feeds = { [detector.inputNames[0]]: new ort.Tensor('float32', input, [1, 3, size, size]) };
  const out = await detector.run(feeds);
  const t = out[detector.outputNames[0]];
  const boxes = [];
  if (t && t.dims.length === 3 && t.dims[2] >= 6) {
    const stride = t.dims[2];
    const d = t.data;
    for (let i = 0; i < t.dims[1]; i++) {
      const o = i * stride;
      const score = d[o + 4];
      if (score < DETECTOR_THRESHOLD) continue;
      const x1 = d[o] / scale + rect.x;
      const y1 = d[o + 1] / scale + rect.y;
      const x2 = d[o + 2] / scale + rect.x;
      const y2 = d[o + 3] / scale + rect.y;
      const b = {
        x: Math.max(0, Math.round(x1)),
        y: Math.max(0, Math.round(y1)),
        w: Math.round(x2 - x1),
        h: Math.round(y2 - y1),
        score,
      };
      if (b.w > 6 && b.h > 6) boxes.push(b);
    }
  }
  return boxes;
}

function overlapArea(a, b) {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

function dedupe(boxes) {
  // 1. Cross-tile duplicates: IoU-suppress, best score wins.
  boxes.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const b of boxes) {
    const dup = kept.some((k) => {
      const ov = overlapArea(k, b);
      return ov / (k.w * k.h + b.w * b.h - ov) > 0.45;
    });
    if (!dup) kept.push(b);
  }
  // 2. Nested pairs (the model marks both the bubble and the text inside it):
  //    keep the container — the OCR models read whole-bubble/multi-line crops
  //    and the overlay should cover the whole bubble.
  kept.sort((a, b) => b.w * b.h - a.w * a.h);
  const out = [];
  for (const b of kept) {
    const inside = out.some((k) => overlapArea(k, b) / (b.w * b.h) > 0.75);
    if (!inside) out.push(b);
  }
  // Reading order: top-to-bottom, then right-to-left (manga).
  out.sort((a, b) => (a.y + a.h / 2) - (b.y + b.h / 2) || (b.x + b.w / 2) - (a.x + a.w / 2));
  return out;
}

// ---- OCR: manga-ocr (ja) — manual greedy VisionEncoderDecoder loop ---------

// manga-ocr's own post_process (kha-white/manga-ocr), which we were missing:
// strip whitespace → '…' to '...' → collapse ・/. runs to that many dots →
// jaconv.h2z(ascii, digit): HALF-WIDTH to FULL-WIDTH. The model reads "LINK!",
// "30", "!!", "?" but proper Japanese text is "ＬＩＮＫ！", "３０", "！！", "？".
// Measured on manga-ocr's own 12-image test set: exact matches 5/12 → 8/12 and
// mean CER 12.37% → 6.39%. JA path only — never apply to the latin zh/en/ko
// output, where full-width letters would be wrong.
function mangaOcrPostprocess(t) {
  t = t.replace(/\s+/g, '');
  t = t.replace(/…/g, '...');
  t = t.replace(/[・.]{2,}/g, (m) => '.'.repeat(m.length));
  return t.replace(/[!-~]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 0xFEE0));
}

function mangaOcrPreprocess(crop) {
  const cv = new OffscreenCanvas(MANGA_OCR_SIZE, MANGA_OCR_SIZE);
  const cx = cv.getContext('2d', { willReadFrequently: true });
  cx.fillStyle = '#fff';
  cx.fillRect(0, 0, MANGA_OCR_SIZE, MANGA_OCR_SIZE);
  cx.drawImage(crop, 0, 0, MANGA_OCR_SIZE, MANGA_OCR_SIZE); // ViTImageProcessor squashes aspect
  const data = cx.getImageData(0, 0, MANGA_OCR_SIZE, MANGA_OCR_SIZE).data;
  const plane = MANGA_OCR_SIZE * MANGA_OCR_SIZE;
  const input = new Float32Array(3 * plane);
  for (let i = 0, p = 0; i < plane; i++, p += 4) {
    input[i] = data[p] / 127.5 - 1;              // (x/255 − 0.5) / 0.5
    input[i + plane] = data[p + 1] / 127.5 - 1;
    input[i + 2 * plane] = data[p + 2] / 127.5 - 1;
  }
  return new ort.Tensor('float32', input, [1, 3, MANGA_OCR_SIZE, MANGA_OCR_SIZE]);
}

// Greedy decode ALL crops of a page together: the autoregressive loop is the
// dominant cost (no KV cache in this export, one decoder.run per token), so
// batching N bubbles turns ~N × seq_len sequential runs into ~max_seq_len
// batched ones. Finished rows are padded with [PAD] and masked out.
const MANGA_OCR_BATCH = 8; // bounds logits memory: 8 × len × 6144 floats/step

async function mangaOcrBatch(eng, crops, onOneDone) {
  const texts = new Array(crops.length).fill('');
  for (let base = 0; base < crops.length; base += MANGA_OCR_BATCH) {
    const chunk = crops.slice(base, base + MANGA_OCR_BATCH);
    const n = chunk.length;
    // Per-chunk resilience (mirrors the paddle per-crop try/catch): a decoder
    // throw mid-batch must not sink the whole page. On failure the chunk's
    // entries stay '' (pre-filled) and the partially-decoded array is still
    // returned; balance the progress ticks so the bar still reaches total.
    let fired = 0;
    const fire = () => { fired++; if (onOneDone) onOneDone(); };
    try {
      // Encode each crop (sequential — bounded memory), stack hidden states [n,T,C].
      let T = 0;
      let C = 0;
      const encoded = [];
      for (const crop of chunk) {
        const enc = await eng.encoder.run({ [eng.encoder.inputNames[0]]: mangaOcrPreprocess(crop) });
        const h = enc[eng.encoder.outputNames[0]];
        T = h.dims[1];
        C = h.dims[2];
        encoded.push(h.data);
      }
      const hid = new Float32Array(n * T * C);
      encoded.forEach((d, i) => hid.set(d, i * T * C));
      const hidden = new ort.Tensor('float32', hid, [n, T, C]);

      const seqs = Array.from({ length: n }, () => [MANGA_OCR_START]);
      const finished = new Array(n).fill(false);
      for (let step = 0; step < MANGA_OCR_MAX_TOKENS && finished.includes(false); step++) {
        const len = seqs[0].length;
        const ids = new BigInt64Array(n * len);
        for (let i = 0; i < n; i++) {
          for (let j = 0; j < len; j++) ids[i * len + j] = seqs[i][j];
        }
        const out = await eng.decoder.run({
          input_ids: new ort.Tensor('int64', ids, [n, len]),
          encoder_hidden_states: hidden,
        });
        const logits = out[eng.decoder.outputNames[0]]; // [n, len, vocab]
        const V = logits.dims[2];
        const d = logits.data;
        for (let i = 0; i < n; i++) {
          if (finished[i]) { seqs[i].push(0n); continue; } // [PAD] filler
          const off = (i * len + (len - 1)) * V;
          let best = 0;
          let bestV = -Infinity;
          for (let v = 0; v < V; v++) {
            if (d[off + v] > bestV) { bestV = d[off + v]; best = v; }
          }
          const tok = BigInt(best);
          if (tok === MANGA_OCR_EOS) {
            finished[i] = true;
            seqs[i].push(0n);
            fire();
          } else {
            seqs[i].push(tok);
          }
        }
      }
      for (let i = 0; i < n; i++) {
        if (!finished[i]) fire(); // hit the length cap
        // Character-level BERT vocab: drop [PAD]/[CLS]/…/<unusedN> specials, strip
        // wordpiece '##' continuations, join with no spaces (Japanese).
        let text = '';
        for (const idb of seqs[i].slice(1)) {
          const id = Number(idb);
          if (!id) continue;
          const t = eng.vocab[id] || '';
          if (!t || t.startsWith('[') || t.startsWith('<unused')) continue;
          text += t.startsWith('##') ? t.slice(2) : t;
        }
        texts[base + i] = mangaOcrPostprocess(text);
      }
    } catch { /* one bad chunk must not sink the page — keep the rest */
      while (fired < n) fire();
    }
  }
  return texts;
}

// ---- OCR: PP-OCRv5 rec (zh/en/ko) — line split + CTC decode -----------------

// Otsu-binarize RGBA pixel data into an "is text ink" mask (text = the
// minority class of the binarization). Shared by the line splitter and the
// wide-box refiner.
function inkMask(d, total) {
  const lum = new Uint8Array(total);
  const hist = new Uint32Array(256);
  for (let i = 0, p = 0; i < total; i++, p += 4) {
    const l = (d[p] * 77 + d[p + 1] * 150 + d[p + 2] * 29) >> 8;
    lum[i] = l;
    hist[l]++;
  }
  let sum = 0;
  for (let i = 0; i < 256; i++) sum += i * hist[i];
  let sumB = 0; let wB = 0; let maxVar = -1; let thr = 128;
  for (let i = 0; i < 256; i++) {
    wB += hist[i];
    if (!wB || wB === total) continue;
    sumB += i * hist[i];
    const mB = sumB / wB;
    const mF = (sum - sumB) / (total - wB);
    const v = wB * (total - wB) * (mB - mF) * (mB - mF);
    if (v > maxVar) { maxVar = v; thr = i; }
  }
  let dark = 0;
  for (let i = 0; i < total; i++) if (lum[i] < thr) dark++;
  const textIsDark = dark <= total - dark;
  const ink = new Uint8Array(total);
  for (let i = 0; i < total; i++) ink[i] = (lum[i] < thr) === textIsDark ? 1 : 0;
  return ink;
}

// The detector hugs — and sometimes clips — wide free-text lines ("PLEASE
// READ AT: …" credit pages, shouts). For clearly line-shaped boxes, walk the
// column ink profile outward from the box edges and extend over any text the
// box cut off. Bubbles (roughly square) are left untouched — walking there
// could bleed into adjacent art.
function refineWideBox(sctx, b, W) {
  if (b.w < b.h * 2.2) return b;
  const maxExt = Math.round(b.w * 0.4);
  const x0 = Math.max(0, b.x - maxExt);
  const x1 = Math.min(W, b.x + b.w + maxExt);
  const w = x1 - x0;
  const ink = inkMask(sctx.getImageData(x0, b.y, w, b.h).data, w * b.h);
  const cols = new Uint32Array(w);
  for (let y = 0; y < b.h; y++) {
    for (let x = 0; x < w; x++) cols[x] += ink[y * w + x];
  }
  const minInk = Math.max(1, Math.round(b.h * 0.06));
  const gapMax = Math.max(6, Math.min(90, Math.round(b.h * 0.8))); // word gap, not panel gap
  let left = b.x - x0;
  let gap = 0;
  for (let x = left - 1; x >= 0; x--) {
    if (cols[x] > minInk) { left = x; gap = 0; } else if (++gap > gapMax) break;
  }
  let right = b.x + b.w - x0;
  gap = 0;
  for (let x = right + 1; x < w; x++) {
    if (cols[x] > minInk) { right = x; gap = 0; } else if (++gap > gapMax) break;
  }
  return { ...b, x: x0 + left, w: right - left + 1 };
}

// PP-OCR rec reads single horizontal lines. Find them with the DB text-line
// detector: prob map → binarize → connected components → scored, unclipped
// line boxes (in crop coordinates, reading order).
async function detTextLines(eng, crop) {
  const W0 = crop.width;
  const H0 = crop.height;
  const scale = Math.min(1, DET_MAX_SIDE / Math.max(W0, H0));
  const W = Math.max(32, Math.round((W0 * scale) / 32) * 32);
  const H = Math.max(32, Math.round((H0 * scale) / 32) * 32);
  const cv = new OffscreenCanvas(W, H);
  const cx = cv.getContext('2d', { willReadFrequently: true });
  cx.drawImage(crop, 0, 0, W, H);
  const d = cx.getImageData(0, 0, W, H).data;
  const plane = W * H;
  const input = new Float32Array(3 * plane);
  for (let i = 0, p = 0; i < plane; i++, p += 4) {
    input[i] = (d[p + 2] / 255 - 0.485) / 0.229;      // BGR, ImageNet mean/std
    input[i + plane] = (d[p + 1] / 255 - 0.456) / 0.224;
    input[i + 2 * plane] = (d[p] / 255 - 0.406) / 0.225;
  }
  const out = await eng.lineDet.run({ [eng.lineDet.inputNames[0]]: new ort.Tensor('float32', input, [1, 3, H, W]) });
  const prob = out[eng.lineDet.outputNames[0]].data; // [1,1,H,W]
  const bin = new Uint8Array(plane);
  for (let i = 0; i < plane; i++) bin[i] = prob[i] > DET_BIN ? 1 : 0;
  const seen = new Uint8Array(plane);
  const qx = new Int32Array(plane);
  const qy = new Int32Array(plane);
  const boxes = [];
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const idx = y * W + x;
      if (!bin[idx] || seen[idx]) continue;
      let head = 0;
      let tail = 0;
      qx[tail] = x; qy[tail] = y; tail++;
      seen[idx] = 1;
      let minX = x; let maxX = x; let minY = y; let maxY = y; let sum = 0; let n = 0;
      while (head < tail) {
        const cxx = qx[head];
        const cyy = qy[head];
        head++;
        sum += prob[cyy * W + cxx];
        n++;
        if (cxx < minX) minX = cxx;
        if (cxx > maxX) maxX = cxx;
        if (cyy < minY) minY = cyy;
        if (cyy > maxY) maxY = cyy;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = cxx + dx;
          const ny = cyy + dy;
          if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
          const ni = ny * W + nx;
          if (bin[ni] && !seen[ni]) { seen[ni] = 1; qx[tail] = nx; qy[tail] = ny; tail++; }
        }
      }
      const bw = maxX - minX + 1;
      const bh = maxY - minY + 1;
      if (bw < 3 || bh < 3 || n < 10) continue;
      if (sum / n < DET_BOX_SCORE) continue;
      // DB unclip: offset = area × ratio / perimeter
      const off = Math.round((bw * bh * DET_UNCLIP) / (2 * (bw + bh)));
      boxes.push({
        x: Math.max(0, minX - off),
        y: Math.max(0, minY - off),
        x2: Math.min(W, maxX + off),
        y2: Math.min(H, maxY + off),
      });
    }
  }
  const sx = W0 / W;
  const sy = H0 / H;
  const lines = boxes.map((b) => ({
    x: Math.round(b.x * sx),
    y: Math.round(b.y * sy),
    w: Math.max(1, Math.round((b.x2 - b.x) * sx)),
    h: Math.max(1, Math.round((b.y2 - b.y) * sy)),
  }));
  // The detector often splits one visual line into several word boxes whose
  // centers differ slightly in y — a naive (y, x) sort scrambles the words.
  // Cluster boxes into rows by vertical overlap, then read rows top-to-bottom
  // and each row left-to-right.
  lines.sort((a, b) => (a.y + a.h / 2) - (b.y + b.h / 2));
  const rows = [];
  for (const l of lines) {
    const cy = l.y + l.h / 2;
    const row = rows.find((r) => Math.abs(r.cy - cy) < Math.max(r.h, l.h) * 0.55);
    if (row) {
      row.items.push(l);
      row.cy = (row.cy * (row.items.length - 1) + cy) / row.items.length;
      row.h = Math.max(row.h, l.h);
    } else {
      rows.push({ cy, h: l.h, items: [l] });
    }
  }
  rows.sort((a, b) => a.cy - b.cy);
  return rows.flatMap((r) => r.items.sort((a, b) => a.x - b.x));
}

async function paddleRecLine(eng, crop, rect) {
  const w = Math.max(16, Math.min(PADDLE_MAX_W, Math.round(rect.w * (PADDLE_H / rect.h))));
  const cv = new OffscreenCanvas(w, PADDLE_H);
  const cx = cv.getContext('2d', { willReadFrequently: true });
  cx.drawImage(crop, rect.x, rect.y, rect.w, rect.h, 0, 0, w, PADDLE_H);
  const data = cx.getImageData(0, 0, w, PADDLE_H).data;
  const plane = PADDLE_H * w;
  const input = new Float32Array(3 * plane);
  for (let i = 0, p = 0; i < plane; i++, p += 4) {
    input[i] = data[p + 2] / 127.5 - 1;          // BGR order, (x/255 − .5)/.5
    input[i + plane] = data[p + 1] / 127.5 - 1;
    input[i + 2 * plane] = data[p] / 127.5 - 1;
  }
  const out = await eng.rec.run({ [eng.rec.inputNames[0]]: new ort.Tensor('float32', input, [1, 3, PADDLE_H, w]) });
  const t = out[eng.rec.outputNames[0]]; // [1, T, C] (softmaxed)
  const T = t.dims[1];
  const C = t.dims[2];
  const d = t.data;
  let text = '';
  let prev = 0;
  for (let s = 0; s < T; s++) {
    const off = s * C;
    let best = 0;
    let bestV = -Infinity;
    for (let i = 0; i < C; i++) {
      if (d[off + i] > bestV) { bestV = d[off + i]; best = i; }
    }
    if (best !== 0 && best !== prev) text += eng.table[best] || '';
    prev = best;
  }
  return text.trim();
}

async function paddleOcrCrop(eng, crop, joiner) {
  let lines = await detTextLines(eng, crop);
  // Detector found nothing (tiny/odd crop) — try the whole crop as one line.
  if (!lines.length) lines = [{ x: 0, y: 0, w: crop.width, h: crop.height }];
  const parts = [];
  for (const rect of lines) {
    const line = await paddleRecLine(eng, crop, rect);
    if (line) parts.push(line);
  }
  return parts.join(joiner).trim();
}

// ---- per-page pipeline -----------------------------------------------------

// Android's sampleBackgroundColor: probe the 4 inner corners of the box and
// keep the brightest pixel — that's the bubble fill the overlay repaints with.
function sampleBg(ctx, x, y, w, h) {
  const ins = Math.max(2, Math.round(Math.min(w, h) * 0.12));
  const pts = [[x + ins, y + ins], [x + w - ins, y + ins], [x + ins, y + h - ins], [x + w - ins, y + h - ins]];
  let best = [255, 255, 255];
  let bestLum = -1;
  for (const [px, py] of pts) {
    try {
      const d = ctx.getImageData(px, py, 1, 1).data;
      const lum = 0.299 * d[0] + 0.587 * d[1] + 0.114 * d[2];
      if (lum > bestLum) { bestLum = lum; best = [d[0], d[1], d[2]]; }
    } catch { /* out of bounds — skip */ }
  }
  return `rgb(${best.join(',')})`;
}

async function handlePage(id, bitmap, lang) {
  const eng = await ensureEngine(lang);
  const W = bitmap.width;
  const H = bitmap.height;
  const src = new OffscreenCanvas(W, H);
  const sctx = src.getContext('2d', { willReadFrequently: true });
  sctx.drawImage(bitmap, 0, 0);
  bitmap.close();

  let boxes = [];
  for (const rect of tileRects(W, H)) boxes = boxes.concat(await detectTile(src, rect));
  boxes = dedupe(boxes);

  // Resolve final crop rects up front so the page's pending boxes (and the
  // progress total) can be reported before the slow OCR loop starts.
  const rects = [];
  for (let b of boxes) {
    try { b = refineWideBox(sctx, b, W); } catch { /* keep the raw box */ }
    // Generous padding — detector boxes hug the glyphs, and an overlay that
    // stops mid-letter leaves the original text peeking out at the edges.
    // Wide free-text lines get extra horizontal slack.
    const pad = Math.round(Math.min(28, Math.max(6, Math.min(b.w, b.h) * 0.12)));
    const padX = pad + Math.round(b.w * 0.03);
    const x = Math.max(0, b.x - padX);
    const y = Math.max(0, b.y - pad);
    const w = Math.min(W - x, b.w + padX * 2);
    const h = Math.min(H - y, b.h + pad * 2);
    if (w < 14 || h < 14) continue;
    rects.push({ x, y, w, h, bg: sampleBg(sctx, x, y, w, h) });
  }
  post({ type: 'page-progress', id, done: 0, total: rects.length, boxes: rects });

  const cropOf = (r) => {
    const crop = new OffscreenCanvas(r.w, r.h);
    crop.getContext('2d', { willReadFrequently: true }).drawImage(src, r.x, r.y, r.w, r.h, 0, 0, r.w, r.h);
    return crop;
  };
  const junk = /^[\s.。‥…・･·。、,*×+~〜ー—\-!?！？'"“”]*$/; // SFX dots, dashes, ellipses
  const blocks = [];
  let done = 0;
  const tick = () => { done++; post({ type: 'page-progress', id, done, total: rects.length, boxes: rects }); };

  if (eng.kind === 'manga') {
    let texts = [];
    try {
      texts = await mangaOcrBatch(eng, rects.map(cropOf), tick);
    } catch { /* fall through with whatever decoded */ }
    rects.forEach((r, i) => {
      const text = texts[i];
      if (text && !junk.test(text)) blocks.push({ ...r, text });
    });
  } else {
    const joiner = (PADDLE[lang] && PADDLE[lang].joiner) || ' ';
    for (const r of rects) {
      let text = '';
      try {
        text = await paddleOcrCrop(eng, cropOf(r), joiner);
      } catch { /* one bad crop must not sink the page */ }
      tick();
      if (text && !junk.test(text)) blocks.push({ ...r, text });
    }
  }
  post({ type: 'page-result', id, blocks });
}
