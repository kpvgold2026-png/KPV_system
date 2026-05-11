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
var _sessionCheckInterval = null;
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
  startSessionCheck();
}

function stopInactivityWatch() {
  ['click', 'keydown', 'mousemove', 'touchstart', 'scroll'].forEach(function(evt) {
    document.removeEventListener(evt, resetInactivityTimer);
  });
  if (_inactivityTimer) { clearTimeout(_inactivityTimer); _inactivityTimer = null; }
  stopSessionCheck();
}

function startSessionCheck() {
  if (_sessionCheckInterval) clearInterval(_sessionCheckInterval);
  _sessionCheckInterval = setInterval(checkSession, 10000);
  startRealtimeSessionWatch();
}

function stopSessionCheck() {
  if (_sessionCheckInterval) { clearInterval(_sessionCheckInterval); _sessionCheckInterval = null; }
  stopRealtimeSessionWatch();
}

var _realtimeWs = null;
var _realtimeHeartbeat = null;
var _realtimeRef = 0;

function startRealtimeSessionWatch() {
  stopRealtimeSessionWatch();
  if (!currentUser || !currentUser.token) return;

  var wsUrl = CONFIG.SUPABASE_URL.replace(/^https?:/, 'wss:') + '/realtime/v1/websocket?apikey=' + encodeURIComponent(CONFIG.SUPABASE_ANON_KEY) + '&vsn=1.0.0';

  try {
    _realtimeWs = new WebSocket(wsUrl);
  } catch(e) {
    return;
  }

  var topic = 'realtime:session:' + currentUser.id;

  _realtimeWs.onopen = function() {
    _realtimeWs.send(JSON.stringify({
      topic: topic,
      event: 'phx_join',
      payload: {
        config: {
          broadcast: { self: false, ack: false },
          presence: { key: '' }
        },
        access_token: currentUser.token
      },
      ref: String(++_realtimeRef)
    }));

    _realtimeHeartbeat = setInterval(function() {
      if (_realtimeWs && _realtimeWs.readyState === 1) {
        _realtimeWs.send(JSON.stringify({
          topic: 'phoenix',
          event: 'heartbeat',
          payload: {},
          ref: String(++_realtimeRef)
        }));
      }
    }, 25000);
  };

  _realtimeWs.onmessage = function(event) {
    try {
      var msg = JSON.parse(event.data);
      if (msg.event === 'broadcast' && msg.payload && msg.payload.event === 'kick') {
        var newSession = msg.payload.payload && msg.payload.payload.session;
        if (newSession && newSession !== currentUser.sessionId) {
          stopInactivityWatch();
          if (typeof stopNotificationPolling === 'function') stopNotificationPolling();
          alert('บัญชีนี้ถูกเข้าสู่ระบบที่อื่น คุณจะถูกออกจากระบบ');
          currentUser = null;
          localStorage.removeItem('currentUser');
          localStorage.removeItem('jwt');
          localStorage.removeItem('lastActivity');
          window.location.reload();
        }
      }
    } catch(e) {}
  };

  _realtimeWs.onerror = function() {};
  _realtimeWs.onclose = function() {
    if (_realtimeHeartbeat) { clearInterval(_realtimeHeartbeat); _realtimeHeartbeat = null; }
    _realtimeWs = null;
    if (currentUser) {
      setTimeout(function() {
        if (currentUser) startRealtimeSessionWatch();
      }, 5000);
    }
  };
}

async function broadcastKickOthers(sessionId) {
  try {
    await fetch(CONFIG.SUPABASE_URL + '/realtime/v1/api/broadcast', {
      method: 'POST',
      headers: {
        'apikey': CONFIG.SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + currentUser.token,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        messages: [{
          topic: 'session:' + currentUser.id,
          event: 'kick',
          payload: { session: sessionId },
          private: false
        }]
      })
    });
  } catch(e) {}
}

function stopRealtimeSessionWatch() {
  if (_realtimeHeartbeat) { clearInterval(_realtimeHeartbeat); _realtimeHeartbeat = null; }
  if (_realtimeWs) {
    try { _realtimeWs.close(); } catch(e) {}
    _realtimeWs = null;
  }
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
    var result = await dbRpc('get_my_session', {});
    var stored = result && result.session_token ? result.session_token : null;
    if (stored && stored !== currentUser.sessionId) {
      stopInactivityWatch();
      if (typeof stopNotificationPolling === 'function') stopNotificationPolling();
      alert('บัญชีนี้ถูกเข้าสู่ระบบที่อื่น คุณจะถูกออกจากระบบ');
      currentUser = null;
      localStorage.removeItem('currentUser');
      localStorage.removeItem('jwt');
      localStorage.removeItem('lastActivity');
      window.location.reload();
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
      alert('Invalid response from server');
      return;
    }

    var nickname = user.nickname || user.role || user.username || 'User';
    var dbRole = user.role || 'Sales';

    var sessionId = _b64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
    var role = mapRole(dbRole);
    var token = await jwtSign({
      user_id: user.id,
      role: 'authenticated',
      user_role: dbRole,
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
    localStorage.setItem('lastActivity', Date.now().toString());

    try {
      await broadcastKickOthers(sessionId);
    } catch(e) {}

    try {
      await dbRpc('set_my_session', { p_session: sessionId });
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
      localStorage.removeItem('lastActivity');
      return false;
    }
    currentUser = JSON.parse(saved);
    currentUser.token = token;
    return true;
  } catch(e) {
    return false;
  }
}

document.addEventListener('DOMContentLoaded', async function() {
  var ok = await restoreSession();
  if (!ok) return;
  try {
    var result = await dbRpc('get_my_session', {});
    var stored = result && result.session_token ? result.session_token : null;
    if (stored && currentUser.sessionId && stored !== currentUser.sessionId) {
      localStorage.removeItem('currentUser');
      localStorage.removeItem('jwt');
      localStorage.removeItem('lastActivity');
      currentUser = null;
      return;
    }
  } catch(e) {}

  await enterApp();
  if (currentUser.role === 'User') {
    showSection('sell');
    if (typeof checkOpenShift === 'function') checkOpenShift();
  } else {
    if (typeof loadDashboard === 'function') loadDashboard();
  }
});
