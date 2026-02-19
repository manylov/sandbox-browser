// Stealth patches — injected via --disable-blink-features=AutomationControlled
// and Chrome DevTools Protocol Page.addScriptToEvaluateOnNewDocument

// 1. Hide webdriver flag
Object.defineProperty(navigator, 'webdriver', { get: () => false });

// 2. Override permissions query for notifications
const originalQuery = window.Permissions.prototype.query;
window.Permissions.prototype.query = function(parameters) {
  if (parameters.name === 'notifications') {
    return Promise.resolve({ state: Notification.permission });
  }
  return originalQuery.call(this, parameters);
};

// 3. Fake plugins (Chrome normally has 5)
Object.defineProperty(navigator, 'plugins', {
  get: () => {
    const plugins = [
      { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
      { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '' },
      { name: 'Native Client', filename: 'internal-nacl-plugin', description: '' },
    ];
    plugins.refresh = () => {};
    return plugins;
  }
});

// 4. Fake languages
Object.defineProperty(navigator, 'languages', {
  get: () => ['en-US', 'en']
});

// 5. Hide chrome.runtime if it's exposing CDP
if (window.chrome) {
  const originalChrome = window.chrome;
  window.chrome = {
    ...originalChrome,
    runtime: {
      ...originalChrome.runtime,
      // Remove "id" which signals extension/CDP
      PlatformOs: originalChrome.runtime?.PlatformOs,
      PlatformArch: originalChrome.runtime?.PlatformArch,
      PlatformNaclArch: originalChrome.runtime?.PlatformNaclArch,
      RequestUpdateCheckStatus: originalChrome.runtime?.RequestUpdateCheckStatus,
    }
  };
  // Remove the connect/sendMessage which signal CDP
  delete window.chrome.runtime.connect;
  delete window.chrome.runtime.sendMessage;
}

// 6. Consistent WebGL vendor/renderer
const getParameter = WebGLRenderingContext.prototype.getParameter;
WebGLRenderingContext.prototype.getParameter = function(parameter) {
  if (parameter === 37445) return 'Google Inc. (Intel)';
  if (parameter === 37446) return 'ANGLE (Intel, Mesa Intel(R) UHD Graphics 630, OpenGL 4.6)';
  return getParameter.call(this, parameter);
};
const getParameter2 = WebGL2RenderingContext.prototype.getParameter;
WebGL2RenderingContext.prototype.getParameter = function(parameter) {
  if (parameter === 37445) return 'Google Inc. (Intel)';
  if (parameter === 37446) return 'ANGLE (Intel, Mesa Intel(R) UHD Graphics 630, OpenGL 4.6)';
  return getParameter2.call(this, parameter);
};

// 7. Fix broken Permission descriptor
const origDesc = Object.getOwnPropertyDescriptor(Notification, 'permission');
if (origDesc) {
  Object.defineProperty(Notification, 'permission', {
    ...origDesc,
    get: () => 'default'
  });
}

// 8. Remove CDP-specific properties from window
delete window.cdc_adoQpoasnfa76pfcZLmcfl_Array;
delete window.cdc_adoQpoasnfa76pfcZLmcfl_JSON;
delete window.cdc_adoQpoasnfa76pfcZLmcfl_Object;
delete window.cdc_adoQpoasnfa76pfcZLmcfl_Promise;
delete window.cdc_adoQpoasnfa76pfcZLmcfl_Proxy;
delete window.cdc_adoQpoasnfa76pfcZLmcfl_Symbol;

// Remove all cdc_ prefixed vars
for (const key of Object.keys(window)) {
  if (key.startsWith('cdc_') || key.startsWith('__cdc_')) {
    delete window[key];
  }
}
