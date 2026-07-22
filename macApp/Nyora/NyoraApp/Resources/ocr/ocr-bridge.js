// ocr-bridge.js — bridges the Swift WebOcrProvider to the verbatim nyora-web OCR worker.
//
// This is the ONLY glue between Swift and the proven web pipeline. It runs `tl-worker.js`
// unchanged (bubble YOLO detector + manga-ocr / PaddleOCR), forwards page images that Swift
// hands in, and relays the worker's block results back to Swift via the WKScriptMessageHandler
// named "ocr". Everything vision-related lives in tl-worker.js; we add no OCR logic here.

const worker = new Worker('./tl-worker.js', { type: 'module' });

let readyResolve, readyReject;
const ready = new Promise((res, rej) => { readyResolve = res; readyReject = rej; });
let settled = false;

function toSwift(msg) {
  try { window.webkit.messageHandlers.ocr.postMessage(msg); } catch (_) { /* no bridge */ }
}

worker.onerror = (e) => {
  const err = new Error((e && e.message) || 'worker error');
  if (!settled) { settled = true; readyReject(err); }
  toSwift({ type: 'init-error', error: String(err.message) });
};

worker.onmessage = (ev) => {
  const m = ev.data || {};
  switch (m.type) {
    case 'ready':
      if (!settled) { settled = true; readyResolve(); }
      toSwift({ type: 'ready' });
      break;
    case 'init-error':
      if (!settled) { settled = true; readyReject(new Error(m.error)); }
      toSwift({ type: 'init-error', error: String(m.error) });
      break;
    case 'progress':
      toSwift({ type: 'progress', label: m.label || '', pct: m.pct || 0 });
      break;
    case 'page-result':
      toSwift({ type: 'page-result', id: String(m.id), blocks: m.blocks || [] });
      break;
    case 'page-error':
      toSwift({ type: 'page-error', id: String(m.id), error: String(m.error) });
      break;
    // page-progress is ignored — Swift only needs the final result.
  }
};

worker.postMessage({ type: 'init' });

// Called by Swift (evaluateJavaScript). `base64` is the raw image file bytes (PNG/JPEG),
// `lang` is the OCR source language (ja | zh | en | ko). The result comes back asynchronously
// as a `page-result` (or `page-error`) message keyed by `id`.
window.__ocrPage = async function (id, base64, lang) {
  try {
    await ready;
    const bin = atob(base64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const bitmap = await createImageBitmap(new Blob([bytes]));
    worker.postMessage({ type: 'page', id: String(id), bitmap, lang: lang || 'ja' }, [bitmap]);
  } catch (e) {
    toSwift({ type: 'page-error', id: String(id), error: String((e && e.message) || e) });
  }
};
