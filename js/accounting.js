var _accDateFrom = null;
var _accDateTo = null;
var accNetSellChartInstance = null;

async function loadAccounting() {
  try {
    showLoading();
    if (!_accDateFrom || !_accDateTo) {
      var td = getTodayLocalStr();
      _accDateFrom = td;
      _accDateTo = td;
    }
    document.getElementById('accDateFrom').value = _accDateFrom;
    document.getElementById('accDateTo').value = _accDateTo;

    var dashData = await dbRpc('get_dashboard_data', {
      p_date_from: _accDateFrom,
      p_date_to: _accDateTo
    });
    var gramData = await dbRpc('get_sales_gold_grams', {
      p_date_from: _accDateFrom,
      p_date_to: _accDateTo
    });
    var diffData = await dbRpc('get_diff_summary', {
      p_date_from: _accDateFrom,
      p_date_to: _accDateTo
    });
    var accData = await dbRpc('get_accounting_summary', {
      p_date_from: _accDateFrom,
      p_date_to: _accDateTo
    });

    renderAccounting(dashData, gramData, diffData, accData);
    await renderNetSellChartFromRPC();
    hideLoading();
  } catch (error) {
    console.error('Error loading accounting:', error);
    hideLoading();
  }
}

function renderAccounting(dashData, gramData, diffData, accData) {
  var sales = dashData && dashData.sales ? dashData.sales : {};
  var buybacks = dashData && dashData.buybacks ? dashData.buybacks : {};
  var withdraws = dashData && dashData.withdraws ? dashData.withdraws : {};

  var sellMoney = parseFloat(sales.sell) || 0;
  var sellCount = parseInt(sales.sell_count) || 0;
  var tradeinMoney = parseFloat(sales.tradein) || 0;
  var tradeinCount = parseInt(sales.tradein_count) || 0;
  var exchangeCount = parseInt(sales.exchange_count) || 0;

  var salesOldG = gramData ? parseFloat(gramData.sales_old_g) || 0 : 0;
  var salesNewG = gramData ? parseFloat(gramData.sales_new_g) || 0 : 0;
  var bbOldG = gramData ? parseFloat(gramData.buyback_old_g) || 0 : 0;
  var wdNewG = gramData ? parseFloat(gramData.withdraw_new_g) || 0 : 0;

  var totalOldGIn = salesOldG + bbOldG;
  var totalNewGOut = salesNewG + wdNewG;
  var netBaht = (totalNewGOut - totalOldGIn) / 15;
  var netColor = netBaht >= 0 ? '#4caf50' : '#f44336';

  var wac = dashData && dashData.wac ? dashData.wac : {};
  var newGoldG_wac = parseFloat(wac.new_gold_g) || 0;
  var newValue_wac = parseFloat(wac.new_value) || 0;
  var oldGoldG_wac = parseFloat(wac.old_gold_g) || 0;
  var oldValue_wac = parseFloat(wac.old_value) || 0;
  var totalG_wac = newGoldG_wac + oldGoldG_wac;
  var totalC_wac = newValue_wac + oldValue_wac;
  var wacPerG = totalG_wac > 0 ? totalC_wac / totalG_wac : 0;

  var bbMoney = parseFloat(buybacks.amount) || 0;
  var bbCount = parseInt(buybacks.count) || 0;
  var wdMoney = parseFloat(withdraws.amount) || 0;
  var wdCount = parseInt(withdraws.count) || 0;

  var sellCostLAK = wacPerG * salesNewG;
  var sellDiff = sellMoney - sellCostLAK;
  var tradeinCostLAK = wacPerG * salesNewG;
  var bbCostLAK = wacPerG * bbOldG;
  var bbDiff = bbMoney - bbCostLAK;

  var gpDiff = diffData ? parseFloat(diffData.total) || 0 : 0;
  var otherExpense = dashData ? parseFloat(dashData.other_expense) || 0 : 0;
  var pl = gpDiff - otherExpense;

  document.getElementById('accountingStats').innerHTML =
    '<div class="stat-card" style="margin-bottom:20px;text-align:center;border:2px solid var(--gold-primary);">' +
    '<h3 style="color:var(--gold-primary);margin-bottom:8px;">⚖ ขายสุทธิ / บาท</h3>' +
    '<p style="font-size:36px;margin:10px 0;font-weight:bold;color:' + netColor + ';">' + netBaht.toFixed(3) + ' <span style="font-size:16px;">บาท</span></p>' +
    '<div style="font-size:12px;color:var(--text-secondary);line-height:1.8;">' +
    'New Out: ' + totalNewGOut.toFixed(2) + ' g | Old In: ' + totalOldGIn.toFixed(2) + ' g | Net: ' + (totalNewGOut - totalOldGIn).toFixed(2) + ' g ÷ 15</div></div>' +

    '<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin-bottom:15px;">' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">SELL</h3>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ยอดขาย</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(sellMoney)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">ต้นทุน (WAC)</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(sellCostLAK)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Diff</p><p style="font-size:16px;font-weight:bold;margin:2px 0;color:' + (sellDiff >= 0 ? '#4caf50' : '#f44336') + ';">' + formatNumber(Math.round(sellDiff)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + sellCount + '</p></div>' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">TRADE-IN</h3>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ยอดรับ</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(tradeinMoney)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">New Out</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + salesNewG.toFixed(2) + ' g</p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Old In</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + salesOldG.toFixed(2) + ' g</p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Tx</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + tradeinCount + '</p></div>' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">EXCHANGE</h3>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">Transactions</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + exchangeCount + '</p></div>' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">WITHDRAW</h3>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ยอด</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(wdMoney)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">New Out</p><p style="font-size:14px;font-weight:bold;margin:2px 0;">' + wdNewG.toFixed(2) + ' g</p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Tx</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + wdCount + '</p></div>' +
    '</div>' +

    '<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:15px;margin-bottom:15px;">' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">BUYBACK</h3>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:2px 0;">ยอดจ่าย</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(bbMoney)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">ต้นทุน (WAC)</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + formatNumber(Math.round(bbCostLAK)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Diff</p><p style="font-size:16px;font-weight:bold;margin:2px 0;color:' + (bbDiff >= 0 ? '#4caf50' : '#f44336') + ';">' + formatNumber(Math.round(bbDiff)) + ' <span style="font-size:11px;">LAK</span></p>' +
    '<p style="font-size:13px;color:var(--text-secondary);margin:6px 0 2px;">Tx</p><p style="font-size:16px;font-weight:bold;margin:2px 0;">' + bbCount + '</p></div>' +

    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">GP / Diff</h3><p style="font-size:20px;font-weight:bold;color:' + (gpDiff >= 0 ? '#4caf50' : '#f44336') + ';margin:10px 0;">' + formatNumber(Math.round(gpDiff)) + ' <span style="font-size:12px;">LAK</span></p></div>' +
    '<div class="stat-card"><h3 style="color:var(--gold-primary);margin-bottom:8px;">Other Expense</h3><p style="font-size:20px;font-weight:bold;color:#ff9800;margin:10px 0;">' + formatNumber(Math.round(otherExpense)) + ' <span style="font-size:12px;">LAK</span></p></div>' +
    '</div>' +

    '<div class="stat-card" style="border:2px solid var(--gold-primary);text-align:center;"><h3 style="color:var(--gold-primary);margin-bottom:8px;">P/L</h3><p style="font-size:24px;font-weight:bold;color:' + (pl >= 0 ? '#4caf50' : '#f44336') + ';margin:10px 0;">' + formatNumber(Math.round(pl)) + ' <span style="font-size:12px;">LAK</span></p></div>';
}

async function renderNetSellChartFromRPC() {
  var today = new Date(); today.setHours(0, 0, 0, 0);
  var labels = [], values = [];

  for (var d = 6; d >= 0; d--) {
    var target = new Date(today); target.setDate(target.getDate() - d);
    var ds = target.getFullYear() + '-' + String(target.getMonth() + 1).padStart(2, '0') + '-' + String(target.getDate()).padStart(2, '0');
    var gram = await dbRpc('get_sales_gold_grams', { p_date_from: ds, p_date_to: ds });
    var oldIn = (parseFloat(gram.sales_old_g) || 0) + (parseFloat(gram.buyback_old_g) || 0);
    var newOut = (parseFloat(gram.sales_new_g) || 0) + (parseFloat(gram.withdraw_new_g) || 0);
    var net = (newOut - oldIn) / 15;
    labels.push(target.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' }));
    values.push(parseFloat(net.toFixed(2)));
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
  var td = getTodayLocalStr();
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
