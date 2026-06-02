// Minimal CSInterface shim for Design Hub.
// CEP injects `window.__adobe_cep__`; we only need evalScript + a couple of helpers.
// (The full Adobe CSInterface library is not required for this panel.)

function CSInterface() {
  try {
    this.hostEnvironment = JSON.parse(window.__adobe_cep__.getHostEnvironment());
  } catch (e) {
    this.hostEnvironment = null;
  }
}

/**
 * Run an ExtendScript string in the host (Illustrator). The host's return
 * value (a string) is passed to `callback`. On error the result is the
 * literal "EvalScript error.".
 */
CSInterface.prototype.evalScript = function (script, callback) {
  if (callback === null || callback === undefined) callback = function () {};
  window.__adobe_cep__.evalScript(script, callback);
};

CSInterface.prototype.getApplicationID = function () {
  return this.hostEnvironment ? this.hostEnvironment.appName : "";
};

CSInterface.prototype.addEventListener = function (type, listener, obj) {
  window.__adobe_cep__.addEventListener(type, listener, obj);
};

CSInterface.prototype.removeEventListener = function (type, listener, obj) {
  window.__adobe_cep__.removeEventListener(type, listener, obj);
};
