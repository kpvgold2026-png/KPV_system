async function loadDiff() {
  try {
    showLoading();
    _diffData = await fetchSheetData('Diff!A:J');
    var today = getTodayLocalStr();
    document.getElementById('diffStartDate').value = today;
    document.getElementById('diffEndDate').value = today;
    renderDiffTable(_diffData, today, today);
    hideLoading();
  } catch(e) {
    console.error('Error loading diff:', e);
    hideLoading();
  }
}

function renderDiffTable(data, startDate, endDate) {
  var tbody = document.getElementById('diffTable');

  if (!data || data.length <= 1) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;">No records</td></tr>';
    document.getElementById('diffTotalRow').innerHTML = '<td colspan="7" style="text-align:right;font-weight:bold;">Total Diff:</td><td style="font-weight:bold;">0 LAK</td>';
    return;
  }

  var rows = data.slice(1).filter(function(row) { return String(row[1] || '').toUpperCase() !== 'BUYBACK'; });

  if (startDate && endDate) {
    rows = rows.filter(function(row) {
      var d = parseSheetDate(row[9]);
      if (!d) return false;
      var ds = d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
      return ds >= startDate && ds <= endDate;
    });
  }

  rows.sort(function(a, b) {
    var da = parseSheetDate(a[9]);
    var db = parseSheetDate(b[9]);
    if (!da) return 1;
    if (!db) return -1;
    return db.getTime() - da.getTime();
  });

  var totalDiff = 0;

  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;">No records in this date range</td></tr>';
    document.getElementById('diffTotalRow').innerHTML = '<td colspan="7" style="text-align:right;font-weight:bold;">Total Diff:</td><td style="font-weight:bold;">0 LAK</td>';
    return;
  }

  tbody.innerHTML = rows.map(function(row) {
    var diff = parseFloat(row[8]) || 0;
    totalDiff += diff;
    var diffColor = diff >= 0 ? '#4caf50' : '#f44336';

    return '<tr>' +
      '<td>' + (row[0] || '') + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[2]) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[3]) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[4]) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[5]) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[6]) || 0)) + '</td>' +
      '<td>' + formatNumber(Math.round(parseFloat(row[7]) || 0)) + '</td>' +
      '<td style="color:' + diffColor + ';font-weight:bold;">' + formatNumber(Math.round(diff)) + '</td>' +
    '</tr>';
  }).join('');

  var totalColor = totalDiff >= 0 ? '#4caf50' : '#f44336';
  document.getElementById('diffTotalRow').innerHTML =
    '<td colspan="7" style="text-align:right;font-weight:bold;font-size:16px;">Total Diff:</td>' +
    '<td style="font-weight:bold;font-size:18px;color:' + totalColor + ';">' + formatNumber(Math.round(totalDiff)) + ' LAK</td>';
}

var _diffData = null;

async function filterDiff() {
  var start = document.getElementById('diffStartDate').value;
  var end = document.getElementById('diffEndDate').value;
  if (!start || !end) return;
  if (!_diffData) {
    _diffData = await fetchSheetData('Diff!A:J');
  }
  renderDiffTable(_diffData, start, end);
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
  if (!_diffData) {
    _diffData = await fetchSheetData('Diff!A:J');
  }
  renderDiffTable(_diffData, today, today);
}
