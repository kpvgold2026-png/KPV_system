let reportsChartInstance = null;

async function loadReports() {
  try {
    showLoading();
    
    const data = await fetchSheetData('Reports!A:C');
    
    if (data.length > 1) {
      const today = new Date();
      const yesterday = new Date(today);
      yesterday.setDate(yesterday.getDate() - 1);
      yesterday.setHours(0, 0, 0, 0);
      
      const yesterdayKey = `${yesterday.getFullYear()}-${String(yesterday.getMonth()+1).padStart(2,'0')}-${String(yesterday.getDate()).padStart(2,'0')}`;
      
      let hasYesterday = false;
      data.slice(1).forEach(row => {
        if (row[0]) {
          const d = parseSheetDate(row[0]);
          if (d) {
            const dateKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
            if (dateKey === yesterdayKey) {
              hasYesterday = true;
            }
          }
        }
      });
      
      if (!hasYesterday) {
        await checkAndCalculateMissingReports();
      }
    } else {
      await checkAndCalculateMissingReports();
    }
    
    const updatedData = await fetchSheetData('Reports!A:C');
    const tbody = document.getElementById('reportsTable');
    
    if (updatedData.length <= 1) {
      tbody.innerHTML = '<tr><td colspan="4" style="text-align: center; padding: 40px;">No reports yet</td></tr>';
      hideLoading();
      return;
    }
    
    const reports = updatedData.slice(1).reverse().slice(0, 30);
    
    tbody.innerHTML = reports.map(row => {
      var carry = parseFloat(row[1] || 0);
      var net = parseFloat(row[2] || 0);
      var diff = net - carry;
      var diffColor = diff >= 0 ? '#4caf50' : '#f44336';
      var diffSign = diff >= 0 ? '+' : '';
      return `
      <tr>
        <td style="text-align: center;">${formatDateOnly(row[0])}</td>
        <td style="text-align: center;">${formatWeight(carry)}</td>
        <td style="text-align: center;">${formatWeight(net)}</td>
        <td style="text-align: center; color: ${diffColor}; font-weight: bold;">${diffSign}${formatWeight(diff)}</td>
      </tr>
    `}).join('');
    
    hideLoading();
  } catch (error) {
    console.error('Error loading reports:', error);
    document.getElementById('reportsTable').innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 40px; color: #f44336;">Error loading reports</td></tr>';
    hideLoading();
  }
}

function renderReportsChart(data) {
  if (data.length <= 1) return;

  var chartData = data.slice(1).slice(-30);

  var labels = chartData.map(function(row) {
    var d = parseSheetDate(row[0]);
    if (d && !isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    return String(row[0]).substring(0, 10);
  });

  var firstD = parseSheetDate(chartData[0][0]);
  var lastD = parseSheetDate(chartData[chartData.length - 1][0]);
  var rangeEl = document.getElementById('reportsDateRange');
  if (rangeEl) {
    var fmt = function(d) { return d ? d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' }) : ''; };
    rangeEl.textContent = fmt(firstD) + ' — ' + fmt(lastD);
  }

  var netValues = chartData.map(function(row) { return parseFloat(row[2]) || 0; });
  var diffValues = chartData.map(function(row) { return (parseFloat(row[2]) || 0) - (parseFloat(row[1]) || 0); });

  if (reportsChartInstance) reportsChartInstance.destroy();

  var ctx = document.getElementById('reportsChart').getContext('2d');
  reportsChartInstance = new Chart(ctx, {
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

async function checkAndCalculateMissingReports() {
  try {
    const result = await callAppsScript('AUTO_CALCULATE_REPORTS', {});
    if (result.calculated > 0) {
      console.log(`Auto-calculated ${result.calculated} missing reports`);
    }
  } catch (error) {
    console.error('Error auto-calculating reports:', error);
  }
}
