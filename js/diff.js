var _diffData = null;

async function loadDiff() {
  try {
    showLoading();
    var today = getTodayLocalStr();
    document.getElementById('diffStartDate').value = today;
    document.getElementById('diffEndDate').value = today;
    await loadDiffData(today, today);
    hideLoading();
  } catch(e) {
    console.error('Error loading diff:', e);
    hideLoading();
  }
}

async function loadDiffData(startDate, endDate) {
  var result = await dbRpc('get_diff_summary', {
    p_date_from: startDate,
    p_date_to: endDate
  });
  renderDiffTable(result, startDate, endDate);
}

function renderDiffTable(data, startDate, endDate) {
  var tbody = document.getElementById('diffTable');

  if (!data || !data.rows || data.rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;">No records in this date range</td></tr>';
    document.getElementById('diffTotalRow').innerHTML = '<td colspan="7" style="text-align:right;font-weight:bold;">Total Diff:</td><td style="font-weight:bold;">0 LAK</td>';
    return;
  }

  var rows = data.rows.filter(function(row) { return String(row.type || '').toUpperCase() !== 'BUYBACK'; });

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;">No records in this date range</td></tr>';
    document.getElementById('diffTotalRow').innerHTML = '<td colspan="7" style="text-align:right;font-weight:bold;">Total Diff:</td><td style="font-weight:bold;">0 LAK</td>';
    return;
  }

  var totalDiff = 0;
  tbody.innerHTML = rows.map(function(row) {
    var diff = parseFloat(row.diff) || 0;
    totalDiff += diff;
    var diffColor = diff >= 0 ? '#4caf50' : '#f44336';
    return '<tr>' +
      '<td>' + (row.tx_id || '') + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.sell_value) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.ex_fee) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.switch_fee) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.premium) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.cost_diff) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row.cost_old_gold) || 0)) + '</td>' +
      '<td style="color:' + diffColor + ';font-weight:bold;">' + formatNumber(Math.round(diff)) + '</td>' +
    '</tr>';
  }).join('');

  var totalColor = totalDiff >= 0 ? '#4caf50' : '#f44336';
  document.getElementById('diffTotalRow').innerHTML =
    '<td colspan="7" style="text-align:right;font-weight:bold;font-size:16px;">Total Diff:</td>' +
    '<td style="font-weight:bold;font-size:18px;color:' + totalColor + ';">' + formatNumber(Math.round(totalDiff)) + ' LAK</td>';
}

async function filterDiff() {
  var start = document.getElementById('diffStartDate').value;
  var end = document.getElementById('diffEndDate').value;
  if (!start || !end) return;
  await loadDiffData(start, end);
}

function checkDiffFilter() {
  var start = document.getElementById('diffStartDate').value;
  var end = document.getElementById('diffEndDate').value;
  if (start && end) filterDiff();
}

async function showTodayDiff() {
  var today = getTodayLocalStr();
  document.getElementById('diffStartDate').value = today;
  document.getElementById('diffEndDate').value = today;
  await loadDiffData(today, today);
}
