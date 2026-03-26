var historySellDateFrom = '';
var historySellDateTo = '';

async function loadHistorySell() {
  try {
    showLoading();
    var today = getTodayDateString();
    if (!historySellDateFrom && !historySellDateTo) {
      historySellDateFrom = today;
      historySellDateTo = today;
    }
    document.getElementById('historySellDateFrom').value = historySellDateFrom;
    document.getElementById('historySellDateTo').value = historySellDateTo;

    var fromEl = document.getElementById('historySellDateFrom');
    var toEl = document.getElementById('historySellDateTo');
    fromEl.onchange = function() { historySellDateFrom = this.value; loadHistorySell(); };
    toEl.onchange = function() { historySellDateTo = this.value; loadHistorySell(); };

    var results = await Promise.all([
      fetchSheetData('Sells!A:L'),
      fetchSheetData('Tradeins!A:N'),
      fetchSheetData('Exchanges!A:T'),
      fetchSheetData('Withdraws!A:L')
    ]);

    var all = [];

    results[0].slice(1).forEach(function(r) {
      var sPaid = parseFloat(r[5]) || 0;
      var sChange = parseFloat(r[8]) || 0;
      all.push({
        type: 'SELL', id: r[0], phone: r[1],
        oldGold: '-', newGold: formatItemsForTable(r[2]),
        difference: '-', exchangeFee: '-', switchFee: '-',
        premium: formatNumber(calculatePremiumFromItems(r[2])),
        total: parseFloat(r[3]) || 0,
        paid: sPaid > 0 ? formatNumber(sPaid) + ' ' + (r[6] || 'LAK') : '-',
        change: sChange > 0 ? formatNumber(sChange) + ' LAK' : '-',
        status: r[10] || '', sale: r[11] || '', date: r[9], raw: r
      });
    });

    results[1].slice(1).forEach(function(r) {
      var tPaid = parseFloat(r[7]) || 0;
      var tChange = parseFloat(r[10]) || 0;
      all.push({
        type: 'TRADE-IN', id: r[0], phone: r[1],
        oldGold: formatItemsForTable(r[2]), newGold: formatItemsForTable(r[3]),
        difference: formatNumber(parseFloat(r[4]) || 0), exchangeFee: '-', switchFee: '-',
        premium: formatNumber(calculatePremiumFromItems(r[3])),
        total: parseFloat(r[6]) || 0,
        paid: tPaid > 0 ? formatNumber(tPaid) + ' ' + (r[8] || 'LAK') : '-',
        change: tChange > 0 ? formatNumber(tChange) + ' LAK' : '-',
        status: r[12] || '', sale: r[13] || '', date: r[11], raw: r
      });
    });

    results[2].slice(1).forEach(function(r) {
      var switchFeeVal = parseFloat(r[15]) || 0;
      var ePaid = parseFloat(r[7]) || 0;
      var eChange = parseFloat(r[10]) || 0;
      all.push({
        type: 'EXCHANGE', id: r[0], phone: r[1],
        oldGold: formatItemsForTable(r[2]), newGold: formatItemsForTable(r[3]),
        difference: '-',
        exchangeFee: formatNumber(parseFloat(r[4]) || 0),
        switchFee: switchFeeVal > 0 ? formatNumber(switchFeeVal) : '-',
        premium: formatNumber(parseFloat(r[5]) || 0),
        total: parseFloat(r[6]) || 0,
        paid: ePaid > 0 ? formatNumber(ePaid) + ' ' + (r[8] || 'LAK') : '-',
        change: eChange > 0 ? formatNumber(eChange) + ' LAK' : '-',
        status: r[12] || '', sale: r[13] || '', date: r[11], raw: r
      });
    });

    results[3].slice(1).forEach(function(r) {
      var wPaid = parseFloat(r[5]) || 0;
      all.push({
        type: 'WITHDRAW', id: r[0], phone: r[1],
        oldGold: '-', newGold: formatItemsForTable(r[2]),
        difference: '-', exchangeFee: '-', switchFee: '-',
        premium: formatNumber(parseFloat(r[3]) || 0),
        total: parseFloat(r[4]) || 0,
        paid: wPaid > 0 ? formatNumber(wPaid) + ' LAK' : '-',
        change: '-',
        status: r[7] || '', sale: r[8] || '', date: r[6], raw: r
      });
    });

    all = filterHistoryByDate(all, historySellDateFrom, historySellDateTo);
    all.sort(function(a, b) { return parseHistoryDate(b.date) - parseHistoryDate(a.date); });

    var tbody = document.getElementById('historySellTable');
    if (all.length === 0) {
      tbody.innerHTML = '<tr><td colspan="13" style="text-align:center;padding:40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = all.map(function(r) {
        var typeColors = { 'SELL': '#4caf50', 'TRADE-IN': '#2196f3', 'EXCHANGE': '#9c27b0', 'SWITCH': '#ff9800', 'FREE EX': '#00bcd4', 'WITHDRAW': '#f44336' };
        var color = typeColors[r.type] || '#888';
        var actions = '';
        if (r.status === 'COMPLETED' || r.status === 'PAID') {
          var detailArr = [];
          if (r.type === 'WITHDRAW') {
            detailArr = [
              ['Type', r.type], ['Transaction ID', r.id], ['Phone', r.phone],
              ['Withdraw Code', (r.raw && r.raw[11]) || '-'],
              ['Items', r.newGold],
              ['Premium', r.premium],
              ['Total', formatNumber(r.total) + ' LAK'],
              ['Customer Paid', r.paid || '-'],
              ['Note', (r.raw && r.raw[9]) || '-'],
              ['Date', formatDateTime(r.date)], ['Status', r.status], ['Sale', r.sale]
            ];
          } else if (r.type === 'SELL') {
            detailArr = [
              ['Type', r.type], ['Transaction ID', r.id], ['Phone', r.phone],
              ['Items', r.newGold],
              ['Premium', r.premium],
              ['Total', formatNumber(r.total) + ' LAK'],
              ['Customer Paid', r.paid || '-'], ['Change', r.change || '-'],
              ['Date', formatDateTime(r.date)], ['Status', r.status], ['Sale', r.sale]
            ];
          } else {
            detailArr = [
              ['Type', r.type], ['Transaction ID', r.id], ['Phone', r.phone],
              ['Old Gold', r.oldGold], ['New Gold', r.newGold],
              ['Difference', r.difference], ['Exchange Fee', r.exchangeFee],
              ['Switch Fee', r.switchFee],
              ['Free Ex Bill', (r.raw && (r.raw[17] || '')) || '-'],
              ['Premium', r.premium],
              ['Total', formatNumber(r.total) + ' LAK'],
              ['Customer Paid', r.paid || '-'], ['Change', r.change || '-'],
              ['Date', formatDateTime(r.date)], ['Status', r.status], ['Sale', r.sale]
            ];
          }
          var detail = encodeURIComponent(JSON.stringify(detailArr));
          actions = '<button class="btn-action" onclick="viewTransactionDetail(\'' + r.type + '\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
        } else if (r.status === 'PENDING' && isManager()) {
          var reviewTypeMap = { 'SELL': 'reviewSell', 'TRADE-IN': 'reviewTradein', 'EXCHANGE': 'reviewExchange', 'SWITCH': 'reviewSwitch', 'FREE EX': 'reviewFreeExchange', 'WITHDRAW': 'reviewWithdraw' };
          var fn = reviewTypeMap[r.type];
          if (fn) {
            actions = '<button class="btn-action" onclick="' + fn + '(\'' + r.id + '\')" style="background:#ff9800;color:#fff;border-color:#ff9800;">Review</button>';
          }
        } else if (r.status === 'PENDING') {
          actions = '<span style="color:var(--text-secondary);font-size:12px;">Pending</span>';
        } else if (r.status === 'READY') {
          actions = '<span style="color:var(--text-secondary);font-size:12px;">Ready</span>';
        }
        if (r.status !== 'COMPLETED' && r.status !== 'PARTIAL' && r.status !== 'PAID' && currentUser.role === 'Admin') {
          var sheetMap = { 'SELL': 'Sells', 'TRADE-IN': 'Tradeins', 'EXCHANGE': 'Exchanges', 'SWITCH': 'Switches', 'FREE EX': 'FreeExchanges', 'WITHDRAW': 'Withdraws' };
          var sheet = sheetMap[r.type] || '';
          actions += ' <button class="btn-action" onclick="deleteTransaction(\'' + r.id + '\',\'' + sheet + '\',\'' + r.type + '\')" style="background:#f44336;margin-left:4px;">🗑️</button>';
        }
        var dim = 'style="color:var(--text-secondary);"';
        return '<tr>' +
          '<td style="white-space:nowrap;">' + r.id + '</td>' +
          '<td style="font-size:11px;white-space:nowrap;">' + (r.date || '') + '</td>' +
          '<td>' + r.phone + '</td>' +
          '<td><span style="background:' + color + ';color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;white-space:nowrap;">' + r.type + '</span></td>' +
          '<td>' + (r.oldGold === '-' ? '<span ' + dim + '>-</span>' : r.oldGold) + '</td>' +
          '<td>' + (r.newGold === '-' ? '<span ' + dim + '>-</span>' : r.newGold) + '</td>' +
          '<td>' + (r.difference === '-' ? '<span ' + dim + '>-</span>' : r.difference) + '</td>' +
          '<td>' + (r.exchangeFee === '-' ? '<span ' + dim + '>-</span>' : r.exchangeFee) + '</td>' +
          '<td>' + (r.switchFee === '-' ? '<span ' + dim + '>-</span>' : r.switchFee) + '</td>' +
          '<td>' + (r.premium === '0' || r.premium === '-' ? '<span ' + dim + '>-</span>' : r.premium) + '</td>' +
          '<td style="font-weight:bold;">' + formatNumber(r.total) + '</td>' +
          '<td><span class="status-badge status-' + (r.status || '').toLowerCase() + '">' + r.status + '</span></td>' +
          '<td>' + r.sale + '</td>' +
          '<td>' + actions + '</td>' +
          '</tr>';
      }).join('');
    }

    hideLoading();
  } catch(e) {
    console.error('Error loading history sell:', e);
    hideLoading();
  }
}

function filterHistoryByDate(data, from, to) {
  var fromDate = null, toDate = null;
  if (from) { var p = from.split('-'); fromDate = new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2]), 0, 0, 0, 0); }
  if (to) { var p = to.split('-'); toDate = new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2]), 23, 59, 59, 999); }
  return data.filter(function(r) {
    var d = parseHistoryDate(r.date);
    if (!d || isNaN(d)) return false;
    if (fromDate && d < fromDate) return false;
    if (toDate && d > toDate) return false;
    return true;
  });
}

function parseHistoryDate(dateValue) {
  if (!dateValue) return 0;
  if (dateValue instanceof Date) return dateValue.getTime();
  if (typeof dateValue === 'string') {
    if (dateValue.includes('/')) {
      var parts = dateValue.split(' ');
      var dp = parts[0].split('/');
      var day = parseInt(dp[0]), month = parseInt(dp[1]) - 1, year = parseInt(dp[2]);
      var h = 0, m = 0;
      if (parts[1]) { var tp = parts[1].split(':'); h = parseInt(tp[0]) || 0; m = parseInt(tp[1]) || 0; }
      return new Date(year, month, day, h, m).getTime();
    }
    return new Date(dateValue).getTime();
  }
  return 0;
}

function resetHistorySellDateFilter() {
  historySellDateFrom = getTodayDateString();
  historySellDateTo = getTodayDateString();
  loadHistorySell();
}
