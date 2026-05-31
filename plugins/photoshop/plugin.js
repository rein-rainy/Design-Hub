// Design Hub — Photoshop UXP Plugin (panel script)

const { app, action } = require('photoshop');

// ── Bridge (WebSocket client) ────────────────────────────────────────────────

const WS_URL = 'ws://localhost:49152';
const RECONNECT_DELAYS = [1000, 2000, 5000, 10000, 30000];

const bridge = (() => {
  let ws = null;
  let attempt = 0;
  let queue = [];
  let onStatusChange = null;
  let onMessage = null;

  function connect() {
    if (onStatusChange) onStatusChange('connecting');
    try {
      ws = new WebSocket(WS_URL);

      ws.onopen = () => {
        attempt = 0;
        if (onStatusChange) onStatusChange('connected');
        const pending = queue.splice(0);
        for (const msg of pending) ws.send(JSON.stringify(msg));
      };

      ws.onclose = () => {
        if (onStatusChange) onStatusChange('connecting');
        scheduleReconnect();
      };

      ws.onerror = () => {
        if (onStatusChange) onStatusChange('error');
      };

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (onMessage) onMessage(msg);
        } catch (_) {}
      };
    } catch (_) {
      scheduleReconnect();
    }
  }

  function scheduleReconnect() {
    const delay = RECONNECT_DELAYS[Math.min(attempt, RECONNECT_DELAYS.length - 1)];
    attempt++;
    setTimeout(connect, delay);
  }

  return {
    start() { connect(); },
    send(msg) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
      } else if (queue.length < 50) {
        queue.push(msg);
      }
    },
    setStatusHandler(fn) { onStatusChange = fn; },
    setMessageHandler(fn) { onMessage = fn; },
  };
})();

// ── Layer utilities ──────────────────────────────────────────────────────────

const KIND_MAP = {
  1: 'pixel', 2: 'adjustment', 3: 'text', 4: 'vector',
  5: 'smartObject', 6: 'video', 7: 'group', 8: 'threeD',
  9: 'gradient', 10: 'pattern', 11: 'solidColor', 13: 'background',
};

function buildLayerTree(layers) {
  const nodes = [];
  for (const layer of layers) {
    const node = {
      id: layer.id,
      name: layer.name,
      kind: KIND_MAP[layer.kind] || String(layer.kind),
      visible: layer.visible,
      children: [],
    };
    if (layer.layers && layer.layers.length > 0) {
      node.children = buildLayerTree(layer.layers);
    }
    nodes.push(node);
  }
  return nodes;
}

function countLayers(layers) {
  let n = 0;
  for (const layer of layers) {
    n++;
    if (layer.layers && layer.layers.length > 0) n += countLayers(layer.layers);
  }
  return n;
}

// ── UI ───────────────────────────────────────────────────────────────────────

const dot        = document.getElementById('dot');
const statusText = document.getElementById('statusText');
const lastEvent  = document.getElementById('lastEvent');

bridge.setStatusHandler((status) => {
  dot.className = 'dot ' + status;
  const labels = { connected: 'Connected', connecting: 'Connecting…', error: 'Error' };
  statusText.textContent = labels[status] || status;
  console.log('[DesignHub] bridge status:', status);
});

bridge.setMessageHandler((msg) => {
  if (msg.type === 'request_snapshot') sendSnapshot('snapshot_requested');
});

// ── Snapshot ─────────────────────────────────────────────────────────────────

function sendSnapshot(eventType) {
  const doc = app.activeDocument;
  if (!doc) return;

  const tree = buildLayerTree(doc.layers);
  const message = {
    version: 1,
    type: eventType,
    app: 'photoshop',
    timestamp: new Date().toISOString(),
    payload: {
      path: doc.path || '',
      name: doc.title,
      layerCount: countLayers(doc.layers),
      topLevelLayerCount: doc.layers.length,
      layerTree: tree,
    },
  };

  bridge.send(message);
  lastEvent.textContent = eventType + ' · ' + new Date().toLocaleTimeString();
  console.log('[DesignHub] sent:', eventType, '| layers:', message.payload.layerCount, '| file:', message.payload.name);
}

// ── Event listeners ───────────────────────────────────────────────────────────

// PS fires 'save' multiple times per operation. Debounce to emit only once.
let saveTimer = null;

async function setup() {
  await action.addNotificationListener(['save'], () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => sendSnapshot('document_saved'), 500);
  });

  await action.addNotificationListener(['open'], () => {
    sendSnapshot('document_opened');
  });

  await action.addNotificationListener(['close'], () => {
    const doc = app.activeDocument;
    if (!doc) return;
    bridge.send({
      version: 1,
      type: 'document_closed',
      app: 'photoshop',
      timestamp: new Date().toISOString(),
      payload: { path: doc.path || '', name: doc.title, layerCount: 0, topLevelLayerCount: 0, layerTree: [] },
    });
  });
}

console.log('[DesignHub] plugin starting…');
bridge.start();
setup().catch(console.error);
