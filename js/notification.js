var _notifInterval = null;
var _notifData = [];
var _notifDropdownOpen = false;
var _markedReadIds = {};
var _notifRealtimeChannel = null;

function startNotificationPolling() {
  if (_notifInterval) clearInterval(_notifInterval);
  pollAll();
  _notifInterval = setInterval(pollAll, 30000);
  startRealtimeNotifications();
}

function stopNotificationPolling() {
  if (_notifInterval) { clearInterval(_notifInterval); _notifInterval = null; }
  stopRealtimeNotifications();
}

function startRealtimeNotifications() {
  stopRealtimeNotifications();
  if (!currentUser || !currentUser.id) return;
  try {
    _notifRealtimeChannel = sb.channel('notif:' + currentUser.id)
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'notifications',
        filter: 'target_user_id=eq.' + currentUser.id
      }, function(payload) { _handleRealtimeNotif(payload && payload.new); })
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'notifications',
        filter: 'target_role=eq.' + (currentUser.dbRole || currentUser.role || '')
      }, function(payload) { _handleRealtimeNotif(payload && payload.new); })
      .subscribe();
  } catch(e) {}
}

function stopRealtimeNotifications() {
  if (_notifRealtimeChannel) {
    try { sb.removeChannel(_notifRealtimeChannel); } catch(e) {}
    _notifRealtimeChannel = null;
  }
}

function _handleRealtimeNotif(n) {
  if (!n) return;
  // กันกรณีของตัวเอง (Manager approve tx ของ Manager เอง — ไม่ควรเด้ง)
  if (n.created_by_id && currentUser && n.created_by_id === currentUser.id) return;
  // เด้ง toast
  if (typeof showToast === 'function') {
    var msg = (n.message || 'New notification');
    if (msg.length > 80) msg = msg.substring(0, 77) + '...';
    showToast('🔔 ' + msg, 4000);
  }
  // refresh dropdown badge ทันที (poll RPC สั้น ๆ)
  pollNotifications();
}

async function pollAll() {
  await batchFetchAll();
  await fetchExchangeRates();
  await fetchCurrentPricing();
  await pollNotifications();
  if (typeof checkPendingClose === 'function') checkPendingClose();
  if (typeof loadPendingTransferCount === 'function') loadPendingTransferCount();
  if (typeof loadSalesInfoBar === 'function') loadSalesInfoBar();
}

async function pollNotifications() {
  try {
    var data = await dbRpc('get_notifications', {});
    if (!Array.isArray(data) || data.length === 0) {
      _notifData = [];
      updateNotifBadge();
      return;
    }

    var filtered = data.map(function(n) {
      var tab = n.tab || '';
      if (isManager()) {
        if (tab !== 'buyback') tab = 'historysell';
      }
      return {
        id: n.id,
        type: n.type,
        message: n.message,
        tab: tab,
        createdAt: n.created_at,
        read: !!n.read || !!_markedReadIds[n.id],
        isTx: !!n.ref_tx_id,
        txId: n.ref_tx_id || null
      };
    });

    if (filtered.length > 0) {
      var txIds = filtered.filter(function(n) { return n.txId; }).map(function(n) { return n.txId; });
      if (txIds.length > 0) {
        try {
          var completedRows = await dbSelect('transactions', {
            select: 'id,status',
            filters: { id: 'in.(' + txIds.join(',') + ')' },
            useCache: false
          });
          var statusMap = {};
          (completedRows || []).forEach(function(t) { statusMap[t.id] = t.status; });
          filtered = filtered.filter(function(n) {
            if (!n.txId) return true;
            var status = statusMap[n.txId];
            if (!status) return false;
            if (status === 'COMPLETED' || status === 'REJECTED') return false;
            return true;
          });
        } catch(e) {}
      }
    }

    _notifData = filtered;
    updateNotifBadge();
  } catch(e) {}
}

function updateNotifBadge() {
  var badge = document.getElementById('notifBadge');
  if (!badge) return;
  var count = _notifData.filter(function(n) {
    if (n.isTx) return true;
    return !n.read;
  }).length;
  if (count > 0) {
    badge.textContent = count > 99 ? '99+' : count;
    badge.style.display = 'flex';
  } else {
    badge.style.display = 'none';
  }
}

function toggleNotifDropdown() {
  var dropdown = document.getElementById('notifDropdown');
  if (!dropdown) return;
  _notifDropdownOpen = !_notifDropdownOpen;
  dropdown.style.display = _notifDropdownOpen ? 'block' : 'none';
  if (_notifDropdownOpen) {
    renderNotifList();
    markAllRead();
  }
}

function renderNotifList() {
  var list = document.getElementById('notifList');
  if (!list) return;
  if (_notifData.length === 0) {
    list.innerHTML = '<div style="padding:15px;text-align:center;color:var(--text-secondary);">ไม่มีการแจ้งเตือน</div>';
    return;
  }
  list.innerHTML = _notifData.slice(0, 30).map(function(n) {
    var icon = '📌';
    if (n.type === 'APPROVAL') icon = '🆕';
    else if (n.type === 'PAYMENT') icon = '💰';
    else if (n.type === 'INFO') icon = 'ℹ️';
    else if (n.type === 'WARNING') icon = '⚠️';
    else if (n.type === 'CLOSE') icon = '🔒';
    else if (n.type === 'TRANSFER') icon = '🔄';
    else if (n.type === 'STOCK') icon = '📦';

    var time = '';
    try { time = formatDateTime(n.createdAt); } catch(e) {}
    var bg = n.read ? 'transparent' : 'rgba(212,175,55,0.08)';

    return '<div onclick="goToNotifTab(\'' + n.tab + '\')" style="padding:10px 15px;border-bottom:1px solid var(--border-color);cursor:pointer;background:' + bg + ';">' +
      '<div style="font-size:13px;">' + icon + ' ' + n.message + '</div>' +
      '<div style="font-size:11px;color:var(--text-secondary);margin-top:3px;">' + time + '</div>' +
      '</div>';
  }).join('');
}

function goToNotifTab(tab) {
  if (tab) showSection(tab);
  _notifDropdownOpen = false;
  var dropdown = document.getElementById('notifDropdown');
  if (dropdown) dropdown.style.display = 'none';
}

async function markAllRead() {
  var unread = _notifData.filter(function(n) { return !n.read && !n.isTx; });
  if (unread.length === 0) return;
  unread.forEach(function(n) {
    n.read = true;
    _markedReadIds[n.id] = true;
  });
  updateNotifBadge();
  try {
    await dbRpc('mark_notifications_read', {});
  } catch(e) {}
}

async function refreshPage() {
  var btn = document.getElementById('refreshBtn');
  var icon = document.getElementById('refreshIcon');
  if (icon) icon.style.animation = 'spin 0.8s linear infinite';
  if (btn) btn.style.pointerEvents = 'none';

  var activeTab = document.querySelector('.nav-btn.active');
  var tabName = 'dashboard';
  if (activeTab) {
    var onclick = activeTab.getAttribute('onclick');
    var match = onclick.match(/showSection\('(.+?)'\)/);
    if (match) tabName = match[1];
  }

  try {
    invalidateCache();
    await batchFetchAll();
    await fetchExchangeRates();
    await fetchCurrentPricing();
    if (typeof loadSalesInfoBar === 'function') loadSalesInfoBar();
    await showSection(tabName);
    await pollAll();
  } catch(e) {}

  if (icon) icon.style.animation = '';
  if (btn) btn.style.pointerEvents = '';
}

document.addEventListener('click', function(e) {
  var bell = document.getElementById('notifBell');
  var dropdown = document.getElementById('notifDropdown');
  if (bell && dropdown && !bell.contains(e.target) && !dropdown.contains(e.target)) {
    _notifDropdownOpen = false;
    dropdown.style.display = 'none';
  }
});
