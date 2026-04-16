(function () {
  const pending = new Map();
  const listeners = new Map();

  window.__enoBridgeResolve = function (payload) {
    const item = pending.get(payload.id);
    if (!item) return;
    pending.delete(payload.id);

    if (payload.error) {
      item.reject(new Error(payload.error));
    } else {
      item.resolve(payload.result);
    }
  };

  window.__enoBridgeEmit = function (payload) {
    const channelListeners = listeners.get(payload.channel);
    if (!channelListeners) return;
    for (const listener of Array.from(channelListeners)) {
      try {
        listener({ type: payload.channel }, ...(payload.args || []));
      } catch (error) {
        console.error(error);
      }
    }
  };

  window.enoPlatform = {
    invoke(channel, ...args) {
      return new Promise((resolve, reject) => {
        const id = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
        pending.set(id, { resolve, reject });

        window.webkit.messageHandlers.enoBridge.postMessage({
          id,
          channel,
          args,
        });
      });
    },
  };

  window.ipcRenderer = {
    invoke(channel, ...args) {
      return window.enoPlatform.invoke(channel, ...args);
    },
    send(channel, ...args) {
      window.enoPlatform.invoke(channel, ...args).catch(console.error);
    },
    on(channel, listener) {
      if (!listeners.has(channel)) listeners.set(channel, new Set());
      listeners.get(channel).add(listener);
    },
    off(channel, listener) {
      const channelListeners = listeners.get(channel);
      if (!channelListeners) return;
      channelListeners.delete(listener);
      if (!channelListeners.size) listeners.delete(channel);
    },
  };

  function isBiliPage() {
    return /(^|\.)bilibili\.com$/.test(location.hostname) || /(^|\.)biliapi\.(com|net)$/.test(location.hostname);
  }

  function injectBiliLoginPanel() {
    if (!isBiliPage() || document.getElementById("eno-ios-login-panel")) return;

    const panel = document.createElement("div");
    panel.id = "eno-ios-login-panel";
    panel.style.cssText = [
      "position:fixed",
      "left:12px",
      "right:12px",
      "bottom:calc(12px + env(safe-area-inset-bottom))",
      "z-index:2147483647",
      "display:flex",
      "gap:8px",
      "padding:10px",
      "background:rgba(5,5,5,.88)",
      "border:1px solid rgba(255,255,255,.18)",
      "border-radius:8px",
      "backdrop-filter:blur(14px)",
      "font-family:-apple-system,BlinkMacSystemFont,sans-serif",
      "box-shadow:0 12px 30px rgba(0,0,0,.35)",
    ].join(";");

    const syncButton = document.createElement("button");
    syncButton.textContent = "同步登录状态";
    syncButton.style.cssText = buttonStyle("#14b8a6", "#041f1d");

    const closeButton = document.createElement("button");
    closeButton.textContent = "返回 ENO-M";
    closeButton.style.cssText = buttonStyle("#27272a", "#f4f4f5");

    syncButton.addEventListener("click", async () => {
      syncButton.disabled = true;
      syncButton.textContent = "同步中...";
      try {
        const result = await window.ipcRenderer.invoke("bili-web-login-sync");
        syncButton.textContent = result && result.success ? "已同步" : "未登录";
        alert(JSON.stringify(result, null, 2));
      } catch (error) {
        syncButton.textContent = "同步失败";
        alert(String(error && error.message ? error.message : error));
      } finally {
        setTimeout(() => {
          syncButton.disabled = false;
          syncButton.textContent = "同步登录状态";
        }, 1200);
      }
    });

    closeButton.addEventListener("click", () => {
      window.ipcRenderer.invoke("bili-web-login-close").catch(console.error);
    });

    panel.append(syncButton, closeButton);
    document.documentElement.appendChild(panel);
  }

  function buttonStyle(background, color) {
    return [
      "appearance:none",
      "border:0",
      "border-radius:8px",
      "padding:10px 12px",
      "font-size:15px",
      "font-weight:700",
      `background:${background}`,
      `color:${color}`,
      "flex:1",
    ].join(";");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", injectBiliLoginPanel);
  } else {
    injectBiliLoginPanel();
  }
})();
