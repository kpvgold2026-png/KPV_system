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

  if (currentUser && currentUser.role === 'Manager') {
    ['buybackDateFrom', 'buybackDateTo', 'historySellDateFrom', 'historySellDateTo'].forEach(function(id) {
      var el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
    document.querySelectorAll('#buyback .date-filter, #historysell .date-filter').forEach(function(el) {
      el.style.display = 'none';
    });
    var hsFilters = document.querySelector('.historysell-filters');
    if (hsFilters) hsFilters.style.display = 'none';

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

    var managerHideTabs = ["'accounting'", "'diff'", "'reports'", "'wac'"];
    document.querySelectorAll('.nav-btn').forEach(function(btn) {
      var oc = (btn.getAttribute('onclick') || '') + '';
      for (var i = 0; i < managerHideTabs.length; i++) {
        if (oc.indexOf(managerHideTabs[i]) !== -1) {
          btn.style.display = 'none';
          break;
        }
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
    var users = await sbSelect('users', { eq: [['active', true]] });
    USERS = {};
    for (var i = 0; i < users.length; i++) {
      var u = users[i];
      var role = mapRole(u.role);
      USERS[u.username] = {
        password: u.password,
        role: role,
        nickname: u.nickname || u.role,
        sheetRole: u.role
      };
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
    var navDL = document.getElementById('navDeletedList');
    if (navDL) navDL.style.display = '';
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
  await fetchCurrentPricing();
  if (typeof checkAndResumePendingClose === 'function') checkAndResumePendingClose();
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
    var today = getTodayLocalStr();
    var userName = currentUser.nickname;

    var closeRows = await sbSelect('close_shifts', {
      eq: [['username', userName]],
      order: ['date', 'desc'],
      limit: 10
    });

    for (var ci = 0; ci < closeRows.length; ci++) {
      var status = closeRows[ci].status;
      if (status !== 'PENDING' && status !== 'APPROVED' && status !== 'COMPLETED') continue;
      var closeDate = closeRows[ci].date ? closeRows[ci].date.split('T')[0] : '';
      if (closeDate === today) return;
    }

    var openShifts = await sbSelect('open_shifts', {
      eq: [['username', userName], ['status', 'OPEN']],
      order: ['date', 'desc'],
      limit: 1
    });

    if (openShifts.length === 0) {
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
