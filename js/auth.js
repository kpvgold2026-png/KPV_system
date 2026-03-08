function mapRole(sheetRole) {
  if (sheetRole === 'Sales') return 'User';
  return sheetRole;
}

function setupManagerUI() {
  var managerHideButtons = ['addSellBtn', 'addTradeinBtn', 'addBuybackBtn', 'addExchangeBtn', 'addSwitchBtn', 'addFreeExchangeBtn', 'addWithdrawBtn', 'withdrawBtn'];
  managerHideButtons.forEach(function(id) {
    var el = document.getElementById(id);
    if (el) el.style.display = 'none';
  });
  if (currentUser && currentUser.role === 'Manager') {
    ['stockInNewBtn', 'transferOldBtn', 'stockOutOldBtn'].forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
  }
  var hideSections = ["'sell'", "'tradein'", "'exchange'", "'switch'", "'freeexchange'", "'withdraw'"];
  document.querySelectorAll('.nav-btn').forEach(function(btn) {
    var oc = (btn.getAttribute('onclick') || '') + '';
    for (var i = 0; i < hideSections.length; i++) {
      if (oc.indexOf(hideSections[i]) !== -1) {
        btn.style.display = 'none';
        break;
      }
    }
    if (oc.indexOf("'buyback'") !== -1) btn.textContent = '◑ History Buyback';
  });
  var hBtn = document.getElementById('navHistorySell');
  if (hBtn) hBtn.style.display = '';
  var bbTitle = document.getElementById('buybackTitle');
  if (bbTitle) bbTitle.textContent = 'History Buyback';

  ['buybackDateFrom', 'buybackDateTo', 'historySellDateFrom', 'historySellDateTo'].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) el.style.display = 'none';
  });
  document.querySelectorAll('#buyback .date-filter, #historysell .date-filter').forEach(function(el) {
    el.style.display = 'none';
  });
  var hsFilters = document.querySelector('.historysell-filters');
  if (hsFilters) hsFilters.style.display = 'none';

  if (currentUser && currentUser.role === 'Manager') {
    ['addCashBankBtn', 'addOtherDepositBtn', 'addOtherIncomeBtn'].forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
    document.querySelectorAll('#cashbank .btn-primary, #cashbank .btn-secondary').forEach(function(btn) {
      var txt = (btn.textContent || '').trim();
      if (txt.indexOf('Cash') >= 0 || txt.indexOf('Bank') >= 0 || txt.indexOf('Deposit') >= 0 || txt.indexOf('Income') >= 0 || txt.indexOf('Expense') >= 0) {
        btn.style.display = 'none';
      }
    });
  }
}

var _inactivityTimer = null;
var INACTIVITY_LIMIT = 60 * 60 * 1000;

function resetInactivityTimer() {
  localStorage.setItem('lastActivity', Date.now());
  if (_inactivityTimer) clearTimeout(_inactivityTimer);
  _inactivityTimer = setTimeout(function() {
    if (currentUser) {
      alert('⏰ ไม่มีการใช้งาน 1 ชั่วโมง — ออกจากระบบอัตโนมัติ');
      logout();
    }
  }, INACTIVITY_LIMIT);
}

function startInactivityWatch() {
  ['click', 'keydown', 'mousemove', 'touchstart', 'scroll'].forEach(function(evt) {
    document.addEventListener(evt, resetInactivityTimer, { passive: true });
  });
  resetInactivityTimer();
}

function stopInactivityWatch() {
  ['click', 'keydown', 'mousemove', 'touchstart', 'scroll'].forEach(function(evt) {
    document.removeEventListener(evt, resetInactivityTimer);
  });
  if (_inactivityTimer) { clearTimeout(_inactivityTimer); _inactivityTimer = null; }
}

function isSessionExpired() {
  var last = parseInt(localStorage.getItem('lastActivity')) || 0;
  return (Date.now() - last) > INACTIVITY_LIMIT;
}

async function fetchUsersFromSheet() {
  try {
    var data = await fetchSheetData('_database!A33:D100');
    USERS = {};
    if (data.length > 1) {
      for (var i = 1; i < data.length; i++) {
        var role = String(data[i][0] || '').trim();
        var name = String(data[i][1] || '').trim();
        var username = String(data[i][2] || '').trim();
        var pass = String(data[i][3] || '').trim();
        if (username && pass && role) {
          USERS[username] = { password: pass, role: mapRole(role), nickname: name || role, sheetRole: role };
        }
      }
    }
    return true;
  } catch(e) {
    console.error('Error fetching users:', e);
    return false;
  }
}

function applyRoleUI() {
  if (currentUser.role === 'Admin') {
    var navUS = document.getElementById('navUserSetting');
    if (navUS) navUS.style.display = '';
  }

  if (currentUser.role === 'Accountant') {
    document.body.classList.add('accountant-readonly');
    var readonlyBtns = ['quickSales', 'quickTradein', 'quickBuyback', 'addSellBtn', 'addTradeinBtn', 'addBuybackBtn', 'addExchangeBtn', 'addSwitchBtn', 'addFreeExchangeBtn', 'withdrawBtn'];
    readonlyBtns.forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
  }

  if (currentUser.role === 'User') {
    document.querySelectorAll('.date-filter').forEach(function(el) { el.style.display = 'none'; });
    var allowedTabs = ['sell', 'trade-in', 'exchange', 'buyback', 'withdraw'];
    document.querySelectorAll('.nav-btn').forEach(function(btn) {
      var text = btn.textContent.toLowerCase();
      var isAllowed = false;
      allowedTabs.forEach(function(tab) {
        if (text.indexOf(tab) !== -1) isAllowed = true;
      });
      if (!isAllowed) btn.style.display = 'none';
    });
  }

  if (isManager()) { setupManagerUI(); }
}

async function enterApp() {
  document.getElementById('loginScreen').classList.remove('active');
  document.getElementById('mainHeader').style.display = 'block';
  document.getElementById('mainContainer').style.display = 'block';
  document.getElementById('userName').textContent = currentUser.nickname || currentUser.role;
  document.getElementById('userRole').textContent = currentUser.role;
  document.getElementById('userAvatar').textContent = (currentUser.nickname || currentUser.role)[0];
  document.body.className = 'role-' + currentUser.username;

  applyRoleUI();

  await batchFetchAll();
  await fetchExchangeRates();
  if (typeof checkAndResumePendingClose === 'function') checkAndResumePendingClose();
  callAppsScript('INIT_STOCK').catch(function(){});
  startNotificationPolling();
  startInactivityWatch();
}

async function login() {
  var username = document.getElementById('loginUsername').value.trim();
  var password = document.getElementById('loginPassword').value;

  if (!username || !password) {
    alert('กรุณากรอก Username และ Password');
    return;
  }

  showLoading();
  await fetchUsersFromSheet();
  hideLoading();

  if (USERS[username] && USERS[username].password === password) {
    currentUser = { username: username, password: USERS[username].password, role: USERS[username].role, nickname: USERS[username].nickname, sheetRole: USERS[username].sheetRole };
    localStorage.setItem('currentUser', JSON.stringify(currentUser));

    await enterApp();

    if (currentUser.role === 'User') {
      showSection('sell');
      checkOpenShift();
    } else {
      loadDashboard();
    }
  } else {
    alert('Invalid username or password');
  }
}

async function checkOpenShift() {
  if (!currentUser || currentUser.role !== 'User') return;
  try {
    var closeData = await fetchSheetData('Close!A:I');
    if (closeData && closeData.length > 1) {
      var today = getTodayLocalStr();
      for (var ci = 1; ci < closeData.length; ci++) {
        var closeUser = String(closeData[ci][1] || '').trim();
        var status = String(closeData[ci][8] || '').trim();
        if (closeUser !== currentUser.nickname) continue;
        if (status !== 'PENDING' && status !== 'APPROVED' && status !== 'COMPLETED') continue;
        var rawDate = closeData[ci][2];
        var closeDate = '';
        try {
          var d = new Date(rawDate);
          var local = new Date(d.getTime() + 7 * 60 * 60000);
          closeDate = local.toISOString().split('T')[0];
        } catch(e2) {}
        if (closeDate === today) {
          return;
        }
      }
    }

    var sheetName = currentUser.nickname;
    var data = await fetchSheetData(sheetName + '!A2:A2');
    if (!data || data.length === 0 || !data[0] || !data[0][0] || String(data[0][0]).trim() === '') {
      document.getElementById('openShiftAmount').value = '';
      _shiftCompleted = false;
      openModal('openShiftModal');
    }
  } catch(e) {
    document.getElementById('openShiftAmount').value = '';
    _shiftCompleted = false;
    openModal('openShiftModal');
  }
}

async function confirmOpenShift() {
  var amount = parseInt(document.getElementById('openShiftAmount').value.replace(/,/g, '')) || 0;
  if (amount <= 0) {
    alert('กรุณากรอกจำนวนเงิน');
    return;
  }
  if (!confirm('ยืนยันเปิดกะด้วยเงิน ' + formatNumber(amount) + ' LAK ?')) return;
  try {
    showLoading();
    var result = await callAppsScript('OPEN_SHIFT', {
      user: currentUser.nickname,
      amount: amount
    });
    if (result.success) {
      showToast('✅ เปิดกะสำเร็จ');
      _shiftCompleted = true;
      closeModal('openShiftModal');
    } else {
      alert('❌ ' + result.message);
    }
    hideLoading();
  } catch(e) {
    alert('❌ ' + e.message);
    hideLoading();
  }
}

function logout() {
  stopInactivityWatch();
  stopNotificationPolling();
  currentUser = null;

  localStorage.removeItem('currentUser');
  localStorage.removeItem('lastActivity');

  document.getElementById('loginScreen').classList.add('active');
  document.getElementById('mainHeader').style.display = 'none';
  document.getElementById('mainContainer').style.display = 'none';
  document.getElementById('loginUsername').value = '';
  document.getElementById('loginPassword').value = '';
  document.body.className = '';

  localStorage.setItem('cacheBuster', Date.now());

  setTimeout(function() {
    window.location.reload();
  }, 100);
}

(async function checkSession() {
  var savedUser = localStorage.getItem('currentUser');
  if (!savedUser) return;

  if (isSessionExpired()) {
    localStorage.removeItem('currentUser');
    localStorage.removeItem('lastActivity');
    return;
  }

  try {
    currentUser = JSON.parse(savedUser);

    await enterApp();

    if (currentUser.role === 'User') {
      showSection('sell');
      checkOpenShift();
    } else {
      loadDashboard();
    }
  } catch (error) {
    console.error('Session restore error:', error);
    localStorage.removeItem('currentUser');
    localStorage.removeItem('lastActivity');
  }
})();