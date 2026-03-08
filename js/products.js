let pricingChartInstance = null;

async function loadProducts() {
  try {
    showLoading();
    
    const pricingData = await fetchSheetData('Pricing!A:B');
    
    if (pricingData.length > 1) {
      const latestPricing = pricingData[pricingData.length - 1];
      currentPricing = {
        sell1Baht: parseFloat(String(latestPricing[1]).replace(/,/g, '')) || 0,
        buyback1Baht: 0
      };
      
      document.getElementById('currentPriceDisplay').textContent = formatNumber(currentPricing.sell1Baht) + ' LAK';
    }
    
    const unitLabels = {
      'G01': '10B',
      'G02': '5B',
      'G03': '2B',
      'G04': '1B',
      'G05': '0.5B',
      'G06': '0.25B',
      'G07': '1g'
    };
    
    const tbody = document.getElementById('productsTable');
    tbody.innerHTML = FIXED_PRODUCTS.map(product => {
      const sellPrice = calculateSellPrice(product.id, currentPricing.sell1Baht);
      const buybackPrice = calculateBuybackPrice(product.id, currentPricing.sell1Baht);
      const exchangeFee = EXCHANGE_FEES[product.id];
      const switchFee = EXCHANGE_FEES_SWITCH[product.id];
      const unit = unitLabels[product.id] || product.unit;
      
      return `
        <tr>
          <td>${product.id}</td>
          <td>${product.name}</td>
          <td>${unit}</td>
          <td>${formatNumber(sellPrice)}</td>
          <td>${formatNumber(buybackPrice)}</td>
          <td>${formatNumber(exchangeFee)}</td>
          <td>${formatNumber(switchFee)}</td>
        </tr>
      `;
    }).join('');
    
    renderPricingChart(pricingData);
    await loadPriceHistory();
    
    hideLoading();
  } catch (error) {
    hideLoading();
  }
}

function renderPricingChart(data) {
  if (data.length <= 1) return;

  var chartData = data.slice(1).slice(-30);

  var labels = chartData.map(function(row) {
    var d = parseSheetDate(row[0]);
    if (d && !isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    return String(row[0]).substring(0, 10);
  });

  var firstD = parseSheetDate(chartData[0][0]);
  var lastD = parseSheetDate(chartData[chartData.length - 1][0]);
  var rangeEl = document.getElementById('pricingDateRange');
  if (rangeEl) {
    var fmt = function(d) { return d ? d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' }) : ''; };
    rangeEl.textContent = fmt(firstD) + ' — ' + fmt(lastD);
  }

  var values = chartData.map(function(row) { return parseFloat(row[1]) || 0; });

  if (pricingChartInstance) pricingChartInstance.destroy();

  var ctx = document.getElementById('pricingChart').getContext('2d');
  pricingChartInstance = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label: 'Sell 1 Baht',
        data: values,
        borderColor: '#d4af37',
        backgroundColor: 'rgba(212,175,55,0.15)',
        tension: 0.3,
        fill: true,
        pointRadius: 4,
        pointBackgroundColor: '#d4af37'
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#ccc', font: { size: 12 } } },
        tooltip: { callbacks: { label: function(ctx) { return 'Sell 1 Baht: ' + formatNumber(ctx.parsed.y) + ' LAK'; } } }
      },
      scales: {
        x: { display: false },
        y: { title: { display: true, text: 'LAK', color: '#ccc' }, ticks: { color: '#999', callback: function(v) { return formatNumber(v); } }, grid: { color: 'rgba(255,255,255,0.1)' } }
      }
    }
  });
}

async function loadPriceHistory() {
  try {
    const data = await fetchSheetData('Pricing!A:C');
    const tbody = document.getElementById('priceHistoryTable');
    
    if (data.length <= 1) {
      tbody.innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }
    
    tbody.innerHTML = data.slice(1).reverse().slice(0, 30).map(row => `
      <tr>
        <td>${formatDateTime(row[0])}</td>
        <td>${formatNumber(row[1])}</td>
        <td>${row[2] || '-'}</td>
      </tr>
    `).join('');
  } catch (error) {
  }
}

async function updatePricing() {
  const sell1Baht = document.getElementById('sell1BahtPrice').value;
  
  if (!sell1Baht) {
    alert('กรุณากรอกราคา 1 บาท');
    return;
  }
  
  try {
    showLoading();
    const result = await callAppsScript('UPDATE_PRICING', {
      sell1Baht
    });
    
    if (result.success) {
      showToast('✅ อัพเดตราคาสำเร็จ!');
      closeModal('pricingModal');
      document.getElementById('sell1BahtPrice').value = '';
      loadProducts();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}