(function () {
  function $(selector, root) {
    return (root || document).querySelector(selector);
  }

  function text(selector, value, root) {
    var node = $(selector, root);
    if (node) node.textContent = value;
  }

  function asNumber(value) {
    var parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  function timeAgo(isoString) {
    if (!isoString) return "never";
    var seconds = Math.floor((Date.now() - new Date(isoString).getTime()) / 1000);
    if (seconds < 60) return seconds + "s ago";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago";
    return Math.floor(seconds / 86400) + "d ago";
  }

  function updateSyncBanner(status) {
    var banner = $("#sync-banner");
    if (!banner || !status) return;

    var synced = asNumber(status.ordersSynced);
    var total = asNumber(status.totalEstimated);
    var progress = total > 0 ? Math.round((synced / total) * 100) : 0;

    banner.dataset.status = status.status || "idle";
    banner.dataset.ordersSynced = String(synced);
    banner.dataset.totalEstimated = String(total);
    banner.dataset.lastSyncedAt = status.lastSyncedAt || "";

    if (status.status === "running") {
      banner.classList.remove("is-hidden");
      text('[data-role="status-label"]', "Syncing orders", banner);
      text('[data-role="status-meta"]', synced + " of " + total + " orders synced", banner);
      text('[data-role="progress-value"]', progress + "%", banner);
      var progressBar = $('[data-role="progress-bar"]', banner);
      if (progressBar) progressBar.style.width = progress + "%";
      return;
    }

    if (status.status === "failed") {
      banner.classList.remove("is-hidden");
      text('[data-role="status-label"]', "Sync failed", banner);
      text('[data-role="status-meta"]', "The latest sync did not complete.", banner);
      text('[data-role="progress-value"]', "0%", banner);
      var failedBar = $('[data-role="progress-bar"]', banner);
      if (failedBar) failedBar.style.width = "0%";
      return;
    }

    if (status.lastSyncedAt) {
      banner.classList.remove("is-hidden");
      text('[data-role="status-label"]', "Last synced " + timeAgo(status.lastSyncedAt), banner);
      text('[data-role="status-meta"]', "Shopify data is ready.", banner);
      text('[data-role="progress-value"]', "100%", banner);
      var completeBar = $('[data-role="progress-bar"]', banner);
      if (completeBar) completeBar.style.width = "100%";
      return;
    }

    banner.classList.add("is-hidden");
  }

  async function requestJson(url, options) {
    var response = await fetch(url, options || {});
    var payload = {};
    try {
      payload = await response.json();
    } catch (_error) {
      payload = {};
    }
    if (!response.ok) {
      throw new Error(payload.error || "Request failed");
    }
    return payload;
  }

  function bootSyncPolling() {
    var banner = $("#sync-banner");
    if (!banner || !banner.dataset.shopDomain) return;

    updateSyncBanner({
      status: banner.dataset.status,
      ordersSynced: banner.dataset.ordersSynced,
      totalEstimated: banner.dataset.totalEstimated,
      lastSyncedAt: banner.dataset.lastSyncedAt
    });

    window.setInterval(async function () {
      try {
        var payload = await requestJson(banner.dataset.apiPath);
        updateSyncBanner(payload);
      } catch (_error) {
        // Ignore polling failures.
      }
    }, 5000);
  }

  function bootOnboardingSync() {
    var shell = $("#onboarding-sync");
    if (!shell) return;

    var label = $('[data-role="sync-label"]', shell);
    var meta = $('[data-role="sync-meta"]', shell);
    var progress = $('[data-role="sync-progress"]', shell);
    var retry = $('[data-role="sync-retry"]', shell);

    async function refreshStatus() {
      try {
        var status = await requestJson(shell.dataset.statusPath);
        var total = asNumber(status.totalEstimated);
        var synced = asNumber(status.ordersSynced);
        var percent = total > 0 ? Math.round((synced / total) * 100) : 0;

        if (label) {
          label.textContent = status.status === "failed" ? "Sync failed" : "Setting up your store";
        }

        if (meta) {
          if (status.status === "running") {
            meta.textContent = "Syncing " + synced + " of " + total + " orders";
          } else if (status.status === "completed") {
            meta.textContent = "Sync complete. Redirecting to your dashboard.";
          } else if (status.status === "failed") {
            meta.textContent = "Something went wrong while syncing your store.";
          } else {
            meta.textContent = "Preparing your initial order sync.";
          }
        }

        if (progress) {
          progress.style.width = percent + "%";
        }

        if (status.status === "completed") {
          window.setTimeout(function () {
            window.location.href = shell.dataset.completePath;
          }, 500);
          return true;
        }

        if (status.status === "failed" && retry) {
          retry.hidden = false;
        }

        return status.status === "running";
      } catch (_error) {
        return false;
      }
    }

    async function startSync() {
      if (retry) retry.hidden = true;
      try {
        await requestJson(shell.dataset.apiPath, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ type: "full" })
        });
      } catch (_error) {
        // Ignore initial trigger failures; polling will show the latest state.
      }

      var interval = window.setInterval(async function () {
        var keepGoing = await refreshStatus();
        if (!keepGoing) {
          clearInterval(interval);
          if (shell.dataset.autostart === "true") {
            await refreshStatus();
          }
        }
      }, 1500);
    }

    if (retry) {
      retry.addEventListener("click", function () {
        startSync();
      });
    }

    startSync();
  }

  function bootInvoicePreview() {
    var form = $("#invoice-template-form");
    var preview = $("#invoice-preview");
    if (!form || !preview) return;

    form.querySelectorAll("[data-preview-text]").forEach(function (field) {
      field.addEventListener("input", function () {
        var key = field.getAttribute("data-preview-text");
        preview.querySelectorAll('[data-preview-key="' + key + '"]').forEach(function (node) {
          node.textContent = field.value || "-";
        });
      });
    });

    form.querySelectorAll("[data-preview-toggle]").forEach(function (field) {
      field.addEventListener("change", function () {
        var key = field.getAttribute("data-preview-toggle");
        preview.querySelectorAll('[data-visibility-key="' + key + '"]').forEach(function (node) {
          node.hidden = !field.checked;
        });
      });
    });
  }

  bootSyncPolling();
  bootOnboardingSync();
  bootInvoicePreview();
})();
