let reportsChartInstance = null;

async function loadReports() {
  try {
    showLoading();
    var data = await dbSelect('daily_reports', {
      select: 'date,carry,net',
      order: 'date.desc',
      limit: 30,
      useCache: false
    });

    var tbody = document.getElementById('reportsTable');
    if (!data || data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; padding: 40px;">No reports yet</td></tr>';
      hideLoading();
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var carry = parseFloat(row.carry) || 0;
      var net = parseFloat(row.net) || 0;
      var diff = net - carry;
      var diffColor = diff >= 0 ? '#4caf50' : '#f44336';
      var diffSign = diff >= 0 ? '+' : '';
      return '<tr>' +
        '<td style="text-align: center;">' + formatDateOnly(row.date) + '</td>' +
        '<td style="text-align: center;">' + formatWeight(carry) + '</td>' +
        '<td style="text-align: center;">' + formatWeight(net) + '</td>' +
        '<td style="text-align: center; color: ' + diffColor + '; font-weight: bold;">' + diffSign + formatWeight(diff) + '</td>' +
        '</tr>';
    }).join('');

    renderReportsChart(data);
    await loadSalesShiftList();
    hideLoading();
  } catch (error) {
    console.error('Error loading reports:', error);
    document.getElementById('reportsTable').innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 40px; color: #f44336;">Error loading reports</td></tr>';
    hideLoading();
  }
}

async function loadSalesShiftList() {
  var tbody = document.getElementById('salesShiftTable');
  if (!tbody) return;
  try {
    var rows = await dbRpc('get_sales_with_shift', {});
    if (!Array.isArray(rows) || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:30px;">ไม่มีพนักงาน Sales</td></tr>';
      return;
    }
    tbody.innerHTML = rows.map(function(r) {
      var statusLabel, statusColor;
      if (r.shift_status === 'OPEN') {
        statusLabel = '🟢 เปิดกะ'; statusColor = '#4caf50';
      } else if (r.shift_status === 'CLOSED') {
        statusLabel = '🔒 ปิดกะแล้ว'; statusColor = '#888';
      } else {
        statusLabel = '⚪ ยังไม่เปิด'; statusColor = '#aaa';
      }
      var amt = r.shift_amount ? formatNumber(parseFloat(r.shift_amount)) + ' LAK' : '-';
      var openedAt = r.shift_opened_at ? formatDateTime(r.shift_opened_at) : '-';
      return '<tr>' +
        '<td>' + (r.username || '-') + '</td>' +
        '<td>' + (r.nickname || '-') + '</td>' +
        '<td style="color:' + statusColor + ';font-weight:600;">' + statusLabel + '</td>' +
        '<td style="text-align:right;">' + amt + '</td>' +
        '<td style="font-size:11px;">' + openedAt + '</td>' +
        '</tr>';
    }).join('');
  } catch(e) {
    console.error('loadSalesShiftList error:', e);
    tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:30px;color:#f44336;">Error</td></tr>';
  }
}

function renderReportsChart(data) {
  if (!data || data.length === 0) return;
  var ctx = document.getElementById('reportsChart');
  if (!ctx) return;

  var chartData = data.slice().reverse().slice(-30);
  var labels = chartData.map(function(row) {
    var d = new Date(row.date);
    if (!isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    return String(row.date).substring(0, 10);
  });

  var rangeEl = document.getElementById('reportsDateRange');
  if (rangeEl && chartData.length > 0) {
    var fmt = function(val) {
      var d = new Date(val);
      return !isNaN(d.getTime()) ? d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' }) : '';
    };
    rangeEl.textContent = fmt(chartData[0].date) + ' — ' + fmt(chartData[chartData.length - 1].date);
  }

  var netValues = chartData.map(function(row) { return parseFloat(row.net) || 0; });
  var diffValues = chartData.map(function(row) { return (parseFloat(row.net) || 0) - (parseFloat(row.carry) || 0); });

  if (reportsChartInstance) reportsChartInstance.destroy();

  reportsChartInstance = new Chart(ctx.getContext('2d'), {
    type: 'line',
    data: {
      labels: labels,
      datasets: [
        { label: 'ยอดทองสุทธิ', data: netValues, borderColor: '#d4af37', backgroundColor: 'rgba(212,175,55,0.15)', tension: 0.3, fill: true, pointRadius: 3, pointBackgroundColor: '#d4af37', borderWidth: 2 },
        { label: 'ส่วนต่าง', data: diffValues, borderColor: '#4caf50', backgroundColor: 'rgba(76,175,80,0.1)', tension: 0.3, fill: true, pointRadius: 3, pointBackgroundColor: '#4caf50', borderWidth: 2 }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#ccc', font: { size: 12 } } },
        tooltip: { callbacks: { label: function(ctx) { return ctx.dataset.label + ': ' + ctx.parsed.y.toFixed(2) + ' g'; } } }
      },
      scales: {
        x: { display: false },
        y: { title: { display: true, text: 'Gold (g)', color: '#ccc' }, ticks: { color: '#999' }, grid: { color: 'rgba(255,255,255,0.1)' } }
      }
    }
  });
}
