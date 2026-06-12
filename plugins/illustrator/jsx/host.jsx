// Design Hub — Illustrator ExtendScript host (CEP)
// Reads layer/artboard data from the active document and returns JSON strings.
// ExtendScript is ES3-ish and has no JSON object, so JSON is built by hand.

function dhEscape(s) {
    if (s === null || s === undefined) return "";
    s = String(s);
    var out = "";
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        var code = s.charCodeAt(i);
        if (c === '"') out += '\\"';
        else if (c === '\\') out += '\\\\';
        else if (c === '\n') out += '\\n';
        else if (c === '\r') out += '\\r';
        else if (c === '\t') out += '\\t';
        else if (code < 32) out += '\\u' + ('0000' + code.toString(16)).slice(-4);
        else out += c;
    }
    return out;
}

// Illustrator layers can contain sub-layers via `layer.layers`. No "kind".
function dhLayerJSON(layer) {
    var locked = false;
    try { locked = layer.locked; } catch (e) {}
    var visible = true;
    try { visible = layer.visible; } catch (e2) {}

    var kids = [];
    try {
        for (var i = 0; i < layer.layers.length; i++) {
            kids.push(dhLayerJSON(layer.layers[i]));
        }
    } catch (e3) {}

    // Illustrator exposes no stable layer IDs — send null so the app's differ
    // falls back to name-based identity (id:0 would make every layer identical).
    return '{"id":null'
        + ',"name":"' + dhEscape(layer.name) + '"'
        + ',"visible":' + (visible ? 'true' : 'false')
        + ',"locked":' + (locked ? 'true' : 'false')
        + ',"children":[' + kids.join(',') + ']}';
}

function dhCountLayers(layers) {
    var n = 0;
    for (var i = 0; i < layers.length; i++) {
        n++;
        try { if (layers[i].layers.length > 0) n += dhCountLayers(layers[i].layers); } catch (e) {}
    }
    return n;
}

// Full snapshot payload (matches the macOS app's DocumentPayload).
function dhSnapshot() {
    if (app.documents.length === 0) return "";
    var doc = app.activeDocument;

    var path = "";
    try { path = doc.fullName.fsName; } catch (e) { path = ""; }

    var layerJSONs = [];
    for (var i = 0; i < doc.layers.length; i++) {
        layerJSONs.push(dhLayerJSON(doc.layers[i]));
    }

    var abNames = [];
    try {
        for (var a = 0; a < doc.artboards.length; a++) {
            abNames.push('"' + dhEscape(doc.artboards[a].name) + '"');
        }
    } catch (e2) {}

    // Shape (pageItem) count drives the heatmap/diff for Illustrator: AI work
    // adds/removes shapes far more often than whole layers. `doc.pageItems`
    // is a flat collection of every page item across all layers *and* inside
    // groups, so its length is the document's total shape count.
    //
    // Each item's uuid (Illustrator 24+) is also collected so the app can tell
    // "3 added, 2 removed" apart from a net count change of +1. If uuids are
    // unavailable the list comes back short and the app falls back to the net
    // count delta.
    var shapeCount = 0;
    var shapeIds = [];
    try {
        var items = doc.pageItems;
        shapeCount = items.length;
        for (var s = 0; s < shapeCount; s++) {
            try { shapeIds.push('"' + dhEscape(String(items[s].uuid)) + '"'); } catch (eId) {}
        }
    } catch (eShapes) {}

    return '{'
        + '"path":"' + dhEscape(path) + '"'
        + ',"name":"' + dhEscape(doc.name) + '"'
        + ',"layerCount":' + dhCountLayers(doc.layers)
        + ',"topLevelLayerCount":' + doc.layers.length
        + ',"shapeCount":' + shapeCount
        + ',"shapeIds":[' + shapeIds.join(',') + ']'
        + ',"layerTree":[' + layerJSONs.join(',') + ']'
        + ',"artboardCount":' + abNames.length
        + ',"artboardNames":[' + abNames.join(',') + ']'
        + '}';
}

// Auto-save path: flush in-memory edits to disk first (so the macOS app sees
// real byte changes), then return the snapshot. Untitled docs (no file on disk)
// are snapshotted without saving — there is nowhere to save them silently.
function dhSaveAndSnapshot() {
    if (app.documents.length === 0) return "";
    var doc = app.activeDocument;

    var path = "";
    try { path = doc.fullName.fsName; } catch (e) { path = ""; }

    if (path !== "") {
        var dirty = false;
        try { dirty = (doc.saved === false); } catch (e2) {}
        if (dirty) {
            try { doc.save(); } catch (e3) {}
        }
    }

    return dhSnapshot();
}

// All currently-open documents (path + name), so the panel can detect which
// documents were closed by diffing against the previous set. Handles closing one
// of several docs and switching the active doc — cases dhSaveState alone misses.
function dhOpenDocs() {
    var out = [];
    try {
        for (var i = 0; i < app.documents.length; i++) {
            var d = app.documents[i];
            var p = "";
            try { p = d.fullName.fsName; } catch (e) { p = ""; }
            out.push('{"path":"' + dhEscape(p) + '","name":"' + dhEscape(d.name) + '"}');
        }
    } catch (e2) {}
    return '[' + out.join(',') + ']';
}

// Lightweight state used by the panel to detect open / close transitions.
// Combines the active-doc state and the full open set into one call, because
// every evalScript round-trip runs on Illustrator's main thread.
function dhPollState() {
    var docsJSON = dhOpenDocs();
    if (app.documents.length === 0) {
        return '{"open":false,"path":"","name":"","docs":' + docsJSON + '}';
    }
    var doc = app.activeDocument;
    var path = "";
    try { path = doc.fullName.fsName; } catch (e) { path = ""; }
    return '{"open":true'
        + ',"path":"' + dhEscape(path) + '"'
        + ',"name":"' + dhEscape(doc.name) + '"'
        + ',"docs":' + docsJSON + '}';
}
