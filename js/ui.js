function showSection(sectionId) {
  document.querySelectorAll('.section').forEach(section => {
    section.classList.remove('active');
  });
  document.querySelectorAll('.nav-btn').forEach(btn => {
    btn.classList.remove('active');
  });

  const targetSection = document.getElementById(sectionId);
  if (targetSection) {
    targetSection.classList.add('active');
  }

  document.querySelectorAll('.nav-btn').forEach(btn => {
    var oc = btn.getAttribute('onclick') || '';
    if (oc.indexOf("'" + sectionId + "'") !== -1) {
      btn.classList.add('active');
    }
  });

  if (sectionId !== 'dashboard' && typeof stopDashReportRefresh === 'function') {
    stopDashReportRefresh();
  }

  const loaderMap = {
    'dashboard': 'loadDashboard',
    'products': 'loadProducts',
    'pricerate': 'loadPriceRate',
    'sell': 'loadSells',
    'tradein': 'loadTradeins',
    'exchange': 'loadExchanges',
    'buyback': 'loadBuybacks',
    'withdraw': 'loadWithdraws',
    'historysell': 'loadHistorySell',
    'cashbank': 'loadCashBank',
    'accounting': 'loadAccounting',
    'diff': 'loadDiff',
    'reports': 'loadReports',
    'stockold': 'loadStockOld',
    'stocknew': 'loadStockNew',
    'wac': 'loadWAC',
    'usersetting': 'loadUserSetting',
    'deletedlist': 'loadDeletedList'
  };
  const fn = loaderMap[sectionId];
  if (fn && typeof window[fn] === 'function') window[fn]();
}

function showToast(message, duration) {
  duration = duration || 3000;
  var existing = document.getElementById('toastNotification');
  if (existing) existing.remove();
  var toast = document.createElement('div');
  toast.id = 'toastNotification';
  toast.textContent = message;
  toast.style.cssText = 'position:fixed;top:20px;left:50%;transform:translateX(-50%);background:#4caf50;color:white;padding:14px 28px;border-radius:10px;font-size:15px;font-weight:600;z-index:99999;box-shadow:0 4px 20px rgba(0,0,0,0.4);opacity:1;transition:opacity 0.5s ease;pointer-events:none;';
  document.body.appendChild(toast);
  setTimeout(function() {
    toast.style.opacity = '0';
    setTimeout(function() { toast.remove(); }, 500);
  }, duration);
}

function initMoneyInputs() {
  document.querySelectorAll('input[type="number"]').forEach(function(input) {
    if (input.dataset.moneyBound) return;
    var ph = (input.placeholder || '').toLowerCase();
    var label = '';
    var parent = input.closest('.form-group');
    if (parent) {
      var lbl = parent.querySelector('.form-label');
      if (lbl) label = (lbl.textContent || '').toLowerCase();
    }
    if (input.step === '1000' || ph.includes('amount') || ph.includes('จำนวนเงิน') || label.includes('เงิน') || label.includes('amount') || label.includes('lak') || label.includes('thb') || label.includes('usd') || input.id === 'openShiftAmount') {
      convertToMoneyInput(input);
    }
  });
}

function convertToMoneyInput(input) {
  if (input.dataset.moneyBound) return;
  input.dataset.moneyBound = '1';
  var hiddenVal = input.value || '';
  input.type = 'text';
  input.inputMode = 'numeric';
  if (hiddenVal) input.value = formatMoneyInput(hiddenVal);

  input.addEventListener('input', function() {
    var raw = this.value.replace(/[^0-9.-]/g, '');
    var num = parseFloat(raw) || 0;
    var pos = this.selectionStart;
    var oldLen = this.value.length;
    this.value = raw ? formatMoneyInput(raw) : '';
    var newLen = this.value.length;
    var newPos = pos + (newLen - oldLen);
    this.setSelectionRange(newPos, newPos);
    this.dataset.rawValue = raw;
  });

  input.addEventListener('focus', function() {
    if (!this.dataset.rawValue) this.dataset.rawValue = this.value.replace(/[^0-9.-]/g, '');
  });

  Object.defineProperty(input, 'numericValue', {
    get: function() { return parseFloat((this.dataset.rawValue || this.value || '0').replace(/[^0-9.-]/g, '')) || 0; }
  });
}

function formatMoneyInput(val) {
  var str = String(val).replace(/[^0-9.-]/g, '');
  var parts = str.split('.');
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return parts.join('.');
}

var _moneyObserver = new MutationObserver(function() { initMoneyInputs(); });
document.addEventListener('DOMContentLoaded', function() {
  initMoneyInputs();
  _moneyObserver.observe(document.body, { childList: true, subtree: true });
});
