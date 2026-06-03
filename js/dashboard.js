var _dashReportInterval = null;
var _dashDateFrom = null;
var _dashDateTo = null;

var _boxSpinner = '<div style="display:flex;justify-content:center;align-items:center;padding:20px;"><div style="width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></div>';

function setBoxLoading(ids) {
  ids.forEach(function(id) {
    var el = document.getElementById(id);
    if (el) el.innerHTML = _boxSpinner;
  });
}

async function loadDashboard() {
  if (!_dashDateFrom || !_dashDateTo) {
    var td = getTodayDateString();
    _dashDateFrom = td;
    _dashDateTo = td;
  }
  document.getElementById('dashDateFrom').value = _dashDateFrom;
  document.getElementById('dashDateTo').value = _dashDateTo;

  var dashDayStart = new Date(_dashDateFrom + 'T00:00:00');
  document.getElementById('dashboardDate').textContent = _dashDateFrom === _dashDateTo ? formatDateOnly(dashDayStart) : _dashDateFrom + ' ~ ' + _dashDateTo;

  var salesIds = ['dashSalesBox', 'dashBuybackBox', 'dashWithdrawBox', 'dashNetSellBox'];
  var dbIds = ['dashPLBox', 'dashWACBox', 'dashNewStockBox', 'dashOldStockBox', 'dashCashBox', 'dashBankBox', 'dashTotalGoldBox', 'dashTotalCashBox'];
  var reportIds = ['dashReportBox'];

  setBoxLoading(salesIds);
  setBoxLoading(dbIds);
  setBoxLoading(reportIds);

  var plRow = document.getElementById('dashWACBox').parentElement;
  if (currentUser && currentUser.role === 'Manager') {
    document.getElementById('dashPLBox').style.display = 'none';
    document.getElementById('dashWACBox').style.display = 'none';
    document.getElementById('dashReportBox').style.display = 'none';
    plRow.style.display = 'none';
  } else {
    document.getElementById('dashPLBox').style.display = '';
    document.getElementById('dashWACBox').style.display = '';
    document.getElementById('dashReportBox').style.display = '';
    plRow.style.display = 'grid';
    plRow.style.gridTemplateColumns = 'repeat(3, 1fr)';
  }

  try {
    var data = await dbRpc('get_dashboard_data', {
      p_date_from: _dashDateFrom,
      p_date_to: _dashDateTo
    });

    var gramData = await dbRpc('get_sales_gold_grams', {
      p_date_from: _dashDateFrom,
      p_date_to: _dashDateTo
    });

    renderDashDB(data);
    renderDashSales(data, gramData);
    loadDashReport();
  } catch(e) {
    console.error('Error loading dashboard:', e);
  }
}

function filterDashboard() {
  _dashDateFrom = document.getElementById('dashDateFrom').value;
  _dashDateTo = document.getElementById('dashDateTo').value;
  if (_dashDateFrom && !_dashDateTo) { _dashDateTo = _dashDateFrom; document.getElementById('dashDateTo').value = _dashDateTo; }
  if (!_dashDateFrom && _dashDateTo) { _dashDateFrom = _dashDateTo; document.getElementById('dashDateFrom').value = _dashDateFrom; }
  if (_dashDateFrom && _dashDateTo) loadDashboard();
}

function resetDashDateFilter() {
  var td = getTodayDateString();
  _dashDateFrom = td;
  _dashDateTo = td;
  loadDashboard();
}

function renderDashDB(data) {
  if (!data) return;

  var plDiff = parseFloat(data.pl_diff) || 0;
  var otherExpense = parseFloat(data.other_expense) || 0;
  var todayPL = plDiff - otherExpense;

  var newGoldG = data.wac ? parseFloat(data.wac.new_gold_g) || 0 : 0;
  var newValue = data.wac ? parseFloat(data.wac.new_value) || 0 : 0;
  var oldGoldG = data.wac ? parseFloat(data.wac.old_gold_g) || 0 : 0;
  var oldValue = data.wac ? parseFloat(data.wac.old_value) || 0 : 0;
  var totalGoldG_wac = newGoldG + oldGoldG;
  var totalCost_wac = newValue + oldValue;
  var wacPerG = totalGoldG_wac > 0 ? totalCost_wac / totalGoldG_wac : 0;
  var wacPerBaht = wacPerG * 15;

  document.getElementById('dashPLBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">📈 P/L</h3>' +
    '<p style="font-size:24px;font-weight:bold;color:' + (todayPL >= 0 ? '#4caf50' : '#f44336') + ';margin:10px 0;">' + formatNumber(Math.round(todayPL)) + ' <span style="font-size:12px;">LAK</span></p>';

  document.getElementById('dashWACBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">⚖ WAC</h3>' +
    '<p style="font-size:12px;color:var(--text-secondary);margin:2px 0;">ราคา/g</p>' +
    '<p style="font-size:20px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(wacPerG)) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:12px;color:var(--text-secondary);margin:8px 0 2px 0;">ราคา/บาท</p>' +
    '<p style="font-size:20px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(wacPerBaht)) + ' <span style="font-size:12px;">LAK</span></p>';

  var newPieces = parseFloat(data.new_pieces) || 0;
  var newG = parseFloat(data.new_g) || 0;
  var oldPieces = parseFloat(data.old_pieces) || 0;
  var oldG = parseFloat(data.old_g) || 0;

  document.getElementById('dashNewStockBox').innerHTML =
    '<h3 style="color:#4caf50;margin-bottom:10px;">💎 NEW STOCK</h3>' +
    '<p style="font-size:20px;margin:5px 0;font-weight:bold;">' + newPieces + ' <span style="font-size:13px;">ชิ้น</span></p>' +
    '<p style="font-size:16px;color:var(--text-secondary);">' + newG.toFixed(2) + ' g</p>';

  document.getElementById('dashOldStockBox').innerHTML =
    '<h3 style="color:#ff9800;margin-bottom:10px;">🥇 OLD STOCK</h3>' +
    '<p style="font-size:20px;margin:5px 0;font-weight:bold;">' + oldPieces + ' <span style="font-size:13px;">ชิ้น</span></p>' +
    '<p style="font-size:16px;color:var(--text-secondary);">' + oldG.toFixed(2) + ' g</p>';

  var cash = data.cash || {};
  var cashLAK = parseFloat(cash.LAK) || 0;
  var cashTHB = parseFloat(cash.THB) || 0;
  var cashUSD = parseFloat(cash.USD) || 0;

  document.getElementById('dashCashBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">💵 CASH</h3>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatNumber(cashLAK) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatCurrency(cashTHB, 'THB') + ' <span style="font-size:12px;">THB</span></p>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatCurrency(cashUSD, 'USD') + ' <span style="font-size:12px;">USD</span></p>';

  var bankLAK = 0, bankTHB = 0, bankUSD = 0;
  if (data.banks) {
    Object.keys(data.banks).forEach(function(name) {
      var b = data.banks[name] || {};
      bankLAK += parseFloat(b.LAK) || 0;
      bankTHB += parseFloat(b.THB) || 0;
      bankUSD += parseFloat(b.USD) || 0;
    });
  }

  document.getElementById('dashBankBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">🏦 BANK</h3>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatNumber(bankLAK) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatCurrency(bankTHB, 'THB') + ' <span style="font-size:12px;">THB</span></p>' +
    '<p style="font-size:16px;margin:3px 0;">' + formatCurrency(bankUSD, 'USD') + ' <span style="font-size:12px;">USD</span></p>';

  var totalGoldG = newG + oldG;
  document.getElementById('dashTotalGoldBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">TOTAL GOLD</h3>' +
    '<p style="font-size:28px;margin:5px 0;font-weight:bold;">' + totalGoldG.toFixed(2) + ' g</p>' +
    '<p style="font-size:13px;color:var(--text-secondary);">NEW: ' + newG.toFixed(2) + ' g | OLD: ' + oldG.toFixed(2) + ' g</p>';

  document.getElementById('dashTotalCashBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:10px;">TOTAL CASH + BANK</h3>' +
    '<p style="font-size:18px;margin:5px 0;">' + formatNumber(cashLAK + bankLAK) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:18px;margin:3px 0;">' + formatCurrency(cashTHB + bankTHB, 'THB') + ' <span style="font-size:12px;">THB</span></p>' +
    '<p style="font-size:18px;margin:3px 0;">' + formatCurrency(cashUSD + bankUSD, 'USD') + ' <span style="font-size:12px;">USD</span></p>';
}

function renderDashSales(data, gramData) {
  if (!data) return;

  var sales = data.sales || {};
  var buybacks = data.buybacks || {};
  var withdraws = data.withdraws || {};

  var sellMoney = parseFloat(sales.sell) || 0;
  var sellCount = parseInt(sales.sell_count) || 0;
  var tradeinMoney = parseFloat(sales.tradein) || 0;
  var tradeinCount = parseInt(sales.tradein_count) || 0;
  var exchangeMoney = parseFloat(sales.exchange) || 0;
  var exchangeCount = parseInt(sales.exchange_count) || 0;

  var salesTotal = sellMoney + tradeinMoney + exchangeMoney;
  var salesTotalTx = sellCount + tradeinCount + exchangeCount;

  var salesOldG = gramData ? parseFloat(gramData.sales_old_g) || 0 : 0;
  var salesNewG = gramData ? parseFloat(gramData.sales_new_g) || 0 : 0;
  var bbOldG = gramData ? parseFloat(gramData.buyback_old_g) || 0 : 0;
  var wdNewG = gramData ? parseFloat(gramData.withdraw_new_g) || 0 : 0;

  var salesGoldBaht = (salesNewG - salesOldG) / 15;
  var salesTotalPerBaht = salesGoldBaht > 0 ? Math.round(salesTotal / salesGoldBaht) : 0;

  document.getElementById('dashSalesBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">💰 SALES</h3>' +
    '<p style="font-size:18px;margin:3px 0;font-weight:bold;">Total: ' + formatNumber(Math.round(salesTotal)) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:13px;margin:3px 0;">GOLD Amount: <b>' + salesGoldBaht.toFixed(3) + '</b> <span style="font-size:11px;">บาท</span></p>' +
    '<p style="font-size:13px;margin:3px 0;">Total/Amount: <b>' + formatNumber(salesTotalPerBaht) + '</b> <span style="font-size:11px;">LAK/บาท</span></p>' +
    '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + salesTotalTx + '</b></p>' +
    '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:11px;color:var(--text-secondary);line-height:1.6;">' +
    'Sell: ' + formatNumber(Math.round(sellMoney)) + ' (' + sellCount + ')<br>' +
    'Trade-in: ' + formatNumber(Math.round(tradeinMoney)) + ' (' + tradeinCount + ')<br>' +
    'Exchange: ' + formatNumber(Math.round(exchangeMoney)) + ' (' + exchangeCount + ')' +
    '</div>' +
    '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">' +
    '<span style="color:#ff9800;">◀ Old In: ' + salesOldG.toFixed(2) + ' g</span><br>' +
    '<span style="color:#4caf50;">▶ New Out: ' + salesNewG.toFixed(2) + ' g</span>' +
    '</div>';

  var bbMoney = parseFloat(buybacks.amount) || 0;
  var bbCount = parseInt(buybacks.count) || 0;
  var bbGoldBaht = bbOldG / 15;
  var bbTotalPerBaht = bbGoldBaht > 0 ? Math.round(bbMoney / bbGoldBaht) : 0;

  document.getElementById('dashBuybackBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">🔄 BUYBACK</h3>' +
    '<p style="font-size:18px;margin:3px 0;font-weight:bold;">Total: ' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:13px;margin:3px 0;">GOLD Amount: <b>' + bbGoldBaht.toFixed(3) + '</b> <span style="font-size:11px;">บาท</span></p>' +
    '<p style="font-size:13px;margin:3px 0;">Total/Amount: <b>' + formatNumber(bbTotalPerBaht) + '</b> <span style="font-size:11px;">LAK/บาท</span></p>' +
    '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + bbCount + '</b></p>' +
    '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">' +
    '<span style="color:#ff9800;">◀ Old In: ' + bbOldG.toFixed(2) + ' g</span>' +
    '</div>';

  var wdMoney = parseFloat(withdraws.amount) || 0;
  var wdCount = parseInt(withdraws.count) || 0;

  document.getElementById('dashWithdrawBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">📤 WITHDRAW</h3>' +
    '<p style="font-size:18px;margin:3px 0;font-weight:bold;">' + formatNumber(Math.round(wdMoney)) + ' <span style="font-size:12px;">LAK</span></p>' +
    '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + wdCount + '</b></p>' +
    '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">' +
    '<span style="color:#4caf50;">▶ New Out: ' + wdNewG.toFixed(2) + ' g</span>' +
    '</div>';

  var totalOldGIn = salesOldG + bbOldG;
  var totalNewGOut = salesNewG + wdNewG;
  var netSellBaht = (totalNewGOut - totalOldGIn) / 15;
  var netColor = netSellBaht >= 0 ? '#4caf50' : '#f44336';

  document.getElementById('dashNetSellBox').innerHTML =
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">⚖ NET SELL</h3>' +
    '<p style="font-size:24px;margin:8px 0;font-weight:bold;color:' + netColor + ';">' + netSellBaht.toFixed(3) + ' <span style="font-size:13px;">บาท</span></p>' +
    '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:11px;color:var(--text-secondary);line-height:1.6;">' +
    'New Out ทั้งหมด: ' + totalNewGOut.toFixed(2) + ' g<br>' +
    'Old In ทั้งหมด: ' + totalOldGIn.toFixed(2) + ' g<br>' +
    'Net: ' + (totalNewGOut - totalOldGIn).toFixed(2) + ' g ÷ 15' +
    '</div>';
}

async function loadDashReport() {
  try {
    await refreshDashReport();
    startDashReportRefresh();
  } catch(e) {}
}

async function refreshDashReport() {
  try {
    var data = await dbRpc('get_live_report', {});
    if (!data) return;
    var net = parseFloat(data.netTotal) || 0;
    var carry = parseFloat(data.carryForward) || 0;
    var diff = parseFloat(data.diff) || 0;
    var diffColor = diff >= 0 ? '#4caf50' : '#f44336';
    var diffSign = diff >= 0 ? '+' : '';

    document.getElementById('dashReportBox').innerHTML =
      '<h3 style="color:var(--gold-primary);margin-bottom:8px;">📋 Wealth</h3>' +
      '<p style="font-size:11px;color:var(--text-secondary);margin:0;">ส่วนต่างทอง (เมื่อวาน − ปัจจุบัน)</p>' +
      '<p style="font-size:26px;font-weight:bold;color:' + diffColor + ';margin:4px 0;">' + diffSign + diff.toFixed(2) + ' g</p>' +
      '<div style="border-top:1px solid var(--border-color);margin-top:8px;padding-top:8px;">' +
      '<div style="display:flex;justify-content:space-between;font-size:12px;margin:3px 0;"><span style="color:var(--text-secondary);">ทองเมื่อวาน</span><span style="font-weight:bold;">' + carry.toFixed(2) + ' g</span></div>' +
      '<div style="display:flex;justify-content:space-between;font-size:12px;margin:3px 0;"><span style="color:var(--text-secondary);">ทองปัจจุบัน</span><span style="font-weight:bold;">' + net.toFixed(2) + ' g</span></div>' +
      '</div>';
  } catch(e) {}
}

function startDashReportRefresh() {
  stopDashReportRefresh();
  _dashReportInterval = setInterval(refreshDashReport, 10000);
}

function stopDashReportRefresh() {
  if (_dashReportInterval) {
    clearInterval(_dashReportInterval);
    _dashReportInterval = null;
  }
}
