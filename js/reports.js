let reportsChartInstance = null;

async function loadReports() {
  try {
    showLoading();
    // ใช้ get_wealth_summary RPC ที่คำนวณจาก stock_moves on-demand
    // (ไม่พึ่ง daily_reports table ซึ่งอาจว่างถ้าไม่มี scheduled job ทำ back-fill)
    var data = null;
    try {
      data = await dbRpc('get_wealth_summary', { p_days: 30 });
    } catch(e) {
      console.warn('get_wealth_summary not available, fallback to daily_reports table:', e);
      data = await dbSelect('daily_reports', {
        select: 'date,carry,net',
        order: 'date.desc',
        limit: 30,
        useCache: false
      });
    }

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
    hideLoading();
  } catch (error) {
    console.error('Error loading reports:', error);
    document.getElementById('reportsTable').innerHTML = '<tr><td colspan="4" style="text-align: center; padding: 40px; color: #f44336;">Error loading reports</td></tr>';
    hideLoading();
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
