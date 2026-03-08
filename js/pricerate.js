let thbChartInstance = null;
let usdChartInstance = null;

async function loadPriceRate() {
  try {
    showLoading();
    const data = await fetchSheetData('PriceRate!A:F');
    
    if (data.length > 1) {
      const latestRate = data[data.length - 1];
      currentPriceRates = {
        thbSell: parseFloat(latestRate[1]) || 0,
        usdSell: parseFloat(latestRate[2]) || 0,
        thbBuy: parseFloat(latestRate[3]) || 0,
        usdBuy: parseFloat(latestRate[4]) || 0
      };
      
      document.getElementById('rateTHBSell').textContent = formatNumber(currentPriceRates.thbSell);
      document.getElementById('rateUSDSell').textContent = formatNumber(currentPriceRates.usdSell);
      document.getElementById('rateTHBBuy').textContent = formatNumber(currentPriceRates.thbBuy);
      document.getElementById('rateUSDBuy').textContent = formatNumber(currentPriceRates.usdBuy);
    }
    
    const tbody = document.getElementById('priceRateTable');
    if (data.length <= 1) {
      tbody.innerHTML = '<tr><td colspan="6" style="text-align: center; padding: 40px;">No records</td></tr>';
    } else {
      const rows = data.slice(1).reverse().slice(0, 30);
      tbody.innerHTML = rows.map(row => `
        <tr>
          <td>${formatDateTime(row[0])}</td>
          <td>${formatNumber(row[1])}</td>
          <td>${formatNumber(row[2])}</td>
          <td>${formatNumber(row[3])}</td>
          <td>${formatNumber(row[4])}</td>
          <td>${row[5]}</td>
        </tr>
      `).join('');
    }
    
    renderPriceRateCharts(data);
    hideLoading();
  } catch (error) {
    console.error('Error loading price rate:', error);
    hideLoading();
  }
}

function renderPriceRateCharts(data) {
  if (data.length <= 1) return;
  
  const chartData = data.slice(1).slice(-30);

  function safeParseDateLabel(val) {
    var d = parseSheetDate(val);
    if (d && !isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    if (typeof val === 'string' && val.includes('/')) {
      var p = val.split(' ')[0].split('/');
      return p[0] + '/' + p[1];
    }
    return String(val).substring(0, 10);
  }

  function safeParseDateFull(val) {
    var d = parseSheetDate(val);
    if (d && !isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' });
    if (typeof val === 'string' && val.includes('/')) return val.split(' ')[0];
    return String(val).substring(0, 10);
  }

  const labels = chartData.map(function(row) { return safeParseDateLabel(row[0]); });
  var firstDate = safeParseDateFull(chartData[0][0]);
  var lastDate = safeParseDateFull(chartData[chartData.length - 1][0]);
  var rangeEl = document.getElementById('priceRateDateRange');
  if (rangeEl) rangeEl.textContent = firstDate + ' — ' + lastDate;
  
  const thbSellValues = chartData.map(row => parseFloat(row[1]) || 0);
  const thbBuyValues = chartData.map(row => parseFloat(row[3]) || 0);
  const usdSellValues = chartData.map(row => parseFloat(row[2]) || 0);
  const usdBuyValues = chartData.map(row => parseFloat(row[4]) || 0);
  
  var makeOpts = function(yTitle) {
    return {
      responsive: true,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#ccc', font: { size: 12 } } },
        tooltip: {
          callbacks: {
            title: function(items) { return labels[items[0].dataIndex]; },
            label: function(ctx) { return ctx.dataset.label + ': ' + formatNumber(ctx.parsed.y) + ' LAK'; }
          }
        }
      },
      scales: {
        x: { display: false },
        y: { title: { display: true, text: yTitle, color: '#ccc', font: { size: 13 } }, ticks: { color: '#999', callback: function(v) { return formatNumber(v); } }, grid: { color: 'rgba(255,255,255,0.1)' } }
      }
    };
  };
  
  if (thbChartInstance) thbChartInstance.destroy();
  if (usdChartInstance) usdChartInstance.destroy();
  
  const thbCtx = document.getElementById('thbChart').getContext('2d');
  thbChartInstance = new Chart(thbCtx, {
    type: 'line',
    data: {
      labels,
      datasets: [
        { label: 'THB Sell', data: thbSellValues, borderColor: '#4caf50', backgroundColor: 'rgba(76,175,80,0.1)', tension: 0.3, fill: false, pointRadius: 3 },
        { label: 'THB Buyback', data: thbBuyValues, borderColor: '#f44336', backgroundColor: 'rgba(244,67,54,0.1)', tension: 0.3, fill: false, pointRadius: 3 }
      ]
    },
    options: makeOpts('LAK / บาท')
  });
  
  const usdCtx = document.getElementById('usdChart').getContext('2d');
  usdChartInstance = new Chart(usdCtx, {
    type: 'line',
    data: {
      labels,
      datasets: [
        { label: 'USD Sell', data: usdSellValues, borderColor: '#2196f3', backgroundColor: 'rgba(33,150,243,0.1)', tension: 0.3, fill: false, pointRadius: 3 },
        { label: 'USD Buyback', data: usdBuyValues, borderColor: '#ff9800', backgroundColor: 'rgba(255,152,0,0.1)', tension: 0.3, fill: false, pointRadius: 3 }
      ]
    },
    options: makeOpts('LAK / USD')
  });
}

async function submitPriceRate() {
  const thbSell = document.getElementById('rateTHBSellInput').value;
  const usdSell = document.getElementById('rateUSDSellInput').value;
  const thbBuy = document.getElementById('rateTHBBuyInput').value;
  const usdBuy = document.getElementById('rateUSDBuyInput').value;
  
  if (!thbSell || !usdSell || !thbBuy || !usdBuy) {
    alert('Please fill all exchange rates');
    return;
  }
  
  try {
    showLoading();
    const result = await callAppsScript('ADD_PRICE_RATE', {
      thbSell, usdSell, thbBuy, usdBuy
    });
    
    if (result.success) {
      alert('✅ Price rate updated successfully!');
      closeModal('priceRateModal');
      document.getElementById('rateTHBSellInput').value = '';
      document.getElementById('rateUSDSellInput').value = '';
      document.getElementById('rateTHBBuyInput').value = '';
      document.getElementById('rateUSDBuyInput').value = '';
      loadPriceRate();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

function openPriceRateModal() {
  document.getElementById('rateTHBSellInput').placeholder = currentPriceRates.thbSell || 0;
  document.getElementById('rateUSDSellInput').placeholder = currentPriceRates.usdSell || 0;
  document.getElementById('rateTHBBuyInput').placeholder = currentPriceRates.thbBuy || 0;
  document.getElementById('rateUSDBuyInput').placeholder = currentPriceRates.usdBuy || 0;
  openModal('priceRateModal');
}