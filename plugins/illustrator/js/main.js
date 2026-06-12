// Design Hub — Illustrator CEP panel script.
// Forwards document snapshots to the macOS app over WebSocket — same protocol
// the Photoshop UXP plugin uses.
//
// Save detection lives in the macOS app (it watches the .ai file on disk and
// sends `request_save_snapshot`), so the panel only polls the host for
// open/close detection — slowly, because every evalScript runs on
// Illustrator's main thread and frequent calls disrupt the user's tools.

var cs = new CSInterface();

// ── Bridge (WebSocket client) ────────────────────────────────────────────────

var WS_URL = 'ws://localhost:49152';
var RECONNECT_DELAYS = [1000, 2000, 5000, 10000, 30000];

var bridge = (function () {
  var ws = null;
  var attempt = 0;
  var queue = [];
  var onStatusChange = null;
  var onMessage = null;

  function connect() {
    if (onStatusChange) onStatusChange('connecting');
    try {
      ws = new WebSocket(WS_URL);

      ws.onopen = function () {
        attempt = 0;
        if (onStatusChange) onStatusChange('connected');
        var pending = queue.splice(0);
        for (var i = 0; i < pending.length; i++) ws.send(JSON.stringify(pending[i]));
        // The app may have (re)started after Illustrator and knows nothing
        // about the documents already open. Forget our diff state and poll
        // immediately so document_opened is re-sent for the active doc.
        lastOpen = false;
        lastPath = '';
        knownDocs = [];
        poll();
      };

      ws.onclose = function () {
        if (onStatusChange) onStatusChange('connecting');
        scheduleReconnect();
      };

      ws.onerror = function () {
        if (onStatusChange) onStatusChange('error');
      };

      ws.onmessage = function (event) {
        try {
          var msg = JSON.parse(event.data);
          if (onMessage) onMessage(msg);
        } catch (e) {}
      };
    } catch (e) {
      scheduleReconnect();
    }
  }

  function scheduleReconnect() {
    var delay = RECONNECT_DELAYS[Math.min(attempt, RECONNECT_DELAYS.length - 1)];
    attempt++;
    setTimeout(connect, delay);
  }

  return {
    start: function () { connect(); },
    send: function (msg) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
      } else if (queue.length < 50) {
        queue.push(msg);
      }
    },
    setStatusHandler: function (fn) { onStatusChange = fn; },
    setMessageHandler: function (fn) { onMessage = fn; }
  };
})();

// ── UI ───────────────────────────────────────────────────────────────────────

var dot        = document.getElementById('dot');
var statusText = document.getElementById('statusText');
var lastEvent  = document.getElementById('lastEvent');

bridge.setStatusHandler(function (status) {
  dot.className = 'dot ' + status;
  var labels = { connected: 'Connected', connecting: 'Connecting…', error: 'Error' };
  statusText.textContent = labels[status] || status;
});

bridge.setMessageHandler(function (msg) {
  if (!msg) return;
  // Auto-save: save the document to disk first, then snapshot.
  if (msg.type === 'request_snapshot') sendSnapshot('snapshot_requested', 'dhSaveAndSnapshot');
  // The app saw the .ai file change on disk — the user just saved, so only
  // a snapshot is needed (saving again here would disturb the user).
  if (msg.type === 'request_save_snapshot') sendSnapshot('document_saved');
});

// ── Snapshot ─────────────────────────────────────────────────────────────────

function envelope(eventType, payload) {
  return {
    version: 1,
    type: eventType,
    app: 'illustrator',
    timestamp: new Date().toISOString(),
    payload: payload
  };
}

function sendSnapshot(eventType, hostFn) {
  cs.evalScript((hostFn || 'dhSnapshot') + '()', function (res) {
    if (!res || res === 'EvalScript error.' || res === 'undefined') return;
    var payload;
    try { payload = JSON.parse(res); } catch (e) { return; }
    bridge.send(envelope(eventType, payload));
    lastEvent.textContent = eventType + ' · ' + new Date().toLocaleTimeString();
  });
}

// ── Open / close detection (poll the host) ───────────────────────────────────
// Saves are detected by the macOS app watching the file on disk; this poll only
// notices documents opening, closing, and switching, so it can run rarely.

var POLL_INTERVAL_MS = 30000;

var lastOpen = false;
var lastPath = '';

// Snapshot of every open document, used to emit document_closed for any that
// disappear — covers closing one of several docs and switching the active doc.
var knownDocs = []; // [{ path, name }]

function docKey(d) {
  return d.path !== '' ? d.path : ('untitled:' + d.name);
}

function poll() {
  // One evalScript per tick: each call runs on Illustrator's main thread.
  cs.evalScript('dhPollState()', function (res) {
    var st;
    try { st = JSON.parse(res); } catch (e) { return; }

    // (1) Active-doc open detection (drives "Now Editing").
    if (st.open) {
      if (!lastOpen || st.path !== lastPath) {
        // A different document is now active (or the first one opened).
        // An untitled doc just saved-as (lastPath "" → real path) counts as a
        // save — it also tells the app which new file to start watching.
        var ev = (lastOpen && lastPath === '' && st.path !== '') ? 'document_saved' : 'document_opened';
        if (ev === 'document_opened' || st.path !== '') sendSnapshot(ev);
      }
      lastOpen = true;
      lastPath = st.path;
    } else {
      lastOpen = false;
      lastPath = '';
    }

    // (2) Reconcile the full open set so closed docs leave "Now Editing".
    var docs = st.docs || [];
    for (var i = 0; i < knownDocs.length; i++) {
      var prev = knownDocs[i];
      var stillOpen = false;
      for (var j = 0; j < docs.length; j++) {
        if (docKey(docs[j]) === docKey(prev)) { stillOpen = true; break; }
      }
      if (!stillOpen) {
        bridge.send(envelope('document_closed', {
          path: prev.path, name: prev.name,
          layerCount: 0, topLevelLayerCount: 0, layerTree: [],
          artboardCount: 0, artboardNames: []
        }));
        lastEvent.textContent = 'document_closed · ' + new Date().toLocaleTimeString();
      }
    }
    knownDocs = docs;
  });
}

bridge.start();
setInterval(poll, POLL_INTERVAL_MS);
poll();
