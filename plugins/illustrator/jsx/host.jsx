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

    return '{"id":0'
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

    return '{'
        + '"path":"' + dhEscape(path) + '"'
        + ',"name":"' + dhEscape(doc.name) + '"'
        + ',"layerCount":' + dhCountLayers(doc.layers)
        + ',"topLevelLayerCount":' + doc.layers.length
        + ',"layerTree":[' + layerJSONs.join(',') + ']'
        + ',"artboardCount":' + abNames.length
        + ',"artboardNames":[' + abNames.join(',') + ']'
        + '}';
}

// Lightweight state used by the panel to detect open / save / close transitions.
function dhSaveState() {
    if (app.documents.length === 0) {
        return '{"open":false,"saved":true,"path":"","name":""}';
    }
    var doc = app.activeDocument;
    var path = "";
    try { path = doc.fullName.fsName; } catch (e) { path = ""; }
    var saved = true;
    try { saved = doc.saved; } catch (e2) {}
    return '{"open":true'
        + ',"saved":' + (saved ? 'true' : 'false')
        + ',"path":"' + dhEscape(path) + '"'
        + ',"name":"' + dhEscape(doc.name) + '"}';
}
