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

  function apiPathWithShop(path, shopDomain) {
    var url = new URL(path, window.location.origin);
    if (shopDomain && !url.searchParams.get("shop")) {
      url.searchParams.set("shop", shopDomain);
    }
    return url.pathname + url.search;
  }

  function formatRequestType(value) {
    switch (value) {
      case "sync.full":
        return "Full sync";
      case "sync.incremental":
        return "Incremental sync";
      case "sync.first_time":
        return "First-time sync";
      case "sync.bulk_finish":
        return "Bulk finish import";
      case "sync.bulk_start":
        return "Bulk sync";
      default:
        return value || "Async request";
    }
  }

  function truncateText(value, maxLength) {
    if (!value) return "";
    if (value.length <= maxLength) return value;
    return value.slice(0, maxLength - 1) + "…";
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
    banner.dataset.queuedAt = status.queuedAt || "";

    if (status.status === "running") {
      banner.classList.remove("is-hidden");
      text('[data-role="status-label"]', "Syncing orders", banner);
      text('[data-role="status-meta"]', synced + " of " + total + " orders synced", banner);
      text('[data-role="progress-value"]', progress + "%", banner);
      var progressBar = $('[data-role="progress-bar"]', banner);
      if (progressBar) progressBar.style.width = progress + "%";
      return;
    }

    if (status.status === "queued") {
      banner.classList.remove("is-hidden");
      text('[data-role="status-label"]', "Sync queued", banner);
      text('[data-role="status-meta"]', "Waiting for the background worker to start this sync.", banner);
      text('[data-role="progress-value"]', "0%", banner);
      var queuedBar = $('[data-role="progress-bar"]', banner);
      if (queuedBar) queuedBar.style.width = "0%";
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

  function renderAsyncRequestPanel(banner, requests) {
    var panel = $('[data-role="async-request-panel"]', banner);
    var list = $('[data-role="async-request-list"]', banner);
    var empty = $('[data-role="async-request-empty"]', banner);
    var count = $('[data-role="async-request-count"]', banner);
    var retryLatestButton = $('[data-action="retry-latest-failed"]', banner);
    var retryAllButton = $('[data-action="retry-all-failed"]', banner);

    if (!panel || !list || !empty || !count) return;

    list.innerHTML = "";
    count.textContent = requests.length + (requests.length === 1 ? " request" : " requests");
    if (retryLatestButton) retryLatestButton.disabled = requests.length === 0;
    if (retryAllButton) retryAllButton.disabled = requests.length === 0;

    if (!requests.length) {
      panel.classList.add("is-hidden");
      empty.classList.add("is-hidden");
      return;
    }

    panel.classList.remove("is-hidden");
    empty.classList.add("is-hidden");

    requests.forEach(function (request) {
      var card = document.createElement("article");
      card.className = "sync-request-card";

      var row = document.createElement("div");
      row.className = "sync-request-row";

      var copy = document.createElement("div");

      var title = document.createElement("div");
      title.className = "sync-request-title";
      title.textContent = formatRequestType(request.requestType);
      copy.appendChild(title);

      var meta = document.createElement("div");
      meta.className = "sync-request-meta";
      meta.textContent = "Attempts " + request.attempts + " • Failed " + timeAgo(request.updatedAt);
      copy.appendChild(meta);
      row.appendChild(copy);

      var actions = document.createElement("div");
      actions.className = "sync-request-actions";

      if (request.canRetry) {
        var retryButton = document.createElement("button");
        retryButton.type = "button";
        retryButton.className = "sync-request-button";
        retryButton.dataset.action = "retry";
        retryButton.dataset.requestId = request.id;
        retryButton.textContent = "Retry";
        actions.appendChild(retryButton);
      }

      if (request.canDelete) {
        var deleteButton = document.createElement("button");
        deleteButton.type = "button";
        deleteButton.className = "sync-request-button is-danger";
        deleteButton.dataset.action = "delete";
        deleteButton.dataset.requestId = request.id;
        deleteButton.textContent = "Delete";
        actions.appendChild(deleteButton);
      }

      row.appendChild(actions);
      card.appendChild(row);

      var error = document.createElement("div");
      error.className = "sync-request-error";
      error.textContent = truncateText(request.errorMessage || "No error message recorded.", 240);
      card.appendChild(error);

      list.appendChild(card);
    });
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
    var asyncRecoveryEnabled = banner.dataset.asyncEnabled === "true";
    var refreshingFailedRequests = false;

    updateSyncBanner({
      status: banner.dataset.status,
      ordersSynced: banner.dataset.ordersSynced,
      totalEstimated: banner.dataset.totalEstimated,
      lastSyncedAt: banner.dataset.lastSyncedAt,
      queuedAt: banner.dataset.queuedAt
    });

    async function refreshSyncBanner() {
      try {
        var payload = await requestJson(apiPathWithShop(banner.dataset.apiPath, banner.dataset.shopDomain));
        updateSyncBanner(payload);
      } catch (_error) {
        // Ignore polling failures.
      }
    }

    async function refreshFailedAsyncRequests() {
      if (!asyncRecoveryEnabled) return;
      if (refreshingFailedRequests) return;
      refreshingFailedRequests = true;
      try {
        var payload = await requestJson(apiPathWithShop(banner.dataset.asyncRequestsPath, banner.dataset.shopDomain));
        renderAsyncRequestPanel(banner, payload.requests || []);
      } catch (_error) {
        renderAsyncRequestPanel(banner, []);
      } finally {
        refreshingFailedRequests = false;
      }
    }

    banner.addEventListener("click", async function (event) {
      var button = event.target.closest("[data-action]");
      if (!button) return;

      var requestId = button.dataset.requestId;
      var action = button.dataset.action;
      if (!action) return;
      if ((action === "retry" || action === "delete") && !requestId) return;
      if (!asyncRecoveryEnabled) return;

      button.disabled = true;
      try {
        if (action === "retry") {
          await requestJson(apiPathWithShop("/api/async-requests/" + encodeURIComponent(requestId) + "/retry", banner.dataset.shopDomain), {
            method: "POST"
          });
        } else if (action === "delete") {
          await requestJson(apiPathWithShop("/api/async-requests/" + encodeURIComponent(requestId), banner.dataset.shopDomain), {
            method: "DELETE"
          });
        } else if (action === "retry-latest-failed") {
          await requestJson(apiPathWithShop(banner.dataset.asyncRetryLatestPath, banner.dataset.shopDomain), {
            method: "POST"
          });
        } else if (action === "retry-all-failed") {
          await requestJson(apiPathWithShop(banner.dataset.asyncRetryAllPath, banner.dataset.shopDomain), {
            method: "POST"
          });
        }
        await refreshSyncBanner();
        await refreshFailedAsyncRequests();
      } catch (_error) {
        button.disabled = false;
      }
    });

    if (asyncRecoveryEnabled) refreshFailedAsyncRequests();

    window.setInterval(async function () {
      await refreshSyncBanner();
      if (asyncRecoveryEnabled) await refreshFailedAsyncRequests();
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
            if (status.firstTimeSyncStatus === "initial_sync_pending") {
              meta.textContent = "Loading the latest 3 days of orders first.";
            } else {
              meta.textContent = "Syncing " + synced + " of " + total + " orders";
            }
          } else if (status.status === "completed") {
            if (status.fullSixMonthsSyncCompleted === false) {
              meta.textContent = "Recent orders are ready. Older orders will continue syncing in the background.";
            } else {
              meta.textContent = "Sync complete. Redirecting to your dashboard.";
            }
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
          body: JSON.stringify({ type: "first_time" })
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
