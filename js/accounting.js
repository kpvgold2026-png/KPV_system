var accNetSellChartInstance = null;
var _accDateFrom = null;
var _accDateTo = null;

function calcGold(itemsStr) {
  var total = 0;
  try {
    JSON.parse(itemsStr).forEach(function(item) {
      total += getGoldWeight(item.productId) * item.qty;
    });
  } catch(e) {}
  return total;
}

function calcNetSellBahtForRows(sellRows, tradeinRows, exchangeRows, buybackRows, withdrawRows) {
  var salesOldGIn = 0, salesNewGOut = 0;
  sellRows.forEach(function(r) { salesNewGOut += calcGold(r[2]); });
  tradeinRows.forEach(function(r) { salesOldGIn += calcGold(r[2]); salesNewGOut += calcGold(r[3]); });
  exchangeRows.forEach(function(r) { salesOldGIn += calcGold(r[2]); salesNewGOut += calcGold(r[3]); });
  var bbOldGIn = 0;
  buybackRows.forEach(function(r) { bbOldGIn += calcGold(r[2]); });
  var wdNewGOut = 0;
  withdrawRows.forEach(function(r) { wdNewGOut += calcGold(r[2]); });
  var totalOldGIn = salesOldGIn + bbOldGIn;
  var totalNewGOut = salesNewGOut + wdNewGOut;
  return { netBaht: (totalNewGOut - totalOldGIn) / 15, totalNewGOut: totalNewGOut, totalOldGIn: totalOldGIn };
}

function accFilterRows(rows, dateCol, statusCol, dayStart, dayEnd) {
  return rows.filter(function(r) {
    var d = parseSheetDate(r[dateCol]);
    if (!d || d < dayStart || d > dayEnd) return false;
    var st = r[statusCol];
    return st === 'COMPLETED' || st === 'PAID';
  });
}

async function loadAccounting() {
  try {
    showLoading();
    var today = new Date();
    if (!_accDateFrom || !_accDateTo) {
      var td = today.getFullYear() + '-' + String(today.getMonth()+1).padStart(2,'0') + '-' + String(today.getDate()).padStart(2,'0');
      _accDateFrom = td;
      _accDateTo = td;
    }
    document.getElementById('accDateFrom').value = _accDateFrom;
    document.getElementById('accDateTo').value = _accDateTo;

    var results = await Promise.all([
      fetchSheetData('Sells!A:L'),
      fetchSheetData('Tradeins!A:N'),
      fetchSheetData('Exchanges!A:T'),
      fetchSheetData('Buybacks!A:L'),
      fetchSheetData('Withdraws!A:J'),
      fetchSheetData('CashBank!A:I'),
      fetchSheetData('_database!A1:G31'),
      fetchSheetData('Diff!A:J')
    ]);

    var sells = results[0], tradeins = results[1], exchanges = results[2];
    var buybacks = results[3], withdraws = results[4];
    var cashbankData = results[5], dbData = results[6], diffData = results[7];

    var fromParts = _accDateFrom.split('-');
    var toParts = _accDateTo.split('-');
    var dayStart = new Date(parseInt(fromParts[0]), parseInt(fromParts[1])-1, parseInt(fromParts[2]), 0, 0, 0);
    var dayEnd = new Date(parseInt(toParts[0]), parseInt(toParts[1])-1, parseInt(toParts[2]), 23, 59, 59);

    var wacPerG = 0;
    if (dbData.length >= 31) {
      var _nG = parseFloat(dbData[30][0]) || 0, _nV = parseFloat(dbData[30][1]) || 0;
      var _oG = parseFloat(dbData[30][2]) || 0, _oV = parseFloat(dbData[30][3]) || 0;
      var _tG = _nG + _oG, _tC = _oV + _nV;
      if (_tG > 0) wacPerG = _tC / _tG;
    }

    var sell = { newGoldG: 0, txCount: 0 };
    var tradein = { newGoldG: 0, oldGoldG: 0, moneyNoP: 0, txCount: 0 };
    var exchange = { newGoldG: 0, oldGoldG: 0, txCount: 0 };
    var wd = { newGoldG: 0, txCount: 0 };
    var bb = { oldGoldG: 0, txCount: 0 };
    var otherExpenseLAK = 0;
    var incomplete = { money: 0, gold: 0 };

    sells.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[9]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[10] === 'COMPLETED') { sell.txCount++; try { JSON.parse(row[2]).forEach(function(item) { sell.newGoldG += getGoldWeight(item.productId) * item.qty; }); } catch(e) {} }
        else if (row[10] !== 'REJECTED') { incomplete.money += parseFloat(row[3]) || 0; incomplete.gold += calcGold(row[2]); }
      }
    });

    tradeins.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[11]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[12] === 'COMPLETED') {
          tradein.txCount++; tradein.moneyNoP += (parseFloat(row[4]) || 0) + (parseFloat(row[5]) || 0);
          try { JSON.parse(row[2]).forEach(function(item) { tradein.oldGoldG += getGoldWeight(item.productId) * item.qty; }); JSON.parse(row[3]).forEach(function(item) { tradein.newGoldG += getGoldWeight(item.productId) * item.qty; }); } catch(e) {}
        } else if (row[12] !== 'REJECTED') { incomplete.money += (parseFloat(row[4]) || 0) + (parseFloat(row[5]) || 0) + (parseFloat(row[6]) || 0); incomplete.gold += calcGold(row[3]); }
      }
    });

    exchanges.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[11]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[12] === 'COMPLETED') { exchange.txCount++; try { JSON.parse(row[2]).forEach(function(item) { exchange.oldGoldG += getGoldWeight(item.productId) * item.qty; }); JSON.parse(row[3]).forEach(function(item) { exchange.newGoldG += getGoldWeight(item.productId) * item.qty; }); } catch(e) {} }
        else if (row[12] !== 'REJECTED') { incomplete.money += parseFloat(row[6]) || 0; incomplete.gold += calcGold(row[3]); }
      }
    });

    buybacks.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[9]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[10] === 'COMPLETED' || row[10] === 'PAID') { bb.txCount++; try { JSON.parse(row[2]).forEach(function(item) { bb.oldGoldG += getGoldWeight(item.productId) * item.qty; }); } catch(e) {} }
        else if (row[10] !== 'REJECTED') { incomplete.money += parseFloat(row[6]) || 0; incomplete.gold += calcGold(row[2]); }
      }
    });

    withdraws.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[6]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[7] === 'COMPLETED') { wd.txCount++; try { JSON.parse(row[2]).forEach(function(item) { wd.newGoldG += getGoldWeight(item.productId) * item.qty; }); } catch(e) {} }
        else if (row[7] !== 'REJECTED') { incomplete.money += parseFloat(row[4]) || 0; incomplete.gold += calcGold(row[2]); }
      }
    });

    cashbankData.slice(1).forEach(function(row) {
      var date = parseSheetDate(row[7]);
      if (date && date >= dayStart && date <= dayEnd) {
        if (row[1] === 'OTHER_EXPENSE') { var amt = parseFloat(row[2]) || 0; var cur = row[3]; if (cur === 'THB') amt = amt * (currentExchangeRates?.THB_Sell || 0); else if (cur === 'USD') amt = amt * (currentExchangeRates?.USD_Sell || 0); otherExpenseLAK += Math.abs(amt); }
      }
    });

    var fS = accFilterRows(sells.slice(1), 9, 10, dayStart, dayEnd);
    var fT = accFilterRows(tradeins.slice(1), 11, 12, dayStart, dayEnd);
    var fE = accFilterRows(exchanges.slice(1), 11, 12, dayStart, dayEnd);
    var fB = accFilterRows(buybacks.slice(1), 9, 10, dayStart, dayEnd);
    var fW = accFilterRows(withdraws.slice(1), 6, 7, dayStart, dayEnd);
    var netResult = calcNetSellBahtForRows(fS, fT, fE, fB, fW);

    var sellCostLAK = wacPerG * sell.newGoldG;
    var tradeinDiffBaht = (tradein.newGoldG - tradein.oldGoldG) / 15;
    var tradeinAvg = tradeinDiffBaht !== 0 ? tradein.moneyNoP / tradeinDiffBaht : 0;
    var bbCostLAK = wacPerG * bb.oldGoldG;

    var gpDiff = 0;
    if (diffData && diffData.length > 1) { diffData.slice(1).forEach(function(row) { var date = parseSheetDate(row[9]); if (date && date >= dayStart && date <= dayEnd) { gpDiff += parseFloat(row[8]) || 0; } }); }
    var pl = gpDiff - otherExpenseLAK;

    var netColor = netResult.netBaht >= 0 ? '#4caf50' : '#f44336';

    document.getElementById('accountingStats').innerHTML =
      '<div class="stat-card" style="margin-bottom:20px;text-align:center;border:2px solid var(--gold-primary);">' +
      '<h3 style="color:var(--gold-primary);margin-bottom:8px;">⚖ ขายสุทธิ / บาท</h3>' +
      '<p style="font-size:36px;margin:10px 0;font-weight:bold;color:' + netColor + ';">' + netResult.netBaht.toFixed(2) + ' <span style="font-size:16px;">บาท</span></p>' +
      '<div style="font-size:12px;color:var(--text-secondary);line-height:1.8;">' +
      'New Out ทั้งหมด: ' + netResult.totalNewGOut.toFixed(2) + ' g | Old In ทั้งหมด: ' + netResult.totalOldGIn.toFixed(2) + ' g | Net: ' + (netResult.totalNewGOut - netResult.totalOldGIn).toFixed(2) + ' g ÷ 15</div></div>' +
      '<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">SELL</h3><p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ต้นทุน (WAC)</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(sellCostLAK)) + ' <span style="font-size:11px;">LAK</span></p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">New Gold Out</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + sell.newGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + sell.txCount + '</p></div>' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">TRADE-IN</h3><p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ราคาเฉลี่ย/บาท</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(tradeinAvg)) + ' <span style="font-size:11px;">LAK</span></p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">New Gold Out</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + tradein.newGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:4px 0 2px;">Old Gold In</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + tradein.oldGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:4px 0 2px;">Transactions</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + tradein.txCount + '</p></div>' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">EXCHANGE</h3><p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">New Gold Out</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + exchange.newGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Old Gold In</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + exchange.oldGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + exchange.txCount + '</p></div>' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">WITHDRAW</h3><p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">New Gold Out</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + wd.newGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + wd.txCount + '</p></div>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin-bottom:15px;">' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">BUYBACK</h3><p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ต้นทุน (WAC)</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(bbCostLAK)) + ' <span style="font-size:11px;">LAK</span></p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Old Gold In</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + bb.oldGoldG.toFixed(2) + ' g</p><p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + bb.txCount + '</p></div>' +
      '<div class="stat-card" style="border:2px solid #c62828;background:linear-gradient(135deg,#1a1a1a 0%,#2d1a1a 100%);"><h3 style="color:#ef5350;margin-bottom:8px;">INCOMPLETE</h3><p style="font-size:16px;color:#ef5350;font-weight:bold;margin:5px 0;">' + formatNumber(Math.round(incomplete.money)) + ' <span style="font-size:11px;">LAK</span></p><p style="font-size:14px;color:#ef5350;margin:3px 0;">' + incomplete.gold.toFixed(2) + ' g</p></div>' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">GP / Diff</h3><p style="font-size:20px;font-weight:bold;color:' + (gpDiff >= 0 ? '#4caf50' : '#f44336') + ';margin:10px 0;">' + formatNumber(Math.round(gpDiff)) + ' <span style="font-size:12px;">LAK</span></p></div>' +
      '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">Other Expense</h3><p style="font-size:20px;font-weight:bold;color:#ff9800;margin:10px 0;">' + formatNumber(Math.round(otherExpenseLAK)) + ' <span style="font-size:12px;">LAK</span></p></div>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr;gap:15px;">' +
      '<div class="stat-card" style="border:2px solid var(--gold-primary);text-align:center;"><h3 style="color:var(--gold-primary);margin-bottom:8px;">P/L</h3><p style="font-size:24px;font-weight:bold;color:' + (pl >= 0 ? '#4caf50' : '#f44336') + ';margin:10px 0;">' + formatNumber(Math.round(pl)) + ' <span style="font-size:12px;">LAK</span></p></div>' +
      '</div>';

    renderNetSellChart(sells, tradeins, exchanges, buybacks, withdraws);
    hideLoading();
  } catch (error) {
    console.error('Error loading accounting:', error);
    hideLoading();
  }
}

function renderNetSellChart(sells, tradeins, exchanges, buybacks, withdraws) {
  var today = new Date(); today.setHours(0,0,0,0);
  var labels = [], values = [];
  for (var d = 6; d >= 0; d--) {
    var target = new Date(today); target.setDate(target.getDate() - d);
    var ds = new Date(target.getFullYear(), target.getMonth(), target.getDate(), 0, 0, 0);
    var de = new Date(target.getFullYear(), target.getMonth(), target.getDate(), 23, 59, 59);
    var net = calcNetSellBahtForRows(
      accFilterRows(sells.slice(1), 9, 10, ds, de),
      accFilterRows(tradeins.slice(1), 11, 12, ds, de),
      accFilterRows(exchanges.slice(1), 11, 12, ds, de),
      accFilterRows(buybacks.slice(1), 9, 10, ds, de),
      accFilterRows(withdraws.slice(1), 6, 7, ds, de)
    );
    labels.push(target.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' }));
    values.push(parseFloat(net.netBaht.toFixed(2)));
  }
  if (accNetSellChartInstance) accNetSellChartInstance.destroy();
  var ctx = document.getElementById('accNetSellChart').getContext('2d');
  accNetSellChartInstance = new Chart(ctx, {
    type: 'line',
    data: { labels: labels, datasets: [{ label: 'ขายสุทธิ (บาท)', data: values, borderColor: '#d4af37', backgroundColor: 'rgba(212,175,55,0.15)', borderWidth: 3, pointBackgroundColor: '#d4af37', pointRadius: 5, pointHoverRadius: 7, fill: true, tension: 0.3 }] },
    options: {
      responsive: true,
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: function(ctx) { return ctx.parsed.y.toFixed(2) + ' บาท'; } } } },
      scales: {
        x: { ticks: { color: '#999' }, grid: { color: 'rgba(255,255,255,0.05)' } },
        y: { ticks: { color: '#999', callback: function(v) { return v.toFixed(1); } }, grid: { color: 'rgba(255,255,255,0.1)' }, title: { display: true, text: 'บาท', color: '#ccc' } }
      }
    }
  });
}

function resetAccDateFilter() {
  var td = getTodayDateString();
  _accDateFrom = td;
  _accDateTo = td;
  loadAccounting();
}

document.addEventListener('DOMContentLoaded', function() {
  var f = document.getElementById('accDateFrom');
  var t = document.getElementById('accDateTo');
  if (f && t) {
    f.addEventListener('change', function() { _accDateFrom = this.value; if (_accDateFrom && _accDateTo) loadAccounting(); });
    t.addEventListener('change', function() { _accDateTo = this.value; if (_accDateFrom && _accDateTo) loadAccounting(); });
  }
});
