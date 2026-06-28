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

    // Sync has settled. Hide the banner for merchants; admins keep it visible
    // so the background-request recovery tools remain reachable.
    if (status.lastSyncedAt && banner.dataset.asyncEnabled === "true") {
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
    var detail = $('[data-role="sync-error-detail"]', shell);
    var progress = $('[data-role="sync-progress"]', shell);
    var retry = $('[data-role="sync-retry"]', shell);
    var shopDomain = shell.dataset.shopDomain || new URL(window.location.href).searchParams.get("shop") || "";

    function syncErrorMessage(status) {
      if (status.errorMessage) return status.errorMessage;
      if (!Array.isArray(status.batches)) return "";
      var failedBatch = status.batches.find(function (batch) {
        return batch.status === "failed" && batch.error_message;
      });
      return failedBatch ? failedBatch.error_message : "";
    }

    function friendlySyncError(errorMessage) {
      if (!errorMessage) return "";
      if (/not approved to access the Order object/i.test(errorMessage)) {
        return "Enable protected customer data access for this app in Shopify Partner Dashboard, then retry the sync.";
      }
      return errorMessage;
    }

    function renderStatus(status) {
      var total = asNumber(status.totalEstimated);
      var synced = asNumber(status.ordersSynced);
      var percent = total > 0 ? Math.round((synced / total) * 100) : 0;
      var errorMessage = syncErrorMessage(status);
      var friendlyError = friendlySyncError(errorMessage);

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
          meta.textContent = /not approved to access the Order object/i.test(errorMessage)
            ? "Shopify is blocking order access for this app."
            : "Something went wrong while syncing your store.";
        } else {
          meta.textContent = "Preparing your initial order sync.";
        }
      }

      if (detail) {
        if (friendlyError) {
          detail.hidden = false;
          detail.textContent = friendlyError;
        } else {
          detail.hidden = true;
          detail.textContent = "";
        }
      }

      if (progress) {
        progress.style.width = percent + "%";
      }

      if (status.status === "completed") {
        window.setTimeout(function () {
          window.location.href = apiPathWithShop(shell.dataset.completePath, shopDomain);
        }, 500);
        return false;
      }

      if (retry) {
        retry.hidden = status.status !== "failed";
      }

      return status.status === "running" || status.status === "queued";
    }

    async function refreshStatus() {
      try {
        var status = await requestJson(apiPathWithShop(shell.dataset.statusPath, shopDomain));
        return renderStatus(status);
      } catch (_error) {
        return false;
      }
    }

    async function pollStatus() {
      var keepGoing = await refreshStatus();
      if (!keepGoing) return;

      var interval = window.setInterval(async function () {
        var next = await refreshStatus();
        if (!next) clearInterval(interval);
      }, 1500);
    }

    async function startSync(triggerRequest) {
      if (retry) retry.hidden = true;
      if (triggerRequest) {
        try {
          await requestJson(apiPathWithShop(shell.dataset.apiPath, shopDomain), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ type: "first_time" })
          });
        } catch (_error) {
          // Ignore trigger failures; the latest status will explain what happened.
        }
      }

      await pollStatus();
    }

    if (retry) {
      retry.addEventListener("click", function () {
        startSync(true);
      });
    }

    (async function init() {
      try {
        var status = await requestJson(apiPathWithShop(shell.dataset.statusPath, shopDomain));
        var keepGoing = renderStatus(status);
        if (status.status === "idle") {
          await startSync(true);
          return;
        }

        if (keepGoing) {
          await pollStatus();
        }
      } catch (_error) {
        if (shell.dataset.autostart === "true") {
          await startSync(true);
        }
      }
    })();
  }

  function bootInvoicePreview() {
    var form = $("#invoice-template-form");
    var preview = $("#invoice-preview");
    if (!form || !preview) return;

    function titleCase(value) {
      return (value || "")
        .split(/[_\s-]+/)
        .filter(Boolean)
        .map(function (part) {
          return part.charAt(0).toUpperCase() + part.slice(1);
        })
        .join(" ");
    }

    function formatCurrency(symbol, amount) {
      return (symbol || "$") + Number(amount || 0).toFixed(2);
    }

    function lineItems() {
      var rows = {};
      form.querySelectorAll("[data-line-item-index]").forEach(function (field) {
        var index = field.getAttribute("data-line-item-index");
        var key = field.getAttribute("data-line-item-field");
        rows[index] = rows[index] || { desc: "", qty: 0, rate: 0, discount: 0, tax: 0 };
        if (key === "desc") {
          rows[index][key] = field.value || "";
        } else {
          rows[index][key] = Number(field.value || 0);
        }
      });
      return Object.keys(rows)
        .sort()
        .map(function (key) {
          return rows[key];
        });
    }

    function renderLineItems() {
      var tbody = $('[data-role="preview-line-items-body"]', preview);
      var subtotalNode = $('[data-role="preview-subtotal"]', preview);
      var taxNode = $('[data-role="preview-tax"]', preview);
      var totalNode = $('[data-role="preview-total"]', preview);
      var currencyField = $("#currency_symbol", form);
      var symbol = currencyField ? currencyField.value : "$";
      var subtotal = 0;
      var taxTotal = 0;
      var items = lineItems().filter(function (item) {
        return item.desc.trim() !== "" || item.qty > 0 || item.rate > 0;
      });

      if (tbody) tbody.innerHTML = "";

      if (!items.length && tbody) {
        var emptyRow = document.createElement("tr");
        emptyRow.innerHTML = '<td colspan="4" class="muted">Add line items to build this invoice.</td>';
        tbody.appendChild(emptyRow);
      }

      items.forEach(function (item) {
        var base = item.qty * item.rate;
        var discounted = base - (base * item.discount / 100);
        var taxAmount = discounted * item.tax / 100;
        subtotal += discounted;
        taxTotal += taxAmount;

        if (!tbody) return;
        var row = document.createElement("tr");
        var desc = document.createElement("td");
        desc.textContent = item.desc || "Untitled item";
        var qty = document.createElement("td");
        qty.className = "align-right";
        qty.textContent = String(item.qty);
        var rate = document.createElement("td");
        rate.className = "align-right";
        rate.textContent = formatCurrency(symbol, item.rate);
        var amount = document.createElement("td");
        amount.className = "align-right";
        amount.textContent = formatCurrency(symbol, discounted);
        row.appendChild(desc);
        row.appendChild(qty);
        row.appendChild(rate);
        row.appendChild(amount);
        tbody.appendChild(row);
      });

      if (subtotalNode) subtotalNode.textContent = formatCurrency(symbol, subtotal);
      if (taxNode) taxNode.textContent = formatCurrency(symbol, taxTotal);
      if (totalNode) totalNode.textContent = formatCurrency(symbol, subtotal + taxTotal);
    }

    function applyTemplateStyle(value) {
      var template = value || "classic";
      preview.dataset.template = template;
      var label = $('[data-role="template-style-label"]', preview);
      if (label) {
        label.textContent = titleCase(template);
      }
      form.querySelectorAll("[data-template-choice]").forEach(function (item) {
        item.classList.toggle("is-active", item.getAttribute("data-template-choice") === template);
      });
    }

    function bindPreviewText(field) {
      function update() {
        var key = field.getAttribute("data-preview-text");
        preview.querySelectorAll('[data-preview-key="' + key + '"]').forEach(function (node) {
          node.textContent = field.value || "-";
        });
      }

      field.addEventListener("input", update);
      field.addEventListener("change", update);
    }

    form.querySelectorAll("[data-preview-text]").forEach(function (field) {
      bindPreviewText(field);
    });

    form.querySelectorAll("[data-preview-toggle]").forEach(function (field) {
      function updateToggle() {
        var key = field.getAttribute("data-preview-toggle");
        preview.querySelectorAll('[data-visibility-key="' + key + '"]').forEach(function (node) {
          node.hidden = !field.checked;
        });
      }

      field.addEventListener("change", updateToggle);
      updateToggle();
    });

    form.querySelectorAll("[data-preview-style]").forEach(function (field) {
      function applyStyle() {
        var styleKey = field.getAttribute("data-preview-style");
        if (styleKey === "accent_color") {
          preview.style.setProperty("--invoice-accent", field.value || "#147c64");
        } else if (styleKey === "font_family") {
          preview.style.setProperty("--invoice-font", field.value || '"IBM Plex Sans", "Aptos", "Segoe UI", sans-serif');
        } else if (styleKey === "surface_tone") {
          preview.dataset.surfaceTone = field.value || "paper";
        } else if (styleKey === "density") {
          preview.dataset.density = field.value || "comfortable";
        } else if (styleKey === "header_align") {
          preview.dataset.headerAlign = field.value || "split";
        }
      }

      field.addEventListener("input", applyStyle);
      field.addEventListener("change", applyStyle);
      applyStyle();
    });

    var templateSelect = form.querySelector("[data-preview-template]");
    if (templateSelect) {
      applyTemplateStyle(templateSelect.value);
      templateSelect.addEventListener("change", function () {
        applyTemplateStyle(templateSelect.value);
      });
    }

    form.querySelectorAll("[data-template-choice]").forEach(function (button) {
      button.addEventListener("click", function () {
        var template = button.getAttribute("data-template-choice");
        if (templateSelect) {
          templateSelect.value = template;
          applyTemplateStyle(template);
        }
      });
    });

    form.querySelectorAll("[data-line-item-index]").forEach(function (field) {
      field.addEventListener("input", renderLineItems);
      field.addEventListener("change", renderLineItems);
    });

    var currencyField = $("#currency_symbol", form);
    if (currencyField) {
      currencyField.addEventListener("change", renderLineItems);
      currencyField.addEventListener("input", renderLineItems);
    }

    renderLineItems();
  }

  function bootDateRangePicker() {
    var MONTHS = ["January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December"];
    var MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var WEEKDAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];

    function pad(value) {
      return value < 10 ? "0" + value : String(value);
    }

    // Parse/format plain YYYY-MM-DD strings without timezone drift.
    function parseDate(value) {
      if (!value) return null;
      var parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
      if (!parts) return null;
      return new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]));
    }

    function formatDate(date) {
      return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
    }

    function formatLabel(date) {
      return MONTHS_SHORT[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear();
    }

    function startOfDay(date) {
      return new Date(date.getFullYear(), date.getMonth(), date.getDate());
    }

    function addDays(date, days) {
      var next = startOfDay(date);
      next.setDate(next.getDate() + days);
      return next;
    }

    function sameDay(a, b) {
      return a && b && a.getFullYear() === b.getFullYear() &&
        a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    function setupOne(root) {
      var fromInput = root.querySelector('input[name="from"]');
      var toInput = root.querySelector('input[name="to"]');
      if (!fromInput || !toInput) return;
      var form = root.closest("form");

      var state = {
        from: parseDate(fromInput.value),
        to: parseDate(toInput.value),
        view: null
      };
      state.view = startOfDay(state.from || state.to || new Date());
      state.view.setDate(1);

      // Inline style hides the native fallback regardless of stylesheet caching.
      var native = root.querySelector(".date-range-native");
      if (native) native.style.display = "none";

      var trigger = document.createElement("button");
      trigger.type = "button";
      trigger.className = "date-range-trigger";
      trigger.setAttribute("aria-haspopup", "dialog");
      trigger.setAttribute("aria-expanded", "false");
      trigger.innerHTML =
        '<span class="date-range-trigger-icon" aria-hidden="true">' +
        '<svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6">' +
        '<rect x="3" y="4" width="14" height="13" rx="2"></rect>' +
        '<path d="M3 8h14M7 2.5v3M13 2.5v3" stroke-linecap="round"></path></svg></span>' +
        '<span class="date-range-trigger-label"></span>';

      var popover = document.createElement("div");
      popover.className = "date-range-popover";
      popover.setAttribute("role", "dialog");
      popover.hidden = true;

      root.appendChild(trigger);
      root.appendChild(popover);

      var presets = [
        { key: "today", label: "Today", range: function () { var t = startOfDay(new Date()); return [t, t]; } },
        { key: "yesterday", label: "Yesterday", range: function () { var y = addDays(new Date(), -1); return [y, y]; } },
        { key: "last7", label: "Last 7 days", range: function () { var t = startOfDay(new Date()); return [addDays(t, -6), t]; } },
        { key: "last30", label: "Last 30 days", range: function () { var t = startOfDay(new Date()); return [addDays(t, -29), t]; } },
        { key: "thisMonth", label: "This month", range: function () { var n = new Date(); return [new Date(n.getFullYear(), n.getMonth(), 1), startOfDay(n)]; } },
        { key: "lastMonth", label: "Last month", range: function () { var n = new Date(); return [new Date(n.getFullYear(), n.getMonth() - 1, 1), new Date(n.getFullYear(), n.getMonth(), 0)]; } },
        { key: "thisYear", label: "This year", range: function () { var n = new Date(); return [new Date(n.getFullYear(), 0, 1), startOfDay(n)]; } }
      ];

      function updateTrigger() {
        var label = trigger.querySelector(".date-range-trigger-label");
        if (state.from && state.to) {
          label.textContent = sameDay(state.from, state.to)
            ? formatLabel(state.from)
            : formatLabel(state.from) + " – " + formatLabel(state.to);
          trigger.classList.add("has-value");
        } else if (state.from) {
          label.textContent = "From " + formatLabel(state.from);
          trigger.classList.add("has-value");
        } else if (state.to) {
          label.textContent = "Until " + formatLabel(state.to);
          trigger.classList.add("has-value");
        } else {
          label.textContent = "All dates";
          trigger.classList.remove("has-value");
        }
      }

      function syncInputs() {
        fromInput.value = state.from ? formatDate(state.from) : "";
        toInput.value = state.to ? formatDate(state.to) : "";
      }

      // Push current selection into the hidden inputs and refresh the trigger label.
      function commit() {
        syncInputs();
        updateTrigger();
      }

      function buildMonth(base) {
        var year = base.getFullYear();
        var month = base.getMonth();
        var wrap = document.createElement("div");
        wrap.className = "date-range-cal";

        var head = document.createElement("div");
        head.className = "date-range-cal-head";
        var title = document.createElement("span");
        title.className = "date-range-cal-title";
        title.textContent = MONTHS[month] + " " + year;
        head.appendChild(title);
        wrap.appendChild(head);

        var grid = document.createElement("div");
        grid.className = "date-range-grid";
        WEEKDAYS.forEach(function (day) {
          var cell = document.createElement("span");
          cell.className = "date-range-weekday";
          cell.textContent = day;
          grid.appendChild(cell);
        });

        var firstDay = new Date(year, month, 1);
        // Monday-first column offset.
        var lead = (firstDay.getDay() + 6) % 7;
        var daysInMonth = new Date(year, month + 1, 0).getDate();
        var today = startOfDay(new Date());

        for (var i = 0; i < lead; i++) {
          var blank = document.createElement("span");
          blank.className = "date-range-day is-empty";
          grid.appendChild(blank);
        }

        for (var d = 1; d <= daysInMonth; d++) {
          var current = new Date(year, month, d);
          var btn = document.createElement("button");
          btn.type = "button";
          btn.className = "date-range-day";
          btn.textContent = String(d);
          btn.dataset.date = formatDate(current);

          if (sameDay(current, today)) btn.classList.add("is-today");
          if (sameDay(current, state.from)) btn.classList.add("is-start");
          if (sameDay(current, state.to)) btn.classList.add("is-end");
          if (state.from && state.to && current > state.from && current < state.to) {
            btn.classList.add("is-in-range");
          }
          grid.appendChild(btn);
        }

        wrap.appendChild(grid);
        return wrap;
      }

      function renderCalendars() {
        var body = popover.querySelector(".date-range-calendars");
        body.innerHTML = "";
        var second = new Date(state.view.getFullYear(), state.view.getMonth() + 1, 1);
        body.appendChild(buildMonth(state.view));
        body.appendChild(buildMonth(second));
      }

      function renderPresets() {
        presets.forEach(function (preset) {
          var btn = popover.querySelector('[data-preset="' + preset.key + '"]');
          if (!btn) return;
          var range = preset.range();
          btn.classList.toggle("is-active",
            sameDay(state.from, range[0]) && sameDay(state.to, range[1]));
        });
      }

      function render() {
        renderCalendars();
        renderPresets();
      }

      var presetHtml = presets.map(function (preset) {
        return '<button type="button" class="date-range-preset" data-preset="' +
          preset.key + '">' + preset.label + "</button>";
      }).join("");

      popover.innerHTML =
        '<div class="date-range-presets">' + presetHtml + "</div>" +
        '<div class="date-range-main">' +
        '<div class="date-range-nav">' +
        '<button type="button" class="date-range-nav-btn" data-nav="prev" aria-label="Previous month">‹</button>' +
        '<button type="button" class="date-range-nav-btn" data-nav="next" aria-label="Next month">›</button>' +
        "</div>" +
        '<div class="date-range-calendars"></div>' +
        "</div>";

      render();

      function open() {
        popover.hidden = false;
        trigger.setAttribute("aria-expanded", "true");
        render();
        document.addEventListener("click", onOutside, true);
        document.addEventListener("keydown", onKeydown);
      }

      function close() {
        popover.hidden = true;
        trigger.setAttribute("aria-expanded", "false");
        document.removeEventListener("click", onOutside, true);
        document.removeEventListener("keydown", onKeydown);
      }

      function onOutside(event) {
        if (!root.contains(event.target)) close();
      }

      function onKeydown(event) {
        if (event.key === "Escape") close();
      }

      trigger.addEventListener("click", function () {
        if (popover.hidden) open();
        else close();
      });

      popover.addEventListener("click", function (event) {
        var nav = event.target.closest("[data-nav]");
        if (nav) {
          var delta = nav.dataset.nav === "prev" ? -1 : 1;
          state.view = new Date(state.view.getFullYear(), state.view.getMonth() + delta, 1);
          render();
          return;
        }

        var preset = event.target.closest("[data-preset]");
        if (preset) {
          var match = presets.filter(function (item) { return item.key === preset.dataset.preset; })[0];
          if (match) {
            var range = match.range();
            state.from = range[0];
            state.to = range[1];
            state.view = startOfDay(state.from);
            state.view.setDate(1);
            commit();
            // A preset always yields a full range, so close immediately.
            close();
          }
          return;
        }

        var day = event.target.closest(".date-range-day");
        if (day && !day.classList.contains("is-empty")) {
          var picked = parseDate(day.dataset.date);
          if (!state.from || state.to || picked < state.from) {
            // Begin a new range.
            state.from = picked;
            state.to = null;
            commit();
            render();
          } else {
            // Complete the range, then close.
            state.to = picked;
            commit();
            close();
          }
          return;
        }
      });

      updateTrigger();
    }

    var roots = document.querySelectorAll("[data-date-range]");
    Array.prototype.forEach.call(roots, setupOne);
  }

  // Collapsible sidebar (icon rail). State persists in localStorage; the
  // initial class is applied by an inline <head> script to avoid a flash.
  function bootNavRail() {
    var KEY = "si-nav-rail";
    var toggle = $('[data-action="toggle-nav-rail"]');

    function syncToggle() {
      if (!toggle) return;
      var railed = document.documentElement.classList.contains("nav-rail");
      toggle.setAttribute("aria-expanded", railed ? "false" : "true");
      toggle.setAttribute("title", railed ? "Expand sidebar" : "Collapse sidebar");
    }

    syncToggle();

    document.addEventListener("click", function (event) {
      if (!event.target.closest('[data-action="toggle-nav-rail"]')) return;
      var railed = document.documentElement.classList.toggle("nav-rail");
      try {
        localStorage.setItem(KEY, railed ? "1" : "0");
      } catch (_error) {
        // Ignore storage failures (private mode, etc.).
      }
      syncToggle();
    });
  }

  bootSyncPolling();
  bootOnboardingSync();
  bootInvoicePreview();
  bootDateRangePicker();
  bootNavRail();
})();
