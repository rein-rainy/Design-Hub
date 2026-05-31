// WebSocket client — connects to the Design Hub macOS app at localhost:49152.
// Queues outgoing messages while disconnected and flushes them on reconnect.

const WS_URL = 'ws://localhost:49152';
const RECONNECT_DELAYS = [1000, 2000, 5000, 10000, 30000];
const MAX_QUEUE = 50;

class Bridge {
  constructor() {
    /** @type {WebSocket|null} */
    this.ws = null;
    this.reconnectAttempt = 0;
    /** @type {object[]} */
    this.queue = [];
    /** @type {((status: 'connected'|'connecting'|'error') => void)|null} */
    this.onStatusChange = null;
    /** @type {((msg: object) => void)|null} */
    this.onMessage = null;
  }

  start() {
    this._connect();
  }

  /** @param {object} message */
  send(message) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    } else {
      if (this.queue.length < MAX_QUEUE) {
        this.queue.push(message);
      }
    }
  }

  _connect() {
    this.onStatusChange?.('connecting');
    try {
      this.ws = new WebSocket(WS_URL);

      this.ws.onopen = () => {
        this.reconnectAttempt = 0;
        this.onStatusChange?.('connected');
        for (const msg of this.queue.splice(0)) {
          this.ws.send(JSON.stringify(msg));
        }
      };

      this.ws.onclose = () => {
        this.onStatusChange?.('connecting');
        this._scheduleReconnect();
      };

      this.ws.onerror = () => {
        this.onStatusChange?.('error');
      };

      this.ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          this.onMessage?.(msg);
        } catch (_) {}
      };
    } catch (_) {
      this._scheduleReconnect();
    }
  }

  _scheduleReconnect() {
    const delay = RECONNECT_DELAYS[Math.min(this.reconnectAttempt, RECONNECT_DELAYS.length - 1)];
    this.reconnectAttempt++;
    setTimeout(() => this._connect(), delay);
  }
}

export const bridge = new Bridge();
