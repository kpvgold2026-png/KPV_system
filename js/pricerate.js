let thbChartInstance = null;
let usdChartInstance = null;

async function loadPriceRate() {
  try {
    showLoading();
    var data = await dbSelect('price_rates', {
      select: 'date,thb_sell,usd_sell,thb_buy,usd_buy,updated_by,user:users!updated_by(nickname)',
      order: 'date.desc',
      limit: 100,
      useCache: false
    });

    if (data && data.length > 0) {
      var latest = data[0];
      currentPriceRates = {
        thbSell: parseFloat(latest.thb_sell) || 0,
        usdSell: parseFloat(latest.usd_sell) || 0,
        thbBuy: parseFloat(latest.thb_buy) || 0,
        usdBuy: parseFloat(latest.usd_buy) || 0
      };
      document.getElementById('rateTHBSell').textContent = formatCurrency(currentPriceRates.thbSell, 'THB');
      document.getElementById('rateUSDSell').textContent = formatCurrency(currentPriceRates.usdSell, 'USD');
      document.getElementById('rateTHBBuy').textContent = formatCurrency(currentPriceRates.thbBuy, 'THB');
      document.getElementById('rateUSDBuy').textContent = formatCurrency(currentPriceRates.usdBuy, 'USD');
    }

    var tbody = document.getElementById('priceRateTable');
    if (!data || data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" style="text-align: center; padding: 40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = data.slice(0, 30).map(function(row) {
        var by = row.user ? row.user.nickname : '';
        return '<tr>' +
          '<td>' + formatDateTime(row.date) + '</td>' +
          '<td>' + formatCurrency(row.thb_sell, 'THB') + '</td>' +
          '<td>' + formatCurrency(row.usd_sell, 'USD') + '</td>' +
          '<td>' + formatCurrency(row.thb_buy, 'THB') + '</td>' +
          '<td>' + formatCurrency(row.usd_buy, 'USD') + '</td>' +
          '<td>' + by + '</td>' +
          '</tr>';
      }).join('');
    }

    renderPriceRateCharts(data);
    hideLoading();
  } catch (error) {
    console.error('Error loading price rate:', error);
    hideLoading();
  }
}

function renderPriceRateCharts(data) {
  if (!data || data.length === 0) return;

  var chartData = data.slice().reverse().slice(-30);

  function safeLabel(val) {
    var d = new Date(val);
    if (!isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short' });
    return String(val).substring(0, 10);
  }
  function safeFull(val) {
    var d = new Date(val);
    if (!isNaN(d.getTime())) return d.toLocaleDateString('th-TH', { day: '2-digit', month: 'short', year: 'numeric' });
    return String(val).substring(0, 10);
  }

  var labels = chartData.map(function(row) { return safeLabel(row.date); });
  var firstDate = safeFull(chartData[0].date);
  var lastDate = safeFull(chartData[chartData.length - 1].date);
  var rangeEl = document.getElementById('priceRateDateRange');
  if (rangeEl) rangeEl.textContent = firstDate + ' — ' + lastDate;

  var thbSellValues = chartData.map(function(row) { return parseFloat(row.thb_sell) || 0; });
  var thbBuyValues = chartData.map(function(row) { return parseFloat(row.thb_buy) || 0; });
  var usdSellValues = chartData.map(function(row) { return parseFloat(row.usd_sell) || 0; });
  var usdBuyValues = chartData.map(function(row) { return parseFloat(row.usd_buy) || 0; });

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

  var thbCtx = document.getElementById('thbChart').getContext('2d');
  thbChartInstance = new Chart(thbCtx, {
    type: 'line',
    data: { labels: labels, datasets: [
      { label: 'THB Sell', data: thbSellValues, borderColor: '#4caf50', backgroundColor: 'rgba(76,175,80,0.1)', tension: 0.3, fill: false, pointRadius: 3 },
      { label: 'THB Buyback', data: thbBuyValues, borderColor: '#f44336', backgroundColor: 'rgba(244,67,54,0.1)', tension: 0.3, fill: false, pointRadius: 3 }
    ]},
    options: makeOpts('LAK / บาท')
  });

  var usdCtx = document.getElementById('usdChart').getContext('2d');
  usdChartInstance = new Chart(usdCtx, {
    type: 'line',
    data: { labels: labels, datasets: [
      { label: 'USD Sell', data: usdSellValues, borderColor: '#2196f3', backgroundColor: 'rgba(33,150,243,0.1)', tension: 0.3, fill: false, pointRadius: 3 },
      { label: 'USD Buyback', data: usdBuyValues, borderColor: '#ff9800', backgroundColor: 'rgba(255,152,0,0.1)', tension: 0.3, fill: false, pointRadius: 3 }
    ]},
    options: makeOpts('LAK / USD')
  });
}

async function submitPriceRate() {
  var thbSellEl = document.getElementById('rateTHBSellInput');
  var usdSellEl = document.getElementById('rateUSDSellInput');
  var thbBuyEl = document.getElementById('rateTHBBuyInput');
  var usdBuyEl = document.getElementById('rateUSDBuyInput');

  function readRate(el) {
    var raw = String(el.value || '').replace(/[^0-9.\-]/g, '');
    return parseFloat(raw) || 0;
  }

  var thbSell = readRate(thbSellEl);
  var usdSell = readRate(usdSellEl);
  var thbBuy = readRate(thbBuyEl);
  var usdBuy = readRate(usdBuyEl);

  if (!thbSell && !usdSell && !thbBuy && !usdBuy) {
    alert('กรุณากรอกค่าเงินอย่างน้อย 1 ช่อง');
    return;
  }

  var finalThbSell = thbSell || currentPriceRates.thbSell || 0;
  var finalUsdSell = usdSell || currentPriceRates.usdSell || 0;
  var finalThbBuy = thbBuy || currentPriceRates.thbBuy || 0;
  var finalUsdBuy = usdBuy || currentPriceRates.usdBuy || 0;

  try {
    showLoading();
    var result = await dbRpc('add_price_rate', {
      p_thb_sell: finalThbSell,
      p_usd_sell: finalUsdSell,
      p_thb_buy: finalThbBuy,
      p_usd_buy: finalUsdBuy
    });
    hideLoading();
    if (result && result.success) {
      showToast('✅ อัพเดตค่าเงินสำเร็จ!');
      closeModal('priceRateModal');
      document.getElementById('rateTHBSellInput').value = '';
      document.getElementById('rateUSDSellInput').value = '';
      document.getElementById('rateTHBBuyInput').value = '';
      document.getElementById('rateUSDBuyInput').value = '';
      invalidateCache();
      await batchFetchAll();
      await fetchExchangeRates();
      loadPriceRate();
      if (typeof loadSalesInfoBar === 'function') loadSalesInfoBar();
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
  }
}

function openPriceRateModal() {
  document.getElementById('rateTHBSellInput').placeholder = currentPriceRates.thbSell || 0;
  document.getElementById('rateUSDSellInput').placeholder = currentPriceRates.usdSell || 0;
  document.getElementById('rateTHBBuyInput').placeholder = currentPriceRates.thbBuy || 0;
  document.getElementById('rateUSDBuyInput').placeholder = currentPriceRates.usdBuy || 0;
  openModal('priceRateModal');
}
