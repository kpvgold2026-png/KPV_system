let pricingChartInstance = null;

async function loadProducts() {
  try {
    showLoading();
    var data = await dbSelect('pricing', {
      select: 'date,sell_1baht,note,updated_by,user:users!updated_by(nickname)',
      order: 'date.desc',
      limit: 100,
      useCache: false
    });

    if (data && data.length > 0) {
      currentPricing = {
        sell1Baht: parseFloat(data[0].sell_1baht) || 0,
        buyback1Baht: 0
      };
      document.getElementById('currentPriceDisplay').textContent = formatNumber(currentPricing.sell1Baht) + ' LAK';
    }

    var unitLabels = {
      'G01': '10B', 'G02': '5B', 'G03': '2B', 'G04': '1B',
      'G05': '0.5B', 'G06': '0.25B', 'G07': '1g'
    };

    var tbody = document.getElementById('productsTable');
    tbody.innerHTML = FIXED_PRODUCTS.map(function(product) {
      var sellPrice = calculateSellPrice(product.id, currentPricing.sell1Baht);
      var buybackPrice = calculateBuybackPrice(product.id, currentPricing.sell1Baht);
      var exchangeFee = EXCHANGE_FEES[product.id];
      var switchFee = EXCHANGE_FEES_SWITCH[product.id];
      var unit = unitLabels[product.id] || product.unit;

      return '<tr>' +
        '<td>' + product.id + '</td>' +
        '<td>' + product.name + '</td>' +
        '<td>' + unit + '</td>' +
        '<td>' + formatNumber(sellPrice) + '</td>' +
        '<td>' + formatNumber(buybackPrice) + '</td>' +
        '<td>' + formatNumber(exchangeFee) + '</td>' +
        '<td>' + formatNumber(switchFee) + '</td>' +
        '</tr>';
    }).join('');

    renderPricingChart(data);
    await loadPriceHistory(data);

    hideLoading();
  } catch (error) {
    console.error('Error loading products:', error);
    hideLoading();
  }
}

function renderPricingChart(data) {
  if (!data || data.length === 0) return;

  var chartData = data.slice().reverse().slice(-30);

  var labels = chartData.map(function(row) {
    var d = new Date(row.date);
    if (!isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    return String(row.date).substring(0, 10);
  });

  var rangeEl = document.getElementById('pricingDateRange');
  if (rangeEl && chartData.length > 0) {
    var fmt = function(val) {
      var d = new Date(val);
      return !isNaN(d.getTime()) ? d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' }) : '';
    };
    rangeEl.textContent = fmt(chartData[0].date) + ' — ' + fmt(chartData[chartData.length - 1].date);
  }

  var values = chartData.map(function(row) { return parseFloat(row.sell_1baht) || 0; });

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

async function loadPriceHistory(data) {
  try {
    var tbody = document.getElementById('priceHistoryTable');
    if (!data || data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="3" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }
    tbody.innerHTML = data.slice(0, 30).map(function(row) {
      var by = row.user ? row.user.nickname : '';
      return '<tr>' +
        '<td>' + formatDateTime(row.date) + '</td>' +
        '<td>' + formatNumber(row.sell_1baht) + '</td>' +
        '<td>' + (row.note || by || '-') + '</td>' +
        '</tr>';
    }).join('');
  } catch (error) {
    console.error('Error loading price history:', error);
  }
}

async function updatePricing() {
  var sell1Baht = parseFloat(document.getElementById('sell1BahtPrice').value);
  if (!sell1Baht || sell1Baht <= 0) {
    alert('กรุณากรอกราคา 1 บาท');
    return;
  }

  try {
    showLoading();
    var result = await dbRpc('update_pricing', { p_sell_1baht: sell1Baht });
    hideLoading();
    if (result && result.success) {
      showToast('✅ อัพเดตราคาสำเร็จ!');
      closeModal('pricingModal');
      document.getElementById('sell1BahtPrice').value = '';
      invalidateCache();
      await batchFetchAll();
      await fetchCurrentPricing();
      loadProducts();
      if (typeof loadSalesInfoBar === 'function') loadSalesInfoBar();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}
