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
  if (!currentUser || !currentUser.id) {
    console.log('[realtime-notif] skip: no currentUser');
    return;
  }
  var role = currentUser.dbRole || currentUser.role || '';
  console.log('[realtime-notif] subscribing for user=' + currentUser.id + ' role=' + role);
  try {
    // ไม่ใช้ filter — ให้ RLS กรองเอง
    // (filter ของ Realtime เป็น exact match ไม่รองรับ "Admin เห็น Manager noti")
    _notifRealtimeChannel = sb.channel('notif:' + currentUser.id)
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'notifications'
      }, function(payload) {
        var n = payload && payload.new;
        if (!n) return;
        console.log('[realtime-notif] received:', n);
        // RLS ทำงานฝั่ง server แล้ว แต่กันพลาด: เช็คอีกชั้นฝั่ง client
        if (n.created_by_id === currentUser.id) return; // ของตัวเอง — skip
        _handleRealtimeNotif(n);
      })
      .subscribe(function(status, err) {
        console.log('[realtime-notif] status=' + status, err || '');
      });
  } catch(e) {
    console.error('[realtime-notif] subscribe error:', e);
  }
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
      } else {
        // Sales: ไม่มี History Sell tab — map tab=historysell → tab ของ tx type ตาม ref_tx_id prefix
        if (tab === 'historysell' && n.ref_tx_id) {
          var prefix = String(n.ref_tx_id).substring(0, 2).toUpperCase();
          var prefixMap = { 'SE': 'sell', 'TI': 'tradein', 'EX': 'exchange', 'BB': 'buyback', 'WD': 'withdraw' };
          if (prefixMap[prefix]) tab = prefixMap[prefix];
        }
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
            // BILL_DUP: keep ค้างไว้จนกว่าจะกดอ่าน (ไม่ผูกกับ tx status)
            if (n.type === 'BILL_DUP') return true;
            var status = statusMap[n.txId];
            if (!status) return false;
            // Sales-targeted (INFO/PAYMENT to user): แสดงจนกว่า tx COMPLETED/REJECTED
            if (n.type === 'INFO') {
              return !(status === 'COMPLETED' || status === 'REJECTED');
            }
            // Admin/Manager action items (APPROVAL/PAYMENT/CLOSE):
            // ซ่อนทันทีที่มี action (APPROVED/COMPLETED/REJECTED)
            return !(status === 'APPROVED' || status === 'COMPLETED' || status === 'REJECTED');
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
    else if (n.type === 'BILL_DUP') icon = '🔁';

    var time = '';
    try { time = formatDateTime(n.createdAt); } catch(e) {}
    var bg = n.read ? 'transparent' : 'rgba(212,175,55,0.08)';

    var clickAttr;
    if (n.type === 'BILL_DUP') {
      var billId = '';
      var m = (n.message || '').match(/Bill ID ซ้ำ:\s*([^\s\(]+)/);
      if (m) billId = m[1];
      clickAttr = 'onclick="showBillDupPopup(\'' + billId.replace(/'/g, "\\'") + '\')"';
    } else {
      clickAttr = 'onclick="goToNotifTab(\'' + n.tab + '\')"';
    }

    return '<div ' + clickAttr + ' style="padding:10px 15px;border-bottom:1px solid var(--border-color);cursor:pointer;background:' + bg + ';">' +
      '<div style="font-size:13px;">' + icon + ' ' + n.message + '</div>' +
      '<div style="font-size:11px;color:var(--text-secondary);margin-top:3px;">' + time + '</div>' +
      '</div>';
  }).join('');
}

async function showBillDupPopup(billId) {
  if (!billId) { alert('ไม่พบ Bill ID'); return; }
  var dropdown = document.getElementById('notifDropdown');
  if (dropdown) { dropdown.style.display = 'none'; _notifDropdownOpen = false; }

  try {
    showLoading();
    var data = await dbRpc('get_bill_dup_detail', { p_bill_id: billId });
    hideLoading();
    var txs = (data && data.txs) || [];

    var html = '<div style="padding:20px;">';
    html += '<h3 style="color:#f44336;margin-bottom:10px;">🔁 Bill ID ซ้ำ: ' + billId + '</h3>';
    html += '<p style="font-size:13px;color:var(--text-secondary);margin-bottom:15px;">พบ ' + txs.length + ' รายการที่ใช้ Bill ID เดียวกัน</p>';

    if (txs.length === 0) {
      html += '<p>ไม่พบข้อมูล</p>';
    } else {
      html += '<table style="width:100%;border-collapse:collapse;">';
      html += '<thead><tr style="background:rgba(212,175,55,0.1);">' +
        '<th style="padding:8px;text-align:left;border-bottom:2px solid var(--gold-primary);">Tx ID</th>' +
        '<th style="padding:8px;text-align:left;border-bottom:2px solid var(--gold-primary);">ประเภท</th>' +
        '<th style="padding:8px;text-align:left;border-bottom:2px solid var(--gold-primary);">Sales</th>' +
        '<th style="padding:8px;text-align:right;border-bottom:2px solid var(--gold-primary);">Total</th>' +
        '<th style="padding:8px;text-align:left;border-bottom:2px solid var(--gold-primary);">สถานะ</th>' +
        '<th style="padding:8px;text-align:left;border-bottom:2px solid var(--gold-primary);">วันที่</th>' +
        '</tr></thead><tbody>';
      txs.forEach(function(t) {
        html += '<tr style="border-bottom:1px solid var(--border-color);">' +
          '<td style="padding:8px;font-weight:bold;color:var(--gold-primary);">' + (t.id || '-') + '</td>' +
          '<td style="padding:8px;">' + (t.type || '-') + '</td>' +
          '<td style="padding:8px;">' + (t.sales_nickname || '-') + '</td>' +
          '<td style="padding:8px;text-align:right;">' + formatNumber(parseFloat(t.total) || 0) + ' LAK</td>' +
          '<td style="padding:8px;">' + (t.status || '-') + '</td>' +
          '<td style="padding:8px;font-size:11px;">' + formatDateTime(t.created_at) + '</td>' +
          '</tr>';
      });
      html += '</tbody></table>';
    }
    html += '</div>';

    var modal = document.getElementById('billDupModal');
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'billDupModal';
      modal.className = 'modal';
      modal.innerHTML = '<div class="modal-content" style="max-width:720px;"><div id="billDupContent"></div><div style="text-align:right;padding:0 20px 20px;"><button class="btn-secondary" onclick="closeModal(\'billDupModal\')">ปิด</button></div></div>';
      document.body.appendChild(modal);
    }
    document.getElementById('billDupContent').innerHTML = html;
    openModal('billDupModal');
  } catch(e) {
    hideLoading();
    alert('❌ โหลดข้อมูลไม่สำเร็จ: ' + e.message);
  }
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
