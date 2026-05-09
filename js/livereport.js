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
  ['lrSalesStatus','lrSummaryBoxes','lrSalesPayments','lrBuybackPayments','lrStockSummary','lrGoldTable'].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) el.innerHTML = spinnerHtml;
  });

  try {
    var dbData = await fetchSheetData('_database!A1:M100');
    var sellsData = await fetchSheetData('Sells!A:M');
    var tradeinsData = await fetchSheetData('Tradeins!A:O');
    var exchangesData = await fetchSheetData('Exchanges!A:T');
    var buybacksData = await fetchSheetData('Buybacks!A:L');
    var withdrawsData = await fetchSheetData('Withdraws!A:L');
    var closeData = await fetchSheetData('Close!A:K');
    var cashbankData = await fetchSheetData('CashBank!A:I');
    var stockMoveNewData = await fetchSheetData('StockMove_New!A:K');
    var stockMoveOldData = await fetchSheetData('StockMove_Old!A:K');

    var users = [];
    if (dbData && dbData.length > 33) {
      for (var i = 33; i < dbData.length; i++) {
        if (dbData[i] && dbData[i][2] && String(dbData[i][2]).trim()) {
          var role = String(dbData[i][0] || '').trim();
          var nickname = String(dbData[i][1] || '').trim();
          if (role === 'Sales' && nickname) {
            users.push(nickname);
          }
        }
      }
    }

    var extraRanges = ['Switches!A:N', 'FreeExchanges!A:J', '_log_cashbank!A:I'];
    for (var u = 0; u < users.length; u++) {
      extraRanges.push(users[u] + '!A:I');
      extraRanges.push(users[u] + '_Gold!A:F');
    }

    var extraResult = {};
    try {
      var br = await callAppsScript('BATCH_READ', { ranges: JSON.stringify(extraRanges) });
      if (br && br.success && br.data) extraResult = br.data;
    } catch(e) {}

    var switchesData = extraResult['Switches!A:N'] || [];
    var freeExData = extraResult['FreeExchanges!A:J'] || [];
    var logCashbankData = extraResult['_log_cashbank!A:I'] || [];

    var salesUserData = {};
    for (var u = 0; u < users.length; u++) {
      var un = users[u];
      salesUserData[un] = {
        sheet: extraResult[un + '!A:I'] || [],
        gold: extraResult[un + '_Gold!A:F'] || []
      };
    }

    renderSalesStatus(users, salesUserData, closeData, logCashbankData, sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo);
    renderLRSummaryBoxes(sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo);
    renderLRPaymentSummary('lrSalesPayments', 'ยอดเงินที่ได้รับจากการขาย', ['SELL', 'TRADEIN', 'EXCHANGE', 'SWITCH', 'FREE_EXCHANGE', 'FREE-EX', 'WITHDRAW'], users, salesUserData, logCashbankData, dateFrom, dateTo);
    renderLRBuybackPayments(cashbankData, dateFrom, dateTo);
    renderLRStockSummary(sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo);
    renderLRGoldTable(stockMoveNewData, stockMoveOldData, dateFrom, dateTo);
  } catch(e) {
    console.error('loadLiveReport error:', e);
  }
}

function lrParseDate(dateVal) {
  if (!dateVal) return null;
  try {
    if (dateVal instanceof Date) return dateVal;
    if (typeof dateVal === 'number') return new Date((dateVal - 25569) * 86400 * 1000);
    var s = String(dateVal).trim();
    if (/^\d+(\.\d+)?$/.test(s)) {
      return new Date((parseFloat(s) - 25569) * 86400 * 1000);
    }
    if (s.includes('/')) {
      var parts = s.split(' ');
      var dp = parts[0].split('/');
      var day = parseInt(dp[0]), month = parseInt(dp[1]) - 1, year = parseInt(dp[2]);
      if (parts.length > 1 && parts[1] && parts[1].includes(':')) {
        var tp = parts[1].split(':');
        return new Date(year, month, day, parseInt(tp[0]) || 0, parseInt(tp[1]) || 0, parseInt(tp[2]) || 0);
      }
      return new Date(year, month, day);
    }
    var isoMatch = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (isoMatch) {
      return new Date(parseInt(isoMatch[1]), parseInt(isoMatch[2]) - 1, parseInt(isoMatch[3]));
    }
    var d = new Date(s);
    if (!isNaN(d.getTime())) return d;
    return null;
  } catch(e) { return null; }
}

function lrDateStr(d) {
  if (!d) return '';
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

function lrInRange(dateVal, dateFrom, dateTo) {
  if (!dateFrom && !dateTo) return true;
  var d = lrParseDate(dateVal);
  if (!d) return false;
  var ds = lrDateStr(d);
  if (dateFrom && ds < dateFrom) return false;
  if (dateTo && ds > dateTo) return false;
  return true;
}

function renderSalesStatus(users, salesUserData, closeData, logCashbankData, sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo) {
  var container = document.getElementById('lrSalesStatus');
  if (!container) return;
  var html = '';
  var weights = { 'G01': 150, 'G02': 75, 'G03': 30, 'G04': 15, 'G05': 7.5, 'G06': 3.75, 'G07': 1 };
  var products = ['G01','G02','G03','G04','G05','G06','G07'];
  window._lrSalesGold = {};
  window._lrSalesCash = {};

  for (var u = 0; u < users.length; u++) {
    var name = users[u];
    var ud = salesUserData[name];
    var isOpen = ud.sheet.length > 1 && ud.sheet[1] && ud.sheet[1][0] && String(ud.sheet[1][0]).trim() !== '';

    var shiftClosed = false;
    var closeRow = null;
    if (closeData && closeData.length > 1) {
      for (var ci = 1; ci < closeData.length; ci++) {
        var cu = String(closeData[ci][1] || '').trim();
        var cs = String(closeData[ci][8] || '').trim();
        if (cu !== name) continue;
        if (cs === 'PENDING' || cs === 'APPROVED') {
          try {
            var cd = lrParseDate(closeData[ci][2]);
            if (cd) {
              var cl = lrDateStr(cd);
              var today = getTodayLocalStr();
              if (cl === today) { shiftClosed = true; closeRow = closeData[ci]; break; }
            }
          } catch(e) {}
        }
      }
    }

    var statusText = shiftClosed ? '🔴 ปิดกะแล้ว' : (isOpen ? '🟢 เปิดกะอยู่' : '⚪ ยังไม่เปิดกะ');
    var statusColor = shiftClosed ? '#f44336' : (isOpen ? '#4caf50' : '#888');

    var sellCount = 0, sellLAK = 0, sellG = 0;
    var bbCount = 0, bbLAK = 0, bbG = 0;
    var wdCount = 0, wdLAK = 0, wdG = 0;

    if (sellsData && sellsData.length > 1) {
      for (var si = 1; si < sellsData.length; si++) {
        if (String(sellsData[si][11] || '') !== name) continue;
        if (String(sellsData[si][10] || '') !== 'COMPLETED') continue;
        if (!lrInRange(sellsData[si][9], dateFrom, dateTo)) continue;
        sellCount++;
        sellLAK += parseFloat(String(sellsData[si][3]).replace(/,/g, '')) || 0;
        try { var items = JSON.parse(sellsData[si][2]); items.forEach(function(it) { sellG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    }
    [tradeinsData, exchangesData].forEach(function(sheet) {
      if (!sheet || sheet.length <= 1) return;
      for (var ti = 1; ti < sheet.length; ti++) {
        if (String(sheet[ti][13] || '') !== name) continue;
        if (String(sheet[ti][12] || '') !== 'COMPLETED') continue;
        if (!lrInRange(sheet[ti][11], dateFrom, dateTo)) continue;
        sellCount++;
        sellLAK += parseFloat(String(sheet[ti][6]).replace(/,/g, '')) || 0;
        try { var nit = JSON.parse(sheet[ti][3]); nit.forEach(function(it) { sellG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    });
    if (switchesData && switchesData.length > 1) {
      for (var swi = 1; swi < switchesData.length; swi++) {
        if (String(switchesData[swi][13] || '') !== name) continue;
        if (String(switchesData[swi][12] || '') !== 'COMPLETED') continue;
        if (!lrInRange(switchesData[swi][11], dateFrom, dateTo)) continue;
        sellCount++;
        sellLAK += parseFloat(String(switchesData[swi][6]).replace(/,/g, '')) || 0;
        try { var nit2 = JSON.parse(switchesData[swi][3]); nit2.forEach(function(it) { sellG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    }
    if (freeExData && freeExData.length > 1) {
      for (var fi = 1; fi < freeExData.length; fi++) {
        if (String(freeExData[fi][9] || '') !== name) continue;
        if (String(freeExData[fi][8] || '') !== 'COMPLETED') continue;
        if (!lrInRange(freeExData[fi][7], dateFrom, dateTo)) continue;
        sellCount++;
        sellLAK += parseFloat(String(freeExData[fi][5]).replace(/,/g, '')) || 0;
        try { var nit3 = JSON.parse(freeExData[fi][3]); nit3.forEach(function(it) { sellG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    }
    if (withdrawsData && withdrawsData.length > 1) {
      for (var wi = 1; wi < withdrawsData.length; wi++) {
        if (String(withdrawsData[wi][8] || '') !== name) continue;
        if (String(withdrawsData[wi][7] || '') !== 'COMPLETED') continue;
        if (!lrInRange(withdrawsData[wi][6], dateFrom, dateTo)) continue;
        wdCount++;
        wdLAK += parseFloat(String(withdrawsData[wi][4]).replace(/,/g, '')) || 0;
        try { var wit = JSON.parse(withdrawsData[wi][2]); wit.forEach(function(it) { wdG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    }
    if (buybacksData && buybacksData.length > 1) {
      for (var bi = 1; bi < buybacksData.length; bi++) {
        var bbCreator = String(buybacksData[bi][11] || '').trim();
        if (bbCreator !== name) continue;
        var bbStatus = String(buybacksData[bi][10] || '').trim();
        if (bbStatus !== 'COMPLETED') continue;
        if (!lrInRange(buybacksData[bi][9], dateFrom, dateTo)) continue;
        bbCount++;
        bbLAK += parseFloat(String(buybacksData[bi][6]).replace(/,/g, '')) || 0;
        try { var bbit = JSON.parse(buybacksData[bi][2]); bbit.forEach(function(it) { bbG += (weights[it.productId] || 0) * it.qty; }); } catch(e) {}
      }
    }

    var cashLAK = 0, cashTHB = 0, cashUSD = 0;
    var oldGoldG = 0;

    if (shiftClosed) {
      if (closeRow) {
        cashLAK = parseFloat(closeRow[3]) || 0;
        cashTHB = parseFloat(closeRow[4]) || 0;
        cashUSD = parseFloat(closeRow[5]) || 0;
        try {
          var ogJson = closeRow[6];
          if (ogJson) {
            var ogParsed = typeof ogJson === 'string' ? JSON.parse(ogJson) : ogJson;
            if (Array.isArray(ogParsed)) {
              ogParsed.forEach(function(it) { oldGoldG += (weights[it.productId] || 0) * (it.qty || 0); });
            } else if (typeof ogParsed === 'object') {
              for (var gKey in ogParsed) {
                if (ogParsed.hasOwnProperty(gKey)) {
                  oldGoldG += (weights[gKey] || 0) * (parseFloat(ogParsed[gKey]) || 0);
                }
              }
            }
          }
        } catch(e) {}
      }
    } else if (isOpen) {
      for (var r = 1; r < ud.sheet.length; r++) {
        if (String(ud.sheet[r][4] || '').trim() === 'Cash') {
          var cur = String(ud.sheet[r][3] || '').trim();
          var amt = parseFloat(ud.sheet[r][2]) || 0;
          if (cur === 'LAK') cashLAK += amt;
          else if (cur === 'THB') cashTHB += amt;
          else if (cur === 'USD') cashUSD += amt;
        }
      }
      if (ud.gold.length > 1) {
        for (var gi = 1; gi < ud.gold.length; gi++) {
          var pid = String(ud.gold[gi][0] || '').trim();
          var qty = parseFloat(ud.gold[gi][1]) || 0;
          oldGoldG += (weights[pid] || 0) * qty;
        }
      }
    }

    var goldQty = {};
    products.forEach(function(p) { goldQty[p] = 0; });

    if (shiftClosed && closeRow) {
      try {
        var ogParsed = typeof closeRow[6] === 'string' ? JSON.parse(closeRow[6]) : closeRow[6];
        if (Array.isArray(ogParsed)) {
          ogParsed.forEach(function(it) { if (goldQty[it.productId] !== undefined) goldQty[it.productId] += (it.qty || 0); });
        } else if (typeof ogParsed === 'object' && ogParsed) {
          for (var gk in ogParsed) { if (goldQty[gk] !== undefined) goldQty[gk] += (parseFloat(ogParsed[gk]) || 0); }
        }
      } catch(e) {}
    } else if (isOpen && ud.gold.length > 1) {
      for (var gi = 1; gi < ud.gold.length; gi++) {
        var pid = String(ud.gold[gi][0] || '').trim();
        var qty = parseFloat(ud.gold[gi][1]) || 0;
        if (goldQty[pid] !== undefined) goldQty[pid] += qty;
      }
    }
    window._lrSalesGold[name] = goldQty;
    window._lrSalesCash[name] = { LAK: cashLAK, THB: cashTHB, USD: cashUSD };

    html += '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:12px;">';
    html += '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:' + (isOpen || shiftClosed ? '10' : '0') + 'px;">';
    html += '<span style="font-weight:700;font-size:16px;color:var(--gold-primary);">' + name + '</span>';
    html += '<div style="display:flex;gap:10px;align-items:center;">';
    if (isOpen || shiftClosed) {
      html += '<button onclick="showLROldGoldModal(\'' + name.replace(/'/g, "\\'") + '\')" style="background:var(--gold-primary);color:#000;border:none;border-radius:6px;padding:4px 12px;font-size:12px;font-weight:600;cursor:pointer;">View ทองเก่า</button>';
    }
    html += '<span style="font-size:13px;color:' + statusColor + ';font-weight:600;">' + statusText + '</span>';
    html += '</div></div>';
    if (isOpen || shiftClosed) {
      html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;font-size:13px;">';
      if (isOpen) {
        html += '<div><span style="color:var(--text-secondary);">Sales:</span> ' + formatNumber(sellLAK) + ' LAK | ' + sellG.toFixed(2) + 'g | ' + sellCount + ' บิล</div>';
        html += '<div><span style="color:var(--text-secondary);">Withdraw:</span> ' + formatNumber(wdLAK) + ' LAK | ' + wdG.toFixed(2) + 'g | ' + wdCount + ' บิล</div>';
        html += '<div><span style="color:var(--text-secondary);">Buyback:</span> ' + formatNumber(bbLAK) + ' LAK | ' + bbG.toFixed(2) + 'g | ' + bbCount + ' บิล</div>';
      }
      html += '<div><span style="color:var(--text-secondary);">เงินสด:</span> ' + formatNumber(cashLAK) + ' LAK | ' + formatNumber(cashTHB) + ' THB | ' + formatNumber(cashUSD) + ' USD</div>';
      html += '<div><span style="color:var(--text-secondary);">ทองเก่า:</span> ' + oldGoldG.toFixed(2) + ' g</div>';
      html += '</div>';
    }
    html += '</div>';
  }

  container.innerHTML = html || '<div style="text-align:center;color:var(--text-secondary);padding:20px;">ไม่พบข้อมูล Sales</div>';
}

function renderLRSummaryBoxes(sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo) {
  var weights = { 'G01': 150, 'G02': 75, 'G03': 30, 'G04': 15, 'G05': 7.5, 'G06': 3.75, 'G07': 1 };

  function calcG(itemsJson) {
    var g = 0;
    try { var it = typeof itemsJson === 'string' ? JSON.parse(itemsJson) : itemsJson; it.forEach(function(x) { g += (weights[x.productId] || 0) * x.qty; }); } catch(e) {}
    return g;
  }

  function filterRows(data, statusCol, dateCol, statuses) {
    if (!data || data.length <= 1) return [];
    return data.slice(1).filter(function(r) {
      var st = String(r[statusCol] || '').trim();
      return statuses.indexOf(st) !== -1 && lrInRange(r[dateCol], dateFrom, dateTo);
    });
  }

  var sellRows = filterRows(sellsData, 10, 9, ['COMPLETED', 'PAID']);
  var tradeinRows = filterRows(tradeinsData, 12, 11, ['COMPLETED', 'PAID']);
  var exchangeRows = filterRows(exchangesData, 12, 11, ['COMPLETED', 'PAID']);
  var switchRows = filterRows(switchesData, 12, 11, ['COMPLETED', 'PAID']);
  var freeExRows = filterRows(freeExData, 8, 7, ['COMPLETED', 'PAID']);
  var buybackRows = filterRows(buybacksData, 10, 9, ['COMPLETED', 'PAID']);
  var withdrawRows = filterRows(withdrawsData, 7, 6, ['COMPLETED', 'PAID']);

  var sellMoney = 0; sellRows.forEach(function(r) { sellMoney += parseFloat(r[3]) || 0; });
  var tradeinMoney = 0; tradeinRows.forEach(function(r) { tradeinMoney += parseFloat(r[6]) || 0; });
  var exchangeMoney = 0; exchangeRows.forEach(function(r) { exchangeMoney += parseFloat(r[6]) || 0; });
  var switchMoney = 0; switchRows.forEach(function(r) { switchMoney += parseFloat(r[6]) || 0; });
  var freeExMoney = 0; freeExRows.forEach(function(r) { freeExMoney += parseFloat(r[5]) || 0; });

  var salesTotal = sellMoney + tradeinMoney + exchangeMoney + switchMoney + freeExMoney;
  var salesTotalTx = sellRows.length + tradeinRows.length + exchangeRows.length + switchRows.length + freeExRows.length;

  var salesOldGIn = 0, salesNewGOut = 0;
  sellRows.forEach(function(r) { salesNewGOut += calcG(r[2]); });
  tradeinRows.forEach(function(r) { salesOldGIn += calcG(r[2]); salesNewGOut += calcG(r[3]); });
  exchangeRows.forEach(function(r) { salesOldGIn += calcG(r[2]); salesNewGOut += calcG(r[3]); });
  switchRows.forEach(function(r) { salesOldGIn += calcG(r[2]); salesNewGOut += calcG(r[3]); });
  freeExRows.forEach(function(r) { salesOldGIn += calcG(r[2]); salesNewGOut += calcG(r[3]); });

  var bbMoney = 0; buybackRows.forEach(function(r) { bbMoney += parseFloat(r[6]) || parseFloat(r[3]) || 0; });
  var bbOldGIn = 0; buybackRows.forEach(function(r) { bbOldGIn += calcG(r[2]); });

  var wdMoney = 0; withdrawRows.forEach(function(r) { wdMoney += parseFloat(r[4]) || 0; });
  var wdNewGOut = 0; withdrawRows.forEach(function(r) { wdNewGOut += calcG(r[2]); });

  var totalOldGIn = salesOldGIn + bbOldGIn;
  var totalNewGOut = salesNewGOut + wdNewGOut;
  var netSellBaht = (totalNewGOut - totalOldGIn) / 15;

  var salesGoldBaht = (salesNewGOut - salesOldGIn) / 15;
  var salesTotalPerBaht = salesGoldBaht > 0 ? Math.round(salesTotal / salesGoldBaht) : 0;

  var bbGoldBaht = bbOldGIn / 15;
  var bbTotalPerBaht = bbGoldBaht > 0 ? Math.round(bbMoney / bbGoldBaht) : 0;

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
  html += 'Sell: ' + formatNumber(Math.round(sellMoney)) + ' (' + sellRows.length + ')<br>';
  html += 'Trade-in: ' + formatNumber(Math.round(tradeinMoney)) + ' (' + tradeinRows.length + ')<br>';
  html += 'Exchange: ' + formatNumber(Math.round(exchangeMoney)) + ' (' + exchangeRows.length + ')';
  if (switchRows.length > 0) html += '<br>Switch: ' + formatNumber(Math.round(switchMoney)) + ' (' + switchRows.length + ')';
  if (freeExRows.length > 0) html += '<br>Free-Ex: ' + formatNumber(Math.round(freeExMoney)) + ' (' + freeExRows.length + ')';
  html += '</div>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#ff9800;">◀ Old In: ' + salesOldGIn.toFixed(2) + ' g</span><br>';
  html += '<span style="color:#4caf50;">▶ New Out: ' + salesNewGOut.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">🔄 BUYBACK</h3>';
  html += '<p style="font-size:18px;margin:3px 0;font-weight:bold;">Total: ' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:12px;">LAK</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">GOLD Amount: <b>' + bbGoldBaht.toFixed(3) + '</b> <span style="font-size:11px;">บาท</span></p>';
  html += '<p style="font-size:13px;margin:3px 0;">Total/Amount: <b>' + formatNumber(bbTotalPerBaht) + '</b> <span style="font-size:11px;">LAK/บาท</span></p>';
  html += '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + buybackRows.length + '</b></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#ff9800;">◀ Old In: ' + bbOldGIn.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '<div style="' + boxStyle + '">';
  html += '<h3 style="color:var(--gold-primary);margin-bottom:8px;">📤 WITHDRAW</h3>';
  html += '<p style="font-size:18px;margin:3px 0;font-weight:bold;">' + formatNumber(Math.round(wdMoney)) + ' <span style="font-size:12px;">LAK</span></p>';
  html += '<p style="font-size:11px;color:var(--text-secondary);margin:2px 0;">Tx: <b>' + withdrawRows.length + '</b></p>';
  html += '<div style="border-top:1px solid var(--border-color);margin:6px 0;padding-top:6px;font-size:12px;">';
  html += '<span style="color:#4caf50;">▶ New Out: ' + wdNewGOut.toFixed(2) + ' g</span>';
  html += '</div></div>';

  html += '</div>';
  document.getElementById('lrSummaryBoxes').innerHTML = html;
}

function renderLRPaymentSummary(containerId, title, types, users, salesUserData, logCashbankData, dateFrom, dateTo) {
  var container = document.getElementById(containerId);
  if (!container) return;

  var methods = ['Cash', 'BCEL', 'LDB', 'Other'];
  var currencies = ['LAK', 'THB', 'USD'];
  var totals = {};
  methods.forEach(function(m) {
    totals[m] = {};
    currencies.forEach(function(c) { totals[m][c] = 0; });
  });

  function processRows(data) {
    if (!data || data.length <= 1) return;
    for (var r = 1; r < data.length; r++) {
      var row = data[r];
      var rType = String(row[1] || '').trim();
      var baseType = rType.replace('_CHANGE', '');
      var matched = false;
      for (var t = 0; t < types.length; t++) {
        if (baseType === types[t]) { matched = true; break; }
      }
      if (!matched) continue;
      if (!lrInRange(row[7], dateFrom, dateTo)) continue;
      var amt = parseFloat(row[2]) || 0;
      var cur = String(row[3] || '').trim();
      var method = String(row[4] || '').trim();
      var bank = String(row[5] || '').trim();

      var key = 'Cash';
      if (method === 'Bank') {
        if (bank === 'BCEL') key = 'BCEL';
        else if (bank === 'LDB') key = 'LDB';
        else key = 'Other';
      }
      if (currencies.indexOf(cur) >= 0 && totals[key]) {
        totals[key][cur] += amt;
      }
    }
  }

  for (var u = 0; u < users.length; u++) {
    var ud = salesUserData[users[u]];
    if (ud && ud.sheet && ud.sheet.length > 1) {
      processRows(ud.sheet);
    }
  }

  if (logCashbankData && logCashbankData.length > 1) {
    processRows(logCashbankData);
  }

  var thStyle = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.5);padding:10px 8px;font-size:12px;text-align:center;font-weight:700;';
  var tdStyle = 'border:1px solid var(--border-color);padding:8px;text-align:right;font-size:13px;';

  var html = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:20px;">';
  html += '<h3 style="color:var(--gold-primary);font-size:16px;margin-bottom:12px;">' + title + '</h3>';
  html += '<div class="table-container"><table><thead><tr>';
  html += '<th style="' + thStyle + '">ช่องทาง</th>';
  currencies.forEach(function(c) { html += '<th style="' + thStyle + '">' + c + '</th>'; });
  html += '</tr></thead><tbody>';

  var grandTotal = {};
  currencies.forEach(function(c) { grandTotal[c] = 0; });

  methods.forEach(function(m) {
    html += '<tr>';
    html += '<td style="' + tdStyle + 'text-align:left;font-weight:600;">' + m + '</td>';
    currencies.forEach(function(c) {
      var val = totals[m][c];
      grandTotal[c] += val;
      var color = val > 0 ? '#4caf50' : (val < 0 ? '#f44336' : 'var(--text-secondary)');
      html += '<td style="' + tdStyle + 'color:' + color + ';">' + formatCurrency(val, c) + '</td>';
    });
    html += '</tr>';
  });

  html += '<tr style="background:rgba(212,175,55,0.1);font-weight:700;">';
  html += '<td style="' + tdStyle + 'text-align:left;color:var(--gold-primary);">รวม</td>';
  currencies.forEach(function(c) {
    var val = grandTotal[c];
    var color = val > 0 ? '#4caf50' : (val < 0 ? '#f44336' : 'var(--text-secondary)');
    html += '<td style="' + tdStyle + 'color:' + color + ';font-weight:700;">' + formatCurrency(val, c) + '</td>';
  });
  html += '</tr>';
  html += '</tbody></table></div></div>';

  container.innerHTML = html;
}

function renderLRBuybackPayments(cashbankData, dateFrom, dateTo) {
  var container = document.getElementById('lrBuybackPayments');
  if (!container) return;

  var methods = ['Cash', 'BCEL', 'LDB', 'Other'];
  var currencies = ['LAK', 'THB', 'USD'];
  var totals = {};
  var feeTotals = {};
  methods.forEach(function(m) {
    totals[m] = {};
    feeTotals[m] = {};
    currencies.forEach(function(c) { totals[m][c] = 0; feeTotals[m][c] = 0; });
  });

  if (cashbankData && cashbankData.length > 1) {
    for (var i = 1; i < cashbankData.length; i++) {
      var row = cashbankData[i];
      var type = String(row[1] || '').trim();
      if (type !== 'BUYBACK' && type !== 'BUYBACK_FEE') continue;
      if (!lrInRange(row[7], dateFrom, dateTo)) continue;

      var amt = Math.abs(parseFloat(row[2]) || 0);
      var cur = String(row[3] || '').trim();
      var method = String(row[4] || '').trim();
      var bank = String(row[5] || '').trim();

      var key = 'Cash';
      if (method === 'Bank') {
        if (bank === 'BCEL') key = 'BCEL';
        else if (bank === 'LDB') key = 'LDB';
        else key = 'Other';
      }

      if (currencies.indexOf(cur) >= 0) {
        if (type === 'BUYBACK') totals[key][cur] += amt;
        else if (type === 'BUYBACK_FEE') feeTotals[key][cur] += amt;
      }
    }
  }

  var thStyle = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.5);padding:10px 8px;font-size:12px;text-align:center;font-weight:700;';
  var tdStyle = 'border:1px solid var(--border-color);padding:8px;text-align:right;font-size:13px;';

  var html = '<div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:16px;margin-bottom:20px;">';
  html += '<h3 style="color:var(--gold-primary);font-size:16px;margin-bottom:12px;">ยอดเงินที่จ่าย Buyback</h3>';
  html += '<div class="table-container"><table><thead><tr>';
  html += '<th style="' + thStyle + '">ช่องทาง</th>';
  currencies.forEach(function(c) { html += '<th style="' + thStyle + '">' + c + '</th>'; });
  html += '</tr></thead><tbody>';

  var grandTotal = {};
  currencies.forEach(function(c) { grandTotal[c] = 0; });

  methods.forEach(function(m) {
    html += '<tr>';
    html += '<td style="' + tdStyle + 'text-align:left;font-weight:600;">' + m + '</td>';
    currencies.forEach(function(c) {
      var val = totals[m][c];
      grandTotal[c] += val;
      var color = val > 0 ? '#f44336' : 'var(--text-secondary)';
      html += '<td style="' + tdStyle + 'color:' + color + ';">' + formatCurrency(val, c) + '</td>';
    });
    html += '</tr>';
  });

  var hasFee = false;
  var feeGrand = {};
  currencies.forEach(function(c) { feeGrand[c] = 0; });
  methods.forEach(function(m) {
    currencies.forEach(function(c) { feeGrand[c] += feeTotals[m][c]; if (feeTotals[m][c] > 0) hasFee = true; });
  });

  if (hasFee) {
    html += '<tr style="border-top:2px solid var(--border-color);">';
    html += '<td style="' + tdStyle + 'text-align:left;font-weight:600;color:#ff9800;">Fee</td>';
    currencies.forEach(function(c) {
      var val = feeGrand[c];
      var color = val > 0 ? '#ff9800' : 'var(--text-secondary)';
      html += '<td style="' + tdStyle + 'color:' + color + ';">' + formatCurrency(val, c) + '</td>';
    });
    html += '</tr>';
  }

  html += '<tr style="background:rgba(212,175,55,0.1);font-weight:700;">';
  html += '<td style="' + tdStyle + 'text-align:left;color:var(--gold-primary);">รวม</td>';
  currencies.forEach(function(c) {
    var val = grandTotal[c] + feeGrand[c];
    var color = val > 0 ? '#f44336' : 'var(--text-secondary)';
    html += '<td style="' + tdStyle + 'color:' + color + ';font-weight:700;">' + formatCurrency(val, c) + '</td>';
  });
  html += '</tr>';
  html += '</tbody></table></div></div>';

  container.innerHTML = html;
}

function renderLRStockSummary(sellsData, tradeinsData, exchangesData, switchesData, freeExData, buybacksData, withdrawsData, dateFrom, dateTo) {
  var container = document.getElementById('lrStockSummary');
  if (!container) return;
  var weights = { 'G01': 150, 'G02': 75, 'G03': 30, 'G04': 15, 'G05': 7.5, 'G06': 3.75, 'G07': 1 };
  var newOutG = 0, oldInG = 0;

  function sumNewOut(data, itemsCol, statusCol, dateCol, statuses) {
    if (!data || data.length <= 1) return 0;
    var g = 0;
    for (var i = 1; i < data.length; i++) {
      if (statuses.indexOf(String(data[i][statusCol] || '').trim()) === -1) continue;
      if (!lrInRange(data[i][dateCol], dateFrom, dateTo)) continue;
      try { var it = JSON.parse(data[i][itemsCol]); it.forEach(function(x) { g += (weights[x.productId] || 0) * x.qty; }); } catch(e) {}
    }
    return g;
  }

  newOutG += sumNewOut(sellsData, 2, 10, 9, ['COMPLETED']);
  newOutG += sumNewOut(tradeinsData, 3, 12, 11, ['COMPLETED']);
  newOutG += sumNewOut(exchangesData, 3, 12, 11, ['COMPLETED']);
  newOutG += sumNewOut(switchesData, 3, 12, 11, ['COMPLETED']);
  newOutG += sumNewOut(freeExData, 3, 8, 7, ['COMPLETED']);
  newOutG += sumNewOut(withdrawsData, 2, 7, 6, ['COMPLETED']);

  function sumOldIn(data, itemsCol, statusCol, dateCol, statuses) {
    if (!data || data.length <= 1) return 0;
    var g = 0;
    for (var i = 1; i < data.length; i++) {
      if (statuses.indexOf(String(data[i][statusCol] || '').trim()) === -1) continue;
      if (!lrInRange(data[i][dateCol], dateFrom, dateTo)) continue;
      try { var it = JSON.parse(data[i][itemsCol]); it.forEach(function(x) { g += (weights[x.productId] || 0) * x.qty; }); } catch(e) {}
    }
    return g;
  }
  oldInG += sumOldIn(tradeinsData, 2, 12, 11, ['COMPLETED']);
  oldInG += sumOldIn(exchangesData, 2, 12, 11, ['COMPLETED']);
  oldInG += sumOldIn(switchesData, 2, 12, 11, ['COMPLETED']);
  oldInG += sumOldIn(freeExData, 2, 8, 7, ['COMPLETED']);
  oldInG += sumOldIn(buybacksData, 2, 10, 9, ['COMPLETED']);

  var boxStyle = 'background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:12px;padding:20px;text-align:center;';
  var html = '<div style="display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-bottom:20px;">';
  html += '<div style="' + boxStyle + '"><div style="color:var(--text-secondary);font-size:12px;margin-bottom:8px;">NEW OUT (ทองใหม่ออก)</div><div style="font-size:24px;font-weight:700;color:#f44336;">' + newOutG.toFixed(2) + ' g</div></div>';
  html += '<div style="' + boxStyle + '"><div style="color:var(--text-secondary);font-size:12px;margin-bottom:8px;">OLD IN (ทองเก่ารับเข้า)</div><div style="font-size:24px;font-weight:700;color:#4caf50;">' + oldInG.toFixed(2) + ' g</div></div>';
  html += '</div>';
  container.innerHTML = html;
}

function renderLRGoldTable(stockMoveNewData, stockMoveOldData, dateFrom, dateTo) {
  var container = document.getElementById('lrGoldTable');
  if (!container) return;
  var products = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06', 'G07'];
  var names = { 'G01': '10 บาท', 'G02': '5 บาท', 'G03': '2 บาท', 'G04': '1 บาท', 'G05': '2 สลึง', 'G06': '1 สลึง', 'G07': '1 กรัม' };
  var newOut = {}, newIn = {}, oldOut = {}, oldIn = {};
  products.forEach(function(p) { newOut[p] = 0; newIn[p] = 0; oldOut[p] = 0; oldIn[p] = 0; });

  function parseMove(data, outMap, inMap) {
    if (!data || data.length <= 1) return;
    for (var i = 1; i < data.length; i++) {
      if (!lrInRange(data[i][0], dateFrom, dateTo)) continue;
      var dir = String(data[i][5] || '').trim();
      try {
        var items = typeof data[i][3] === 'string' ? JSON.parse(data[i][3]) : data[i][3];
        if (!Array.isArray(items)) continue;
        items.forEach(function(x) {
          if (dir === 'OUT' && outMap[x.productId] !== undefined) outMap[x.productId] += (x.qty || 0);
          if (dir === 'IN' && inMap[x.productId] !== undefined) inMap[x.productId] += (x.qty || 0);
        });
      } catch(e) {}
    }
  }

  parseMove(stockMoveNewData, newOut, newIn);
  parseMove(stockMoveOldData, oldOut, oldIn);

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

function showLROldGoldModal(salesName) {
  var modal = document.getElementById('lrOldGoldModal');
  var title = document.getElementById('lrOldGoldTitle');
  var content = document.getElementById('lrOldGoldContent');
  if (!modal || !content) return;

  title.textContent = 'รายละเอียด — ' + salesName;

  var cashData = (window._lrSalesCash && window._lrSalesCash[salesName]) || { LAK: 0, THB: 0, USD: 0 };
  var html = '<div style="margin-bottom:16px;padding:14px;background:rgba(76,175,80,0.08);border-radius:8px;border:1px solid rgba(76,175,80,0.2);">';
  html += '<div style="font-size:13px;color:#4caf50;font-weight:700;margin-bottom:10px;">💵 สรุปเงินทั้งหมด</div>';
  html += '<table style="width:100%;border-collapse:collapse;">';
  var thC = 'background:#2d2d2d;color:#4caf50;border:1px solid rgba(76,175,80,0.3);padding:8px 12px;font-size:12px;font-weight:700;';
  html += '<thead><tr><th style="' + thC + 'text-align:left;">ประเภท</th><th style="' + thC + 'text-align:center;">LAK</th><th style="' + thC + 'text-align:center;">THB</th><th style="' + thC + 'text-align:center;">USD</th></tr></thead><tbody>';
  html += '<tr><td style="padding:8px 12px;font-size:13px;font-weight:600;">💵 Cash</td>';
  html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#4caf50;font-weight:600;">' + formatNumber(cashData.LAK) + '</td>';
  html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#2196f3;font-weight:600;">' + formatCurrency(cashData.THB, 'THB') + '</td>';
  html += '<td style="padding:8px 12px;text-align:center;font-size:13px;color:#ff9800;font-weight:600;">' + formatCurrency(cashData.USD, 'USD') + '</td>';
  html += '</tr></tbody></table></div>';

  var goldQty = (window._lrSalesGold && window._lrSalesGold[salesName]) || {};
  var products = ['G01','G02','G03','G04','G05','G06','G07'];
  var pNames = {'G01':'10 บาท','G02':'5 บาท','G03':'2 บาท','G04':'1 บาท','G05':'2 สลึง','G06':'1 สลึง','G07':'1 กรัม'};

  html += '<div style="font-size:13px;color:var(--gold-primary);font-weight:700;margin-bottom:10px;">◀ ทองเก่าที่ได้รับ</div>';
  var thS = 'background:#2d2d2d;color:#d4af37;border:1px solid rgba(212,175,55,0.3);padding:10px 12px;font-size:12px;font-weight:700;text-transform:uppercase;';
  html += '<table style="width:100%;border-collapse:collapse;">';
  html += '<thead><tr><th style="' + thS + 'text-align:left;">Product</th><th style="' + thS + 'text-align:center;">Unit</th></tr></thead><tbody>';
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

    var sheetName = currentUser.nickname;

    var s1b = currentPricing.sell1Baht || 0;
    var sellPrice = calculateSellPrice('G04', s1b);
    var buybackPrice = calculateBuybackPrice('G04', s1b);

    document.getElementById('siSellPrice').textContent = formatNumber(sellPrice);
    document.getElementById('siBuybackPrice').textContent = formatNumber(buybackPrice);
    document.getElementById('siThbSell').textContent = formatNumber(currentExchangeRates.THB_Sell || 0);
    document.getElementById('siUsdSell').textContent = formatNumber(currentExchangeRates.USD_Sell || 0);
    document.getElementById('siThbBuy').textContent = formatNumber(currentExchangeRates.THB_Buy || 0);
    document.getElementById('siUsdBuy').textContent = formatNumber(currentExchangeRates.USD_Buy || 0);

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
    'body { font-family: "Segoe UI", Arial, sans-serif; padding: 15mm 12mm; background: #fff; color: #333; font-size: 13px; line-height: 1.5; }',
    '.print-header { text-align: center; border-bottom: 3px solid #b8860b; padding-bottom: 20px; margin-bottom: 30px; }',
    '.print-header h1 { color: #b8860b; font-size: 28px; font-weight: 700; letter-spacing: 2px; margin-bottom: 4px; }',
    '.print-header .subtitle { color: #666; font-size: 13px; }',
    '.print-section { margin-bottom: 25px; page-break-inside: avoid; }',
    'h3 { color: #b8860b !important; font-size: 15px; margin-bottom: 12px; padding-bottom: 6px; border-bottom: 1px solid #e0c878; }',
    'table { width: 100%; border-collapse: collapse; margin-bottom: 15px; font-size: 12px; page-break-inside: avoid; }',
    'thead th { background: #b8860b !important; color: #fff !important; border: 1px solid #a07730; padding: 10px 8px; font-size: 11px; text-align: center; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; }',
    'tbody td { border: 1px solid #ddd; padding: 8px; text-align: center; color: #333 !important; }',
    'tbody tr:nth-child(even) { background: #fafafa; }',
    'tbody tr:last-child { font-weight: 700; background: #fff8e1 !important; }',
    'div[style*="background:var(--bg-secondary)"], div[style*="background:#1a1a1a"], div[style*="background: var(--bg-secondary)"] { background: #fff !important; border: 1px solid #e0c878 !important; border-radius: 10px; padding: 16px; margin-bottom: 16px; page-break-inside: avoid; }',
    'div[style*="display:grid"], div[style*="display: grid"] { display: grid !important; gap: 12px !important; }',
    'div[style*="grid-template-columns: repeat(4"], div[style*="grid-template-columns:repeat(4"] { grid-template-columns: repeat(4, 1fr) !important; }',
    'div[style*="grid-template-columns: repeat(2"], div[style*="grid-template-columns:repeat(2"] { grid-template-columns: repeat(2, 1fr) !important; }',
    'div[style*="grid-template-columns: 1fr 1fr"], div[style*="grid-template-columns:1fr 1fr"] { grid-template-columns: 1fr 1fr !important; }',
    '.table-container { overflow: visible !important; margin: 0 !important; padding: 0 !important; }',
    'p, span, div { color: #333 !important; }',
    'span[style*="color:#4caf50"], span[style*="color: #4caf50"] { color: #2e7d32 !important; }',
    'span[style*="color:#f44336"], span[style*="color: #f44336"] { color: #c62828 !important; }',
    'span[style*="color:#2196f3"], span[style*="color: #2196f3"] { color: #1565c0 !important; }',
    'span[style*="color:#ff9800"], span[style*="color: #ff9800"] { color: #e65100 !important; }',
    'td[style*="color:#4caf50"], td[style*="color: #4caf50"] { color: #2e7d32 !important; }',
    'td[style*="color:#f44336"], td[style*="color: #f44336"] { color: #c62828 !important; }',
    'td[style*="color:var(--gold-primary)"] { color: #b8860b !important; }',
    'div[style*="background:rgba(212,175,55"] { background: #fff8e1 !important; }',
    '@media print { @page { margin: 0; size: A4; } .print-section { page-break-inside: avoid; } table { page-break-inside: avoid; } h3 { page-break-after: avoid; } .print-tip { display: none !important; } }'
  ].join('\n');

  var printWin = window.open('', '_blank');
  printWin.document.write('<!DOCTYPE html><html><head><title>KPV GOLD - Report</title>');
  printWin.document.write('<style>' + css + '</style></head><body>');
  printWin.document.write('<div class="print-header">');
  printWin.document.write('<h1>KPV GOLD</h1>');
  printWin.document.write('<div class="subtitle">Live Report: ' + (dateFrom || '-') + ' to ' + (dateTo || '-') + ' | Printed: ' + new Date().toLocaleString() + '</div>');
  printWin.document.write('</div>');
  printWin.document.write('<div class="print-tip" style="background:#fff3cd;border:1px solid #ffc107;border-radius:8px;padding:12px 16px;margin-bottom:20px;font-size:12px;color:#856404;">⚠️ ตอน Print/Save PDF กรุณาตั้ง <b>Margins</b> เป็น <b>"Default"</b> หรือ <b>"Minimum"</b></div>');
  printWin.document.write(contentHtml);
  printWin.document.write('</body></html>');
  printWin.document.close();
  setTimeout(function() { printWin.print(); }, 500);
}