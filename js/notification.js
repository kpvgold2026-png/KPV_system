var _notifInterval = null;
var _notifData = [];
var _notifDropdownOpen = false;
var _markedReadIds = {};

function startNotificationPolling() {
  if (_notifInterval) clearInterval(_notifInterval);
  pollAll();
  _notifInterval = setInterval(pollAll, 60000);
}

function stopNotificationPolling() {
  if (_notifInterval) { clearInterval(_notifInterval); _notifInterval = null; }
}

async function pollAll() {
  await batchFetchAll();
  await pollNotifications();
  if (typeof checkPendingClose === 'function') checkPendingClose();
  if (typeof loadPendingTransferCount === 'function') loadPendingTransferCount();
}

async function pollNotifications() {
  try {
    var data = await fetchSheetData('_notifications!A:I');
    if (!data || data.length <= 1) {
      _notifData = [];
      updateNotifBadge();
      return;
    }

    var user = currentUser.nickname || currentUser.username;
    var username = currentUser.username;
    var nickname = currentUser.nickname || username;
    var role = currentUser.role;
    var filtered = [];

    for (var i = 1; i < data.length; i++) {
      var row = data[i];
      var targetRole = String(row[3] || '');
      var targetUser = String(row[4] || '').trim();
      var createdBy = String(row[6] || '').trim();
      var readBy = String(row[8] || '').trim();

      if (createdBy === nickname || createdBy === username) continue;

      var isTarget = false;
      if (targetUser && (targetUser === nickname || targetUser === username)) {
        isTarget = true;
      } else if (targetRole && targetRole.indexOf(role) >= 0 && !targetUser) {
        isTarget = true;
      }

      if (isTarget) {
        var readList = readBy.split(',').map(function(s) { return s.trim(); });
        var isRead = readList.indexOf(nickname) >= 0 || readList.indexOf(username) >= 0 || !!_markedReadIds[row[0]];
        var nType = String(row[1] || '');

        if (nType !== 'NEW_TX' && nType !== 'TX_APPROVED' && nType !== 'TX_REJECTED') continue;

        var isTx = true;
        var tab = String(row[5] || '');

        if (isManager()) {
          if (tab !== 'buyback') {
            tab = 'historysell';
          }
        }

        filtered.push({
          id: row[0],
          type: nType,
          message: row[2],
          tab: tab,
          createdAt: row[7],
          read: isRead,
          isTx: isTx
        });
      }
    }

    filtered.reverse();

    var txIds = [];
    filtered.forEach(function(n) {
      if (n.isTx) {
        var m = String(n.message).match(/(SE|TI|EX|BB|WD)\d{5}/);
        if (m) {
          n.txId = m[0];
          if (txIds.indexOf(m[0]) < 0) txIds.push(m[0]);
        }
      }
    });

    if (txIds.length > 0) {
      var completedIds = await getCompletedTxIds(txIds);
      filtered = filtered.filter(function(n) {
        if (n.txId && completedIds[n.txId]) return false;
        return true;
      });
    }

    _notifData = filtered;
    updateNotifBadge();
  } catch(e) {}
}

async function getCompletedTxIds(txIds) {
  var completed = {};
  var sheetsToCheck = {
    'SE': { sheet: 'Sells', statusCol: 10 },
    'TI': { sheet: 'Tradeins', statusCol: 12 },
    'EX': { sheet: 'Exchanges', statusCol: 12 },
    'BB': { sheet: 'Buybacks', statusCol: 10 },
    'WD': { sheet: 'Withdraws', statusCol: 7 }
  };

  var prefixes = {};
  txIds.forEach(function(id) {
    var p = id.replace(/\d+$/, '');
    if (!prefixes[p]) prefixes[p] = [];
    prefixes[p].push(id);
  });

  for (var prefix in prefixes) {
    var cfg = sheetsToCheck[prefix];
    if (!cfg) continue;
    try {
      var sheetData = await fetchSheetData(cfg.sheet + '!A:' + String.fromCharCode(65 + cfg.statusCol));
      if (!sheetData || sheetData.length <= 1) {
        prefixes[prefix].forEach(function(id) { completed[id] = true; });
        continue;
      }
      var foundIds = {};
      for (var i = 1; i < sheetData.length; i++) {
        var rowId = String(sheetData[i][0] || '');
        var status = String(sheetData[i][cfg.statusCol] || '');
        foundIds[rowId] = true;
        if (prefixes[prefix].indexOf(rowId) >= 0 && (status === 'COMPLETED' || status === 'REJECTED')) {
          completed[rowId] = true;
        }
      }
      prefixes[prefix].forEach(function(id) {
        if (!foundIds[id]) completed[id] = true;
      });
    } catch(e) {}
  }
  return completed;
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
    if (n.type === 'NEW_TX') icon = '🆕';
    else if (n.type === 'TX_APPROVED') icon = '✅';
    else if (n.type === 'TX_REJECTED') icon = '❌';

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
    await callAppsScript('MARK_NOTIFICATIONS_READ', { user: currentUser.nickname || currentUser.username });
  } catch(e) {}
}

async function refreshPage() {
  var btn = document.getElementById('refreshBtn');
  var icon = document.getElementById('refreshIcon');
  if (icon) {
    icon.style.animation = 'spin 0.8s linear infinite';
  }
  if (btn) {
    btn.style.pointerEvents = 'none';
  }

  var activeTab = document.querySelector('.nav-btn.active');
  var tabName = 'dashboard';
  if (activeTab) {
    var onclick = activeTab.getAttribute('onclick');
    var match = onclick.match(/showSection\('(.+?)'\)/);
    if (match) tabName = match[1];
  }

  try {
    _sheetCache = {};
    await batchFetchAll();
    await fetchExchangeRates();
    await fetchCurrentPricing();
    await showSection(tabName);
    await pollAll();
  } catch(e) {}

  if (icon) {
    icon.style.animation = '';
  }
  if (btn) {
    btn.style.pointerEvents = '';
  }
}

document.addEventListener('click', function(e) {
  var bell = document.getElementById('notifBell');
  var dropdown = document.getElementById('notifDropdown');
  if (bell && dropdown && !bell.contains(e.target) && !dropdown.contains(e.target)) {
    _notifDropdownOpen = false;
    dropdown.style.display = 'none';
  }
});
