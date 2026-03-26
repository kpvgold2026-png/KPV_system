async function loadTradeins() {
  try {
    var tbody = document.getElementById('tradeinTable');
    tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';
    const data = await fetchSheetData('Tradeins!A:N');
    
    let filteredData = data.slice(1);
    
    if (currentUser.role === 'User' || isManager()) {
      if (tradeinDateFrom || tradeinDateTo) {
        filteredData = filterByDateRange(filteredData, 11, 13, tradeinDateFrom, tradeinDateTo);
      } else {
        filteredData = filterTodayData(filteredData, 11, 13);
      }
    }
    
    if (tradeinSortOrder === 'asc') {
      filteredData.sort((a, b) => new Date(a[11]) - new Date(b[11]));
    } else {
      filteredData.sort((a, b) => new Date(b[11]) - new Date(a[11]));
    }
    
    tbody = document.getElementById('tradeinTable');
    if (filteredData.length === 0) {
      tbody.innerHTML = '<tr><td colspan="10" style="text-align: center; padding: 40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = filteredData.map(row => {
        const oldGold = formatItemsForTable(row[2]);
        const newGold = formatItemsForTable(row[3]);
        const premium = calculatePremiumFromItems(row[3]);
        const saleName = row[13];
        const status = row[12];
        
        let actions = '';
        
        if (status === 'PENDING') {
          if (isManager()) {
            actions = `<button class="btn-action" onclick="reviewTradein('${row[0]}')">Review</button>`;
          } else {
            actions = '<span style="color: var(--text-secondary);">Waiting for review</span>';
          }
        } else if (status === 'READY') {
          if (currentUser.role === 'User') {
            actions = `<button class="btn-action" onclick="openTradeinPaymentModal('${row[0]}')">Confirm</button>`;
          } else {
            actions = '<span style="color: var(--text-secondary);">Waiting for confirmation</span>';
          }
        } else {
          var tiPaid = parseFloat(row[7]) || 0;
          var tiChange = parseFloat(row[10]) || 0;
          var tiPayInfo = tiPaid > 0 ? formatNumber(tiPaid) + ' ' + (row[8] || 'LAK') : '-';
          var detail = encodeURIComponent(JSON.stringify([['Transaction ID', row[0]], ['Phone', row[1]], ['Old Gold', oldGold], ['New Gold', newGold], ['Difference', formatNumber(row[4]) + ' LAK'], ['Premium', formatNumber(premium) + ' LAK'], ['Total', formatNumber(row[6]) + ' LAK'], ['Customer Paid', tiPayInfo], ['Change', tiChange > 0 ? formatNumber(tiChange) + ' LAK' : '-'], ['Date', formatDateTime(row[11])], ['Status', status], ['Sale', saleName]]));
          actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Trade-in\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
        }
        
        return `
          <tr>
            <td>${row[0]}</td>
            <td style="font-size:11px;white-space:nowrap;">${row[11] || ''}</td>
            <td>${row[1]}</td>
            <td>${oldGold}</td>
            <td>${newGold}</td>
            <td>${formatNumber(row[4])}</td>
            <td>${formatNumber(premium)}</td>
            <td>${formatNumber(row[6])}</td>
            <td><span class="status-badge status-${status.toLowerCase()}">${status}</span></td>
            <td>${saleName}</td>
            <td>${actions}</td>
          </tr>
        `;
      }).join('');
    }
  } catch (error) {
  }
}

function addTradeinOldGold() {
  tradeinOldCounter++;
  const container = document.getElementById('tradeinOldGold');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.id = `tradeinOld${tradeinOldCounter}`;
  row.innerHTML = `
    <select class="form-select" onchange="updateTradeinTotal()">
      <option value="">เลือกสินค้า...</option>
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="updateTradeinTotal()">
    <button type="button" class="btn-remove" onclick="removeTradeinOldGold(${tradeinOldCounter})">×</button>
  `;
  container.appendChild(row);
}

function removeTradeinOldGold(id) {
  const row = document.getElementById(`tradeinOld${id}`);
  if (row) row.remove();
  updateTradeinTotal();
}

function addTradeinNewGold() {
  tradeinNewCounter++;
  const container = document.getElementById('tradeinNewGold');
  const row = document.createElement('div');
  row.className = 'product-row';
  row.id = `tradeinNew${tradeinNewCounter}`;
  row.innerHTML = `
    <select class="form-select" onchange="updateTradeinTotal()">
      <option value="">เลือกสินค้า...</option>
      ${FIXED_PRODUCTS.map(p => `<option value="${p.id}">${p.name}</option>`).join('')}
    </select>
    <input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="updateTradeinTotal()">
    <button type="button" class="btn-remove" onclick="removeTradeinNewGold(${tradeinNewCounter})">×</button>
  `;
  container.appendChild(row);
}

function removeTradeinNewGold(id) {
  const row = document.getElementById(`tradeinNew${id}`);
  if (row) row.remove();
  updateTradeinTotal();
}

function updateTradeinTotal() {
  var oldWeight = 0, newWeight = 0, premium = 0;
  document.querySelectorAll('#tradeinOldGold .product-row').forEach(function(row) {
    var pid = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (pid && qty > 0) {
      var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === pid; });
      if (p) oldWeight += p.weight * qty;
    }
  });
  document.querySelectorAll('#tradeinNewGold .product-row').forEach(function(row) {
    var pid = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (pid && qty > 0) {
      var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === pid; });
      if (p) newWeight += p.weight * qty;
      if (PREMIUM_PRODUCTS.includes(pid)) premium += PREMIUM_PER_PIECE * qty;
    }
  });
  var total = 0;
  if (newWeight > oldWeight && currentPricing.sell1Baht > 0) {
    var diff = (newWeight - oldWeight) * currentPricing.sell1Baht;
    total = roundTo1000(diff + premium);
  }
  var el = document.getElementById('tradeinPrice');
  if (el) el.value = total > 0 ? formatNumber(total) + ' LAK' : '0';
}

async function calculateTradein() {
  if (_isSubmitting) return;
  const phone = document.getElementById('tradeinPhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 10) {
    alert('กรุณากรอกเบอร์โทร 10 หลัก');
    return;
  }

  const oldGold = [];
  document.querySelectorAll('#tradeinOldGold .product-row').forEach(row => {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) {
      oldGold.push({ productId, qty });
    }
  });

  const newGold = [];
  document.querySelectorAll('#tradeinNewGold .product-row').forEach(row => {
    const productId = row.querySelector('select').value;
    const qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) {
      newGold.push({ productId, qty });
    }
  });

  if (oldGold.length === 0 || newGold.length === 0) {
    alert('กรุณาเลือกทองเก่าและทองใหม่');
    return;
  }

  let oldWeight = 0;
  oldGold.forEach(item => {
    const product = FIXED_PRODUCTS.find(p => p.id === item.productId);
    console.log('Old Gold:', product.name, 'weight:', product.weight, 'qty:', item.qty);
    oldWeight += product.weight * item.qty;
  });

  let newWeight = 0;
  let premium = 0;

  newGold.forEach(item => {
    const product = FIXED_PRODUCTS.find(p => p.id === item.productId);
    console.log('New Gold:', product.name, 'weight:', product.weight, 'qty:', item.qty);
    newWeight += product.weight * item.qty;
    
    if (PREMIUM_PRODUCTS.includes(item.productId)) {
      premium += PREMIUM_PER_PIECE * item.qty;
    }
  });

  console.log('=== TRADE-IN CALCULATION ===');
  console.log('Old Weight:', oldWeight, 'บาท');
  console.log('New Weight:', newWeight, 'บาท');
  console.log('Weight Difference:', newWeight - oldWeight, 'บาท');
  console.log('Sell 1 Baht:', currentPricing.sell1Baht, 'LAK');
  console.log('Difference Value:', (newWeight - oldWeight) * currentPricing.sell1Baht, 'LAK');
  console.log('Premium:', premium, 'LAK');

  if (newWeight <= oldWeight) {
    alert('❌ น้ำหนักทองใหม่ต้องมากกว่าทองเก่า!\nทองเก่า: ' + oldWeight.toFixed(3) + ' บาท\nทองใหม่: ' + newWeight.toFixed(3) + ' บาท');
    return;
  }
  
  const weightDifference = newWeight - oldWeight;
  const difference = weightDifference * currentPricing.sell1Baht;
  const total = roundTo1000(difference + premium);

  console.log('FINAL - difference:', difference, 'LAK');
  console.log('FINAL - premium:', premium, 'LAK');
  console.log('FINAL - total:', total, 'LAK');
  console.log('===========================');

  try {
    _isSubmitting = true;
    showLoading();
    const result = await callAppsScript('ADD_TRADEIN', {
      phone,
      oldGold: JSON.stringify(mergeItems(oldGold)),
      newGold: JSON.stringify(mergeItems(newGold)),
      difference,
      premium,
      total,
      sell1Baht: currentPricing.sell1Baht,
      user: currentUser.nickname
    });
    
    if (result.success) {
      endSubmit();
      showToast('✅ สร้างรายการแลกเปลี่ยนสำเร็จ!');
      closeModal('tradeinModal');
      document.getElementById('tradeinPhone').value = '';
      document.getElementById('tradeinOldGold').innerHTML = '';
      document.getElementById('tradeinNewGold').innerHTML = '';
      tradeinOldCounter = 0;
      tradeinNewCounter = 0;
      addTradeinOldGold();
      addTradeinNewGold();
      loadTradeins();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + result.message);
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function loadCurrentPricing() {
  try {
    const pricingData = await fetchSheetData('Pricing!A:B');
    
    if (pricingData.length > 1) {
      const latestPricing = pricingData[pricingData.length - 1];
      currentPricing = {
        sell1Baht: parseFloat(String(latestPricing[1]).replace(/,/g, '')) || 0,
        buyback1Baht: 0
      };
      
      console.log('Loaded currentPricing:', currentPricing);
      return true;
    }
    return false;
  } catch (error) {
    console.error('Error loading pricing:', error);
    return false;
  }
}

async function openTradeinModal() {
  const hasPrice = await loadCurrentPricing();
  
  if (!hasPrice || !currentPricing.sell1Baht || currentPricing.sell1Baht === 0) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  
  openModal('tradeinModal');
}


function resetTradeinDateFilter() {
  const today = getTodayDateString();
  document.getElementById('tradeinDateFrom').value = today;
  document.getElementById('tradeinDateTo').value = today;
  tradeinDateFrom = today;
  tradeinDateTo = today;
  loadTradeins();
}

document.addEventListener('DOMContentLoaded', function() {
  const fromInput = document.getElementById('tradeinDateFrom');
  const toInput = document.getElementById('tradeinDateTo');
  
  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      tradeinDateFrom = this.value;
      if (tradeinDateFrom && !tradeinDateTo) { tradeinDateTo = tradeinDateFrom; toInput.value = tradeinDateTo; }
      if (tradeinDateFrom && tradeinDateTo) loadTradeins();
    });
    
    toInput.addEventListener('change', function() {
      tradeinDateTo = this.value;
      if (tradeinDateTo && !tradeinDateFrom) { tradeinDateFrom = tradeinDateTo; fromInput.value = tradeinDateFrom; }
      if (tradeinDateFrom && tradeinDateTo) loadTradeins();
    });
  }
});

let currentTradeinPayment = null;
