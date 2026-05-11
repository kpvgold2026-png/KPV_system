function mapRole(dbRole) {
  if (dbRole === 'Sales') return 'User';
  return dbRole;
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
var INACTIVITY_LIMIT = (CONFIG.INACTIVITY_TIMEOUT_MINUTES || 60) * 60 * 1000;

function resetInactivityTimer() {
  localStorage.setItem('lastActivity', Date.now());
  if (_inactivityTimer) clearTimeout(_inactivityTimer);
  _inactivityTimer = setTimeout(function() {
    if (currentUser) {
      var mins = CONFIG.INACTIVITY_TIMEOUT_MINUTES || 60;
      var msg = mins >= 60 ? (mins / 60) + ' ชั่วโมง' : mins + ' นาที';
      alert('⏰ ไม่มีการใช้งาน ' + msg + ' — ออกจากระบบอัตโนมัติ');
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

async function fetchUsersFromDB() {
  try {
    var rows = await dbSelect('users', {
      select: 'id,role,nickname,username,is_active',
      filters: { is_active: 'eq.true' },
      useCache: false
    });
    USERS = {};
    if (rows) {
      rows.forEach(function(u) {
        USERS[u.username] = {
          id: u.id,
          role: mapRole(u.role),
          nickname: u.nickname || u.role,
          dbRole: u.role
        };
      });
    }
    return true;
  } catch(e) {
    console.error('Error fetching users:', e);
    return false;
  }
}

async function checkSession() {
  if (!currentUser || !currentUser.token) return;
  try {
    var payload = await jwtVerify(currentUser.token);
    if (!payload) {
      alert('Session หมดอายุ กรุณาเข้าสู่ระบบใหม่');
      logout();
      return;
    }
    var rows = await dbSelect('users', {
      select: 'id,session_token',
      filters: { id: 'eq.' + currentUser.id },
      useCache: false
    });
    if (rows && rows.length > 0) {
      var stored = rows[0].session_token;
      if (stored && stored !== currentUser.sessionId) {
        alert('บัญชีนี้ถูกเข้าสู่ระบบที่อื่น คุณจะถูกออกจากระบบ');
        logout();
      }
    }
  } catch(e) {}
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
  var displayName = currentUser.nickname || currentUser.role || currentUser.username || 'User';
  var avatarChar = (displayName && displayName.length > 0) ? displayName.charAt(0).toUpperCase() : 'U';
  document.getElementById('userName').textContent = displayName;
  document.getElementById('userRole').textContent = currentUser.role || '';
  document.getElementById('userAvatar').textContent = avatarChar;
  var roleClass = currentUser.role === 'Manager' ? 'role-m' : currentUser.role === 'Admin' ? 'role-a' : 'role-u';
  document.body.className = roleClass;

  applyRoleUI();

  await batchFetchAll();
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
  try {
    var result = await dbRpc('login_user', { p_username: username, p_password: password });
    console.log('[login] RPC result:', result);

    var user = Array.isArray(result) ? result[0] : result;
    if (!user) {
      hideLoading();
      alert('Invalid username or password (no response)');
      return;
    }

    if (user.success === false) {
      hideLoading();
      alert('Login failed: ' + (user.message || 'Unknown'));
      return;
    }

    if (!user.id) {
      hideLoading();
      console.error('[login] user object missing id:', user);
      alert('Invalid response from server');
      return;
    }

    var nickname = user.nickname || user.role || user.username || 'User';
    var dbRole = user.role || 'Sales';

    var sessionId = _b64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
    var role = mapRole(dbRole);
    var token = await jwtSign({
      user_id: user.id,
      role: dbRole,
      username: user.username,
      session: sessionId
    });

    currentUser = {
      id: user.id,
      username: user.username,
      role: role,
      nickname: nickname,
      dbRole: dbRole,
      token: token,
      sessionId: sessionId
    };

    localStorage.setItem('jwt', token);
    localStorage.setItem('currentUser', JSON.stringify(currentUser));

    try {
      await dbUpdate('users', { id: 'eq.' + user.id }, { session_token: sessionId });
    } catch(e) {}

    hideLoading();
    await enterApp();

    if (currentUser.role === 'User') {
      showSection('sell');
      checkOpenShift();
    } else {
      loadDashboard();
    }
  } catch(e) {
    hideLoading();
    console.error('Login error:', e);
    alert('Login failed: ' + (e.message || 'Unknown error'));
  }
}

async function checkOpenShift() {
  if (!currentUser || currentUser.role !== 'User') return;
  try {
    var today = getTodayLocalStr();
    var closes = await dbSelect('closes', {
      select: 'id,date,status',
      filters: { user_id: 'eq.' + currentUser.id },
      order: 'date.desc',
      limit: 5,
      useCache: false
    });
    if (closes && closes.length > 0) {
      for (var ci = 0; ci < closes.length; ci++) {
        var status = String(closes[ci].status || '').trim();
        if (status !== 'PENDING' && status !== 'APPROVED' && status !== 'COMPLETED') continue;
        var d = new Date(closes[ci].date);
        var local = new Date(d.getTime() + 7 * 60 * 60000);
        var closeDate = local.toISOString().split('T')[0];
        if (closeDate === today) return;
      }
    }

    var openShifts = await dbSelect('user_cashbook', {
      select: 'id,date',
      filters: {
        user_id: 'eq.' + currentUser.id,
        type: 'eq.OPEN_SHIFT',
        date: 'gte.' + today + 'T00:00:00'
      },
      limit: 1,
      useCache: false
    });

    if (!openShifts || openShifts.length === 0) {
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
    var result = await dbRpc('open_shift', {
      p_user_id: currentUser.id,
      p_amount: amount
    });
    hideLoading();
    if (result && (result.success || (Array.isArray(result) && result[0] && result[0].success))) {
      showToast('✅ เปิดกะสำเร็จ');
      closeModal('openShiftModal');
      _shiftCompleted = true;
    } else {
      alert('เปิดกะไม่สำเร็จ');
    }
  } catch(e) {
    hideLoading();
    alert('เปิดกะไม่สำเร็จ: ' + e.message);
  }
}

function logout() {
  stopInactivityWatch();
  if (typeof stopNotificationPolling === 'function') stopNotificationPolling();
  currentUser = null;

  localStorage.removeItem('currentUser');
  localStorage.removeItem('jwt');
  localStorage.removeItem('lastActivity');

  document.getElementById('loginScreen').classList.add('active');
  document.getElementById('mainHeader').style.display = 'none';
  document.getElementById('mainContainer').style.display = 'none';
  var lu = document.getElementById('loginUsername'); if (lu) lu.value = '';
  var lp = document.getElementById('loginPassword'); if (lp) lp.value = '';
  document.body.className = '';

  localStorage.setItem('cacheBuster', Date.now());

  setTimeout(function() {
    window.location.reload();
  }, 100);
}

function isManager() {
  return currentUser && (currentUser.role === 'Manager' || currentUser.role === 'Admin');
}

async function restoreSession() {
  var token = localStorage.getItem('jwt');
  var saved = localStorage.getItem('currentUser');
  if (!token || !saved) return false;
  try {
    var payload = await jwtVerify(token);
    if (!payload) {
      localStorage.removeItem('jwt');
      localStorage.removeItem('currentUser');
      return false;
    }
    if (isSessionExpired()) {
      localStorage.removeItem('jwt');
      localStorage.removeItem('currentUser');
      return false;
    }
    currentUser = JSON.parse(saved);
    currentUser.token = token;
    return true;
  } catch(e) {
    return false;
  }
}
