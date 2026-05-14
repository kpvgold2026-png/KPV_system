var _lrDateFrom = null;
var _lrDateTo = null;

function initLiveReportDateFilter() {
  var today = getTodayLocalStr();
  var elFrom = document.getElementById('lrDateFrom');
  var elTo = document.getElementById('lrDateTo');
  if (elFrom && !elFrom.value) elFrom.value = today;
  if (elTo && !elTo.value) elTo.value = today;
  _lrDateFrom = elFrom ? elFrom.value : today;
  _lrDateTo = elTo ? elTo.value : today;
}

function filterLiveReport() {
  var f = document.getElementById('lrDateFrom').value;
  var t = document.getElementById('lrDateTo').value;
  if (f && !t) t = f;
  if (t && !f) f = t;
  _lrDateFrom = f || null;
  _lrDateTo = t || null;
  loadLiveReport();
}

function resetLiveReportFilter() {
  var today = getTodayLocalStr();
  document.getElementById('lrDateFrom').value = today;
  document.getElementById('lrDateTo').value = today;
  _lrDateFrom = today;
  _lrDateTo = today;
  loadLiveReport();
}

async function loadLiveReport() {
  if (!currentUser || (currentUser.role !== 'Admin' && !isManager())) return;
  initLiveReportDateFilter();

  var dateFrom = _lrDateFrom;
  var dateTo = _lrDateTo;

  var spinnerHtml = '<div style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></div>';
  ['lrSalesStatus', 'lrSummaryBoxes', 'lrSalesPayments', 'lrBuybackPayments', 'lrStockSummary', 'lrGoldTable'].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) el.innerHTML = spinnerHtml;
  });

  try {
    var dashData = await dbRpc('get_dashboard_data', { p_date_from: dateFrom, p_date_to: dateTo });
    var gramData = await dbRpc('get_sales_gold_grams', { p_date_from: dateFrom, p_date_to: dateTo });
    var historyData = await dbRpc('get_history_txs', { p_date_from: dateFrom, p_date_to: dateTo, p_limit: 1000 });

    var salesBreakdown = null;
    try {
      salesBreakdown = await dbRpc('get_live_report_sales_breakdown', { p_date_from: dateFrom, p_date_to: dateTo });
    } catch(e) { console.warn('get_live_report_sales_breakdown not available:', e); }

    renderLRSummaryBoxes(dashData, gramData);
    if (salesBreakdown && Array.isArray(salesBreakdown) && salesBreakdown.length > 0) {
      renderLRSalesStatusV2(salesBreakdown);
      renderLRPaymentsBreakdownV2(salesBreakdown);
    } else {
      renderLRSalesStatus(historyData, dateFrom, dateTo);
      renderLRPaymentsByType(historyData, dateFrom, dateTo);
    }
    renderLRStockSummary(gramData);
    renderLRGoldDetailFromHistory(historyData);
  } catch(e) {
    console.error('Error loading live report:', e);
  }
}

// per-sales breakdown: shift status + sell/buyback/withdraw + per-product old gold + cash buttons
function renderLRSalesStatusV2(rows) {
  var container = document.getElementById('lrSalesStatus');
  if (!container) return;
  window._lrSalesGold = {};
  window._lrSalesCash = {};

  var products = ['G01','G02','G03','G04','G05','G06','G07'];
  var html = '<h3 style="color:var(--gold-primary);font-size:16px;margin-bottom:12px;">📋 สถานะ Sales แต่ละคน</h3>';
  if (rows.length === 0) {
    html += '<div style="text-align:center;padding:20px;color:var(--text-secondary);">ไม่มีข้อมูล Sales</div>';
    container.innerHTML = html;
    return;
  }

  rows.forEach(function(r) {
    var name = r.nickname || 'Unknown';
    var status = r.shift_status || 'OPEN';
    var statusText, statusColor;
    if (status === 'CLOSED') { statusText = '🔴 ปิดกะแล้ว'; statusColor = '#f44336'; }
    else if (status === 'PENDING') { statusText = '⏳ รอ Manager ยืนยัน'; statusColor = '#d4af37'; }
    else { statusText = '🟢 เปิดกะอยู่'; statusColor = '#4caf50'; }

    // build per-product goldQty map
    var goldQty = {};
    products.forEach(function(p) { goldQty[p] = 0; });
    var rawGold = r.old_gold || {};
    Object.keys(rawGold).forEach(function(p) {
      if (goldQty[p] !== undefined) goldQty[p] = parseFloat(rawGold[p]) || 0;
    });
    window._lrSalesGold[name] = goldQty;
    window._lrSalesCash[name] = r.cash_breakdown || {};

    var sellLAK = parseFloat(r.sell_money) || 0;
    var sellG = parseFloat(r.sell_gold_g) || 0;
    var sellCount = parseInt(r.sell_count) || 0;
    var bbLAK = parseFloat(r.buyback_money) || 0;
    var bbG = parseFloat(r.buyback_gold_g) || 0;
    var bbCount = parseInt(r.buyback_count) || 0;
    var wdLAK = parseFloat(r.withdraw_money) || 0;
    var wdG = parseFloat(r.withdraw_gold_g) || 0;
    var wdCount = parseInt(r.withdraw_count) || 0;

    var cashLAK = 0, cashTHB = 0, cashUSD = 0;
    var cb = r.cash_breakdown || {};
    ['Cash','BCEL','LDB','Other'].forEach(function(k) {
      var d = cb[k] || {};
      cashLAK += parseFloat(d.LAK) || 0;
      cashTHB += parseFloat(d.THB) || 0;
      cashUSD += parseFloat(d.USD) || 0;
    });

    var oldGoldG = 0;
    Object.keys(goldQty).forEach(function(pid) {
      var w = { 'G01':150,'G02':75,'G03':30,'G04':15,'G05':7.5,'G06':3.75,'G07':1 }[pid] || 0;
      oldGoldG += w * (goldQty[pid] || 0);
    });

    html += '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:12px;">';
    html += '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;">';
    html += '<span style="font-weight:700;font-size:16px;color:var(--gold-primary);">' + name + '</span>';
    html += '<div style="display:flex;gap:10px;align-items:center;">';
    html += '<button onclick="showLROldGoldModal(\'' + name.replace(/'/g, "\\'") + '\')" style="background:var(--gold-primary);color:#000;border:none;border-radius:6px;padding:4px 12px;font-size:12px;font-weight:600;cursor:pointer;">View ทองเก่า</button>';
    html += '<span style="font-size:13px;color:' + statusColor + ';font-weight:600;">' + statusText + '</span>';
    html += '</div></div>';
    html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;font-size:13px;">';
    html += '<div><span style="color:var(--text-secondary);">Sales:</span> ' + formatNumber(sellLAK) + ' LAK | ' + sellG.toFixed(2) + 'g | ' + sellCount + ' บิล</div>';
    html += '<div><span style="color:var(--text-secondary);">Withdraw:</span> ' + formatNumber(wdLAK) + ' LAK | ' + wdG.toFixed(2) + 'g | ' + wdCount + ' บิล</div>';
    html += '<div><span style="color:var(--text-secondary);">Buyback:</span> ' + formatNumber(bbLAK) + ' LAK | ' + bbG.toFixed(2) + 'g | ' + bbCount + ' บิล</div>';
    html += '<div><span style="color:var(--text-secondary);">เงินสด:</span> ' + formatNumber(cashLAK) + ' LAK | ' + formatCurrency(cashTHB,'THB') + ' THB | ' + formatCurrency(cashUSD,'USD') + ' USD</div>';
    html += '<div><span style="color:var(--text-secondary);">ทองเก่า:</span> ' + oldGoldG.toFixed(2) + ' g</div>';
    html += '</div></div>';
  });
  container.innerHTML = html;
}

function renderLRPaymentsBreakdownV2(rows) {
  var salesContainer = document.getElementById('lrSalesPayments');
  var bbContainer = document.getElementById('lrBuybackPayments');

  // aggregate per-user × per-method × per-currency
  var thS = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.3);padding:8px 10px;font-size:12px;font-weight:700;';

  function renderTable(title, methodKeys, totalsKey) {
    var html = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:15px;">';
    html += '<h3 style="color:var(--gold-primary);font-size:15px;margin-bottom:10px;">' + title + '</h3>';
    html += '<table style="width:100%;border-collapse:collapse;">';
    html += '<thead><tr>';
    html += '<th style="' + thS + 'text-align:left;">Sales</th>';
    methodKeys.forEach(function(m) {
      html += '<th style="' + thS + 'text-align:center;">' + m + ' LAK</th>';
      html += '<th style="' + thS + 'text-align:center;">' + m + ' THB</th>';
      html += '<th style="' + thS + 'text-align:center;">' + m + ' USD</th>';
    });
    html += '</tr></thead><tbody>';
    rows.forEach(function(r) {
      var cb = r.cash_breakdown || {};
      var hasAny = false;
      methodKeys.forEach(function(m) {
        var d = cb[m] || {};
        if ((parseFloat(d.LAK)||0) || (parseFloat(d.THB)||0) || (parseFloat(d.USD)||0)) hasAny = true;
      });
      if (!hasAny) return;
      html += '<tr style="border-top:1px solid var(--border-color);">';
      html += '<td style="padding:6px 10px;font-weight:600;">' + (r.nickname || '-') + '</td>';
      methodKeys.forEach(function(m) {
        var d = cb[m] || {};
        html += '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.LAK) || 0)) + '</td>';
        html += '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.THB) || 0)) + '</td>';
        html += '<td style="padding:6px 10px;text-align:right;">' + formatNumber(Math.round(parseFloat(d.USD) || 0)) + '</td>';
      });
      html += '</tr>';
    });
    html += '</tbody></table></div>';
    return html;
  }

  if (salesContainer) {
    salesContainer.innerHTML = renderTable('💵 Sales Payments (per-method × currency)', ['Cash','BCEL','LDB','Other']);
  }
  if (bbContainer) {
    // buyback ใช้ data เดียวกัน (cashbook ของ sales — รวมทุก tx) → ให้ user เห็น breakdown เดียวกัน
    var salesTotal = 0, bbTotal = 0;
    rows.forEach(function(r) {
      salesTotal += parseFloat(r.sell_money) || 0;
      bbTotal += parseFloat(r.buyback_money) || 0;
    });
    bbContainer.innerHTML = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:15px;">' +
      '<h3 style="color:var(--gold-primary);font-size:15px;margin-bottom:10px;">🔄 Buyback Total (รวม)</h3>' +
      '<p style="font-size:20px;font-weight:bold;">' + formatNumber(Math.round(bbTotal)) + ' LAK</p>' +
      '</div>';
  }
}

// คลิกชื่อ Sales → modal แสดงทองเก่า + breakdown payment method × currency
function showLROldGoldModal(salesName) {
  var modal = document.getElementById('lrOldGoldModal');
  var title = document.getElementById('lrOldGoldTitle');
  var content = document.getElementById('lrOldGoldContent');
  if (!modal || !content) return;

  if (title) title.textContent = 'รายละเอียด — ' + salesName;

  var cashData = (window._lrSalesCash && window._lrSalesCash[salesName]) || {};
  var html = '<div style="margin-bottom:16px;padding:14px;background:rgba(76,175,80,0.08);border-radius:8px;border:1px solid rgba(76,175,80,0.2);">';
  html += '<div style="font-size:13px;color:#4caf50;font-weight:700;margin-bottom:10px;">💵 สรุปเงินทั้งหมด</div>';
  html += '<table style="width:100%;border-collapse:collapse;">';
  var thC = 'background:#2d2d2d;color:#4caf50;border:1px solid rgba(76,175,80,0.3);padding:8px 12px;font-size:12px;font-weight:700;';
  html += '<thead><tr><th style="' + thC + 'text-align:left;">ประเภท</th><th style="' + thC + 'text-align:center;">LAK</th><th style="' + thC + 'text-align:center;">THB</th><th style="' + thC + 'text-align:center;">USD</th></tr></thead><tbody>';
  [{key:'Cash',icon:'💵'},{key:'BCEL',icon:'🏦'},{key:'LDB',icon:'🏦'},{key:'Other',icon:'🏦'}].forEach(function(m) {
    var d = cashData[m.key] || { LAK: 0, THB: 0, USD: 0 };
    html += '<tr style="border-top:1px solid var(--border-color);">';
    html += '<td style="padding:8px 12px;font-size:13px;font-weight:600;">' + m.icon + ' ' + m.key + '</td>';
    html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#4caf50;font-weight:600;">' + formatNumber(parseFloat(d.LAK) || 0) + '</td>';
    html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#2196f3;font-weight:600;">' + formatCurrency(parseFloat(d.THB) || 0, 'THB') + '</td>';
    html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#ff9800;font-weight:600;">' + formatCurrency(parseFloat(d.USD) || 0, 'USD') + '</td>';
    html += '</tr>';
  });
  html += '</tbody></table></div>';

  var goldQty = (window._lrSalesGold && window._lrSalesGold[salesName]) || {};
  var products = ['G01','G02','G03','G04','G05','G06','G07'];
  var pNames = {'G01':'10 บาท','G02':'5 บาท','G03':'2 บาท','G04':'1 บาท','G05':'2 สลึง','G06':'1 สลึง','G07':'1 กรัม'};

  html += '<div style="font-size:13px;color:var(--gold-primary);font-weight:700;margin-bottom:10px;">◀ ทองเก่าที่ได้รับ</div>';
  var thG = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.3);padding:10px 12px;font-size:12px;font-weight:700;';
  html += '<table style="width:100%;border-collapse:collapse;">';
  html += '<thead><tr><th style="' + thG + 'text-align:left;">Product</th><th style="' + thG + 'text-align:center;">Unit</th></tr></thead><tbody>';
  var totalQty = 0;
  products.forEach(function(p) {
    var q = goldQty[p] || 0;
    totalQty += q;
    var valStyle = q > 0 ? 'color:var(--gold-primary);font-weight:700;font-size:15px;' : 'color:var(--text-secondary);';
    html += '<tr style="border-top:1px solid var(--border-color);">';
    html += '<td style="padding:8px 12px;font-size:13px;">' + pNames[p] + '</td>';
    html += '<td style="padding:8px 12px;text-align:center;' + valStyle + '">' + q + '</td>';
    html += '</tr>';
  });
  html += '<tr style="border-top:2px solid var(--gold-primary);background:rgba(212,175,55,0.08);">';
  html += '<td style="padding:10px 12px;font-size:13px;font-weight:700;color:var(--gold-primary);">รวม</td>';
  html += '<td style="padding:10px 12px;text-align:center;font-size:15px;font-weight:700;color:var(--gold-primary);">' + totalQty + '</td>';
  html += '</tr></tbody></table>';

  content.innerHTML = html;
  modal.style.display = 'flex';
}

function renderLRSummaryBoxes(dashData, gramData) {
  var container = document.getElementById('lrSummaryBoxes');
  if (!container) return;

  var sales = dashData && dashData.sales ? dashData.sales : {};
  var buybacks = dashData && dashData.buybacks ? dashData.buybacks : {};
  var withdraws = dashData && dashData.withdraws ? dashData.withdraws : {};

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

  var totalOldGIn = salesOldG + bbOldG;
  var totalNewGOut = salesNewG + wdNewG;
  var netSellBaht = (totalNewGOut - totalOldGIn) / 15;

  var salesGoldBaht = (salesNewG - salesOldG) / 15;
  var salesTotalPerBaht = salesGoldBaht > 0 ? Math.round(salesTotal / salesGoldBaht) : 0;

  var bbMoney = parseFloat(buybacks.amount) || 0;
  var bbCount = parseInt(buybacks.count) || 0;
  var bbGoldBaht = bbOldG / 15;
  var bbTotalPerBaht = bbGoldBaht > 0 ? Math.round(bbMoney / bbGoldBaht) : 0;

  var wdMoney = parseFloat(withdraws.amount) || 0;
  var wdCount = parseInt(withdraws.count) || 0;

  var boxStyle = 'background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:20px;';
  var netColor = netSellBaht >= 0 ? '#4caf50' : '#f44336';

  var html = '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:15px;margin-bottom:25px;">';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">⚖ NET SELL</h3>';
  html += '<p style="font-size:24px;margin:8px 0;font-weight:bold;color:' + netColor + ';">' + netSellBaht.toFixed(3) + ' <span style="font-size:13px;">บาท</span></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:11px;color:var(--text-secondary);line-height:1.6;">';
  html += 'New Out ทั้งหมด: ' + totalNewGOut.toFixed(2) + ' g<br>';
  html += 'Old In ทั้งหมด: ' + totalOldGIn.toFixed(2) + ' g<br>';
  html += 'Net: ' + (totalNewGOut - totalOldGIn).toFixed(2) + ' g ÷ 15';
  html += '</div></div>';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">💰 SALES</h3>';
  html += '<p style="font-size:18px;margin:3px 0;font-weight:bold;">Total: ' + formatNumber(Math.round(salesTotal)) + ' <span style="font-size:12px;">LAK</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">GOLD Amount: <b>' + salesGoldBaht.toFixed(3) + '</b> <span style="font-size:11px;">บาท</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">Total/Amount: <b>' + formatNumber(salesTotalPerBaht) + '</b> <span style="font-size:11px;">LAK/บาท</span></p>';
  html += '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + salesTotalTx + '</b></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:11px;color:var(--text-secondary);line-height:1.6;">';
  html += 'Sell: ' + formatNumber(Math.round(sellMoney)) + ' (' + sellCount + ')<br>';
  html += 'Trade-in: ' + formatNumber(Math.round(tradeinMoney)) + ' (' + tradeinCount + ')<br>';
  html += 'Exchange: ' + formatNumber(Math.round(exchangeMoney)) + ' (' + exchangeCount + ')';
  html += '</div>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#ff9800;">◀ Old In: ' + salesOldG.toFixed(2) + ' g</span><br>';
  html += '<span style="color:#4caf50;">▶ New Out: ' + salesNewG.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">🔄 BUYBACK</h3>';
  html += '<p style="font-size:18px;margin:3px 0;font-weight:bold;">Total: ' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:12px;">LAK</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">GOLD Amount: <b>' + bbGoldBaht.toFixed(3) + '</b> <span style="font-size:11px;">บาท</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">Total/Amount: <b>' + formatNumber(bbTotalPerBaht) + '</b> <span style="font-size:11px;">LAK/บาท</span></p>';
  html += '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + bbCount + '</b></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#ff9800;">◀ Old In: ' + bbOldG.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">📤 WITHDRAW</h3>';
  html += '<p style="font-size:18px;margin:3px 0;font-weight:bold;">' + formatNumber(Math.round(wdMoney)) + ' <span style="font-size:12px;">LAK</span></p>';
  html += '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + wdCount + '</b></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#4caf50;">▶ New Out: ' + wdNewG.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '</div>';
  container.innerHTML = html;
}

function renderLRSalesStatus(historyData, dateFrom, dateTo) {
  var container = document.getElementById('lrSalesStatus');
  if (!container) return;

  var salesByUser = {};
  (historyData || []).forEach(function(r) {
    if (r.status !== 'COMPLETED' && r.status !== 'PAID' && r.status !== 'PARTIAL') return;
    var name = r.sale_nickname || 'Unknown';
    if (!salesByUser[name]) {
      salesByUser[name] = { sellCount: 0, sellLAK: 0, bbCount: 0, bbLAK: 0, wdCount: 0, wdLAK: 0, otherCount: 0, otherLAK: 0 };
    }
    var amt = parseFloat(r.total) || 0;
    if (r.type === 'SELL') { salesByUser[name].sellCount++; salesByUser[name].sellLAK += amt; }
    else if (r.type === 'BUYBACK') { salesByUser[name].bbCount++; salesByUser[name].bbLAK += amt; }
    else if (r.type === 'WITHDRAW') { salesByUser[name].wdCount++; salesByUser[name].wdLAK += amt; }
    else { salesByUser[name].otherCount++; salesByUser[name].otherLAK += amt; }
  });

  var html = '<h3 style="color:var(--gold-primary);font-size:16px;margin-bottom:12px;">📋 สถานะ Sales แต่ละคน</h3>';
  if (Object.keys(salesByUser).length === 0) {
    html += '<div style="text-align:center;padding:20px;color:var(--text-secondary);">ไม่มี Sales ทำรายการในช่วงนี้</div>';
  } else {
    html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;margin-bottom:25px;">';
    Object.keys(salesByUser).forEach(function(name) {
      var d = salesByUser[name];
      var totalCount = d.sellCount + d.bbCount + d.wdCount + d.otherCount;
      var totalLAK = d.sellLAK + d.bbLAK + d.wdLAK + d.otherLAK;
      html += '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:10px;padding:15px;">';
      html += '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;"><span style="font-weight:bold;font-size:14px;">👤 ' + name + '</span><span style="font-size:11px;color:#4caf50;">🟢 ทำงานอยู่</span></div>';
      html += '<div style="font-size:12px;color:var(--text-secondary);line-height:1.7;">';
      if (d.sellCount > 0) html += 'Sales: ' + formatNumber(Math.round(d.sellLAK)) + ' LAK (' + d.sellCount + ' tx)<br>';
      if (d.otherCount > 0) html += 'Trade/Ex: ' + formatNumber(Math.round(d.otherLAK)) + ' LAK (' + d.otherCount + ' tx)<br>';
      if (d.bbCount > 0) html += 'Buyback: ' + formatNumber(Math.round(d.bbLAK)) + ' LAK (' + d.bbCount + ' tx)<br>';
      if (d.wdCount > 0) html += 'Withdraw: ' + formatNumber(Math.round(d.wdLAK)) + ' LAK (' + d.wdCount + ' tx)<br>';
      html += '</div>';
      html += '<div style="border-top:1px solid var(--border-color);margin-top:8px;padding-top:8px;font-size:13px;font-weight:bold;">Total: ' + formatNumber(Math.round(totalLAK)) + ' LAK (' + totalCount + ' tx)</div>';
      html += '</div>';
    });
    html += '</div>';
  }
  container.innerHTML = html;
}

function renderLRPaymentsByType(historyData, dateFrom, dateTo) {
  var salesContainer = document.getElementById('lrSalesPayments');
  var bbContainer = document.getElementById('lrBuybackPayments');

  var salesTotal = 0, bbTotal = 0;
  (historyData || []).forEach(function(r) {
    if (r.status !== 'COMPLETED' && r.status !== 'PAID' && r.status !== 'PARTIAL') return;
    var amt = parseFloat(r.total) || 0;
    if (r.type === 'BUYBACK') bbTotal += amt;
    else if (r.type !== 'WITHDRAW') salesTotal += amt;
  });

  if (salesContainer) {
    salesContainer.innerHTML = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:15px;">' +
      '<h3 style="color:var(--gold-primary);font-size:15px;margin-bottom:10px;">💵 Sales Payments</h3>' +
      '<p style="font-size:20px;font-weight:bold;">' + formatNumber(Math.round(salesTotal)) + ' LAK</p>' +
      '</div>';
  }
  if (bbContainer) {
    bbContainer.innerHTML = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:15px;">' +
      '<h3 style="color:var(--gold-primary);font-size:15px;margin-bottom:10px;">🔄 Buyback Payments</h3>' +
      '<p style="font-size:20px;font-weight:bold;">' + formatNumber(Math.round(bbTotal)) + ' LAK</p>' +
      '</div>';
  }
}

function renderLRStockSummary(gramData) {
  var container = document.getElementById('lrStockSummary');
  if (!container) return;
  var salesOldG = gramData ? parseFloat(gramData.sales_old_g) || 0 : 0;
  var salesNewG = gramData ? parseFloat(gramData.sales_new_g) || 0 : 0;
  var bbOldG = gramData ? parseFloat(gramData.buyback_old_g) || 0 : 0;
  var wdNewG = gramData ? parseFloat(gramData.withdraw_new_g) || 0 : 0;
  var newOutG = salesNewG + wdNewG;
  var oldInG = salesOldG + bbOldG;

  var boxStyle = 'background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:20px;text-align:center;';
  var html = '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:20px;">';
  html += '<div style="' + boxStyle + '"><div style="color:var(--text-secondary);font-size:12px;margin-bottom:8px;">NEW OUT (ทองใหม่ออก)</div><div style="font-size:24px;font-weight:700;color:#f44336;">' + newOutG.toFixed(2) + ' g</div></div>';
  html += '<div style="' + boxStyle + '"><div style="color:var(--text-secondary);font-size:12px;margin-bottom:8px;">OLD IN (ทองเก่ารับเข้า)</div><div style="font-size:24px;font-weight:700;color:#4caf50;">' + oldInG.toFixed(2) + ' g</div></div>';
  html += '</div>';
  container.innerHTML = html;
}

function renderLRGoldDetailFromHistory(historyData) {
  var container = document.getElementById('lrGoldTable');
  if (!container) return;
  var products = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];
  var names = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
  var newOut = {}, oldIn = {};
  products.forEach(function(p) { newOut[p] = 0; oldIn[p] = 0; });

  (historyData || []).forEach(function(r) {
    if (r.status !== 'COMPLETED' && r.status !== 'PAID' && r.status !== 'PARTIAL') return;
    (r.items || []).forEach(function(it) {
      if (newOut[it.productId] === undefined) return;
      if (it.role === 'NEW') newOut[it.productId] += (parseFloat(it.qty) || 0);
      else if (it.role === 'OLD' || it.role === 'FOC') oldIn[it.productId] += (parseFloat(it.qty) || 0);
    });
  });

  var thStyle = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.5);padding:10px 8px;font-size:12px;text-align:center;font-weight:700;';
  var tdStyle = 'border:1px solid var(--border-color);padding:8px;text-align:center;font-size:13px;';

  var html = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;">';
  html += '<h3 style="color:var(--gold-primary);font-size:16px;margin-bottom:12px;">รายละเอียดทองแต่ละ Product</h3>';
  html += '<div class="table-container"><table><thead><tr>';
  html += '<th style="' + thStyle + '">Product</th>';
  html += '<th style="' + thStyle + '">New Out</th>';
  html += '<th style="' + thStyle + '">Old In</th>';
  html += '</tr></thead><tbody>';

  var tNewOut = 0, tOldIn = 0;
  products.forEach(function(p) {
    tNewOut += newOut[p]; tOldIn += oldIn[p];
    html += '<tr>';
    html += '<td style="' + tdStyle + 'font-weight:600;">' + names[p] + ' (' + p + ')</td>';
    html += '<td style="' + tdStyle + 'color:' + (newOut[p] > 0 ? '#f44336' : 'var(--text-secondary)') + ';">' + newOut[p] + '</td>';
    html += '<td style="' + tdStyle + 'color:' + (oldIn[p] > 0 ? '#4caf50' : 'var(--text-secondary)') + ';">' + oldIn[p] + '</td>';
    html += '</tr>';
  });
  html += '<tr style="background:rgba(212,175,55,0.1);font-weight:700;">';
  html += '<td style="' + tdStyle + 'color:var(--gold-primary);font-weight:700;">รวม</td>';
  html += '<td style="' + tdStyle + 'color:#f44336;font-weight:700;">' + tNewOut + '</td>';
  html += '<td style="' + tdStyle + 'color:#4caf50;font-weight:700;">' + tOldIn + '</td>';
  html += '</tr>';
  html += '</tbody></table></div></div>';
  container.innerHTML = html;
}

async function loadSalesInfoBar() {
  if (!currentUser || currentUser.role !== 'User') {
    var bar = document.getElementById('salesInfoBar');
    if (bar) bar.style.display = 'none';
    return;
  }
  try {
    var bar = document.getElementById('salesInfoBar');
    if (bar) bar.style.display = 'block';
    var spinner = document.getElementById('salesInfoSpinner');
    var content = document.getElementById('salesInfoContent');
    if (spinner) spinner.style.display = 'block';
    if (content) content.style.display = 'none';

    var s1b = currentPricing.sell1Baht || 0;
    var sellPrice = calculateSellPrice('G04', s1b);
    var buybackPrice = calculateBuybackPrice('G04', s1b);

    document.getElementById('siSellPrice').textContent = formatNumber(sellPrice);
    document.getElementById('siBuybackPrice').textContent = formatNumber(buybackPrice);
    document.getElementById('siThbSell').textContent = formatCurrency(currentExchangeRates.THB_Sell || 0, 'THB');
    document.getElementById('siUsdSell').textContent = formatCurrency(currentExchangeRates.USD_Sell || 0, 'USD');
    document.getElementById('siThbBuy').textContent = formatCurrency(currentExchangeRates.THB_Buy || 0, 'THB');
    document.getElementById('siUsdBuy').textContent = formatCurrency(currentExchangeRates.USD_Buy || 0, 'USD');

    if (spinner) spinner.style.display = 'none';
    if (content) content.style.display = 'block';
  } catch(e) {
    console.error('loadSalesInfoBar error:', e);
  }
}

function printLiveReport() {
  var dateFrom = document.getElementById('lrDateFrom').value || '';
  var dateTo = document.getElementById('lrDateTo').value || '';

  var sections = ['lrSummaryBoxes', 'lrSalesPayments', 'lrBuybackPayments', 'lrStockSummary', 'lrGoldTable'];
  var contentHtml = '';
  sections.forEach(function(id) {
    var el = document.getElementById(id);
    if (el && el.innerHTML.trim()) contentHtml += '<div class="print-section">' + el.innerHTML + '</div>';
  });

  var css = [
    '* { box-sizing: border-box; margin: 0; padding: 0; }',
    'body { font-family: "Segoe UI", Arial, sans-serif; padding: 30px; background: #fff; color: #333; font-size: 13px; line-height: 1.5; }',
    '.print-header { text-align: center; border-bottom: 3px solid #b8860b; padding-bottom: 20px; margin-bottom: 30px; }',
    '.print-header h1 { color: #b8860b; font-size: 28px; font-weight: 700; letter-spacing: 2px; margin-bottom: 4px; }',
    '.print-section { margin-bottom: 25px; page-break-inside: avoid; padding-top: 5mm; }',
    'h3 { color: #b8860b !important; font-size: 15px; margin-bottom: 12px; padding-bottom: 6px; border-bottom: 1px solid #e0c878; }',
    'table { width: 100%; border-collapse: collapse; margin-bottom: 15px; font-size: 12px; }',
    'thead th { background: #b8860b !important; color: #fff !important; padding: 10px 8px; font-size: 11px; text-align: center; font-weight: 700; }',
    'tbody td { border: 1px solid #ddd; padding: 8px; text-align: center; color: #333 !important; }',
    'p, span, div { color: #333 !important; }',
    'span[style*="color:#4caf50"] { color: #2e7d32 !important; }',
    'span[style*="color:#f44336"] { color: #c62828 !important; }',
    '@media print { @page { margin: 10mm; } .print-section { page-break-inside: avoid; } }'
  ].join('\n');

  var printWin = window.open('', '_blank');
  printWin.document.write('<!DOCTYPE html><html><head><title>Live Report</title>');
  printWin.document.write('<style>' + css + '</style></head><body>');
  printWin.document.write('<div class="print-header">');
  printWin.document.write('<h1>KPV GOLD</h1>');
  printWin.document.write('<div class="subtitle">Live Report: ' + (dateFrom || '-') + ' to ' + (dateTo || '-') + ' | Printed: ' + new Date().toLocaleString() + '</div>');
  printWin.document.write('</div>');
  printWin.document.write(contentHtml);
  printWin.document.write('</body></html>');
  printWin.document.close();
  setTimeout(function() { printWin.print(); }, 500);
}
