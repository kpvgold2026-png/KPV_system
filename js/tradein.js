async function loadTradeins() {
  try {
    var tbody = document.getElementById('tradeinTable');
    tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';
    const data = await fetchSheetData('Tradeins!A:T');
    
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
          var focGoldStr = row[16] ? formatItemsForTable(row[16]) : '-';
          var pureOldGold = row[16] ? formatItemsForTable(subtractItems(row[2], row[16])) : oldGold;
          var focPremDeduct = row[17] ? formatNumber(row[17]) + ' LAK' : '-';
          var focBillRef = row[18] || '-';
          var detail = encodeURIComponent(JSON.stringify([['Transaction ID', row[0]], ['BILL ID', row[19] || '-'], ['Phone', row[1]], ['F.O.C รหัสบิลเก่า', focBillRef], ['F.O.C (Old Gold)', focGoldStr], ['Old Gold', pureOldGold], ['New Gold', newGold], ['Difference', formatNumber(row[4]) + ' LAK'], ['Premium', formatNumber(premium) + ' LAK'], ['FOC Premium หัก', focPremDeduct], ['Total', formatNumber(row[6]) + ' LAK'], ['Customer Paid', tiPayInfo], ['Change', tiChange > 0 ? formatNumber(tiChange) + ' LAK' : '-'], ['Date', formatDateTime(row[11])], ['Status', status], ['Sale', saleName]]));
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

function addTradeinFocGold() {
  tradeinFocCounter++;
  var container = document.getElementById('tradeinFocGold');
  var row = document.createElement('div');
  row.className = 'product-row';
  row.id = 'tradeinFoc' + tradeinFocCounter;
  row.innerHTML = '<select class="form-select" onchange="updateTradeinTotal()"><option value="">เลือกสินค้า...</option>' + FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') + '</select><input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="updateTradeinTotal()"><button type="button" class="btn-remove" onclick="removeTradeinFocGold(' + tradeinFocCounter + ')">×</button>';
  container.appendChild(row);
}

function removeTradeinFocGold(id) {
  var row = document.getElementById('tradeinFoc' + id);
  if (row) row.remove();
  updateTradeinTotal();
}

function addTradeinOldGold() {
  tradeinOldCounter++;
  var container = document.getElementById('tradeinOldGold');
  var row = document.createElement('div');
  row.className = 'product-row';
  row.id = 'tradeinOld' + tradeinOldCounter;
  row.innerHTML = '<select class="form-select" onchange="updateTradeinTotal()"><option value="">เลือกสินค้า...</option>' + FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') + '</select><input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="updateTradeinTotal()"><button type="button" class="btn-remove" onclick="removeTradeinOldGold(' + tradeinOldCounter + ')">×</button>';
  container.appendChild(row);
}

function removeTradeinOldGold(id) {
  var row = document.getElementById('tradeinOld' + id);
  if (row) row.remove();
  updateTradeinTotal();
}

function addTradeinNewGold() {
  tradeinNewCounter++;
  var container = document.getElementById('tradeinNewGold');
  var row = document.createElement('div');
  row.className = 'product-row';
  row.id = 'tradeinNew' + tradeinNewCounter;
  row.innerHTML = '<select class="form-select" onchange="updateTradeinTotal()"><option value="">เลือกสินค้า...</option>' + FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('') + '</select><input type="number" class="form-input" placeholder="จำนวน" min="1" step="1" oninput="updateTradeinTotal()"><button type="button" class="btn-remove" onclick="removeTradeinNewGold(' + tradeinNewCounter + ')">×</button>';
  container.appendChild(row);
}

function removeTradeinNewGold(id) {
  var row = document.getElementById('tradeinNew' + id);
  if (row) row.remove();
  updateTradeinTotal();
}

function collectItems(containerId) {
  var items = [];
  document.querySelectorAll('#' + containerId + ' .product-row').forEach(function(row) {
    var pid = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (pid && qty > 0) items.push({ productId: pid, qty: qty });
  });
  return items;
}

function updateTradeinTotal() {
  var focItems = collectItems('tradeinFocGold');
  var oldItems = collectItems('tradeinOldGold');
  var newItems = collectItems('tradeinNewGold');

  var focWeight = 0, oldWeight = 0, newWeight = 0;
  var focPremium = 0, newPremium = 0;

  focItems.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) focWeight += p.weight * item.qty;
    if (PREMIUM_PRODUCTS.includes(item.productId)) focPremium += PREMIUM_PER_PIECE * item.qty;
  });
  oldItems.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) oldWeight += p.weight * item.qty;
  });
  newItems.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) newWeight += p.weight * item.qty;
    if (PREMIUM_PRODUCTS.includes(item.productId)) newPremium += PREMIUM_PER_PIECE * item.qty;
  });

  var totalOldWeight = focWeight + oldWeight;
  var premium = newPremium;
  if (newPremium > 0 && focPremium > 0) {
    premium = Math.max(0, newPremium - focPremium);
  }

  var total = 0;
  var diffValue = 0;
  if (newWeight > totalOldWeight && currentPricing.sell1Baht > 0) {
    diffValue = (newWeight - totalOldWeight) * currentPricing.sell1Baht;
    total = roundTo1000(Math.round(diffValue) + premium);
  }

  var el = document.getElementById('tradeinPrice');
  if (el) el.value = total > 0 ? formatNumber(total) + ' LAK' : '0';

  var detail = document.getElementById('tradeinPriceDetail');
  if (detail) {
    var lines = [];
    lines.push('ทองใหม่: ' + newWeight.toFixed(3) + ' บาท | ทองเก่ารวม: ' + totalOldWeight.toFixed(3) + ' บาท (FOC: ' + focWeight.toFixed(3) + ' + Old: ' + oldWeight.toFixed(3) + ')');
    lines.push('ส่วนต่าง: ' + formatNumber(Math.round(diffValue)) + ' LAK');
    if (newPremium > 0) lines.push('Premium ทองใหม่: ' + formatNumber(newPremium) + (focPremium > 0 ? ' - FOC Premium: ' + formatNumber(focPremium) + ' = ' + formatNumber(premium) : ''));
    detail.innerHTML = lines.join('<br>');
  }
}

async function calculateTradein() {
  if (_isSubmitting) return;
  var phone = document.getElementById('tradeinPhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 8) {
    alert('กรุณากรอกเบอร์โทร 8 หลัก');
    return;
  }
  var billId = document.getElementById('tradeinBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) {
    alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก');
    return;
  }

  var focGold = mergeItems(collectItems('tradeinFocGold'));
  var oldGold = mergeItems(collectItems('tradeinOldGold'));
  var newGold = mergeItems(collectItems('tradeinNewGold'));

  if (oldGold.length === 0 && focGold.length === 0) {
    alert('กรุณาเลือกทองเก่าอย่างน้อย 1 รายการ');
    return;
  }
  if (newGold.length === 0) {
    alert('กรุณาเลือกทองใหม่');
    return;
  }
  if (focGold.length > 0) {
    var focRef = document.getElementById('tradeinFocBillRef') ? document.getElementById('tradeinFocBillRef').value.trim() : '';
    if (!focRef) {
      alert('กรุณากรอกรหัสบิลเก่าสำหรับ F.O.C');
      return;
    }
  }

  var focWeight = 0, oldWeight = 0, newWeight = 0;
  var focPremium = 0, newPremium = 0;

  focGold.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) focWeight += p.weight * item.qty;
    if (PREMIUM_PRODUCTS.includes(item.productId)) focPremium += PREMIUM_PER_PIECE * item.qty;
  });
  oldGold.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) oldWeight += p.weight * item.qty;
  });
  newGold.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) newWeight += p.weight * item.qty;
    if (PREMIUM_PRODUCTS.includes(item.productId)) newPremium += PREMIUM_PER_PIECE * item.qty;
  });

  var totalOldWeight = focWeight + oldWeight;
  if (newWeight <= totalOldWeight) {
    alert('❌ น้ำหนักทองใหม่ต้องมากกว่าทองเก่ารวม!\nทองเก่ารวม (FOC+Old): ' + totalOldWeight.toFixed(3) + ' บาท\nทองใหม่: ' + newWeight.toFixed(3) + ' บาท');
    return;
  }

  var premium = newPremium;
  if (newPremium > 0 && focPremium > 0) {
    premium = Math.max(0, newPremium - focPremium);
  }

  var difference = (newWeight - totalOldWeight) * currentPricing.sell1Baht;
  var total = roundTo1000(Math.round(difference) + premium);

  var allOldGold = mergeItems(focGold.concat(oldGold));

  try {
    _isSubmitting = true;
    showLoading();
    var focBillRef = document.getElementById('tradeinFocBillRef') ? document.getElementById('tradeinFocBillRef').value.trim() : '';
    var result = await callAppsScript('ADD_TRADEIN', {
      phone: phone,
      oldGold: JSON.stringify(allOldGold),
      newGold: JSON.stringify(newGold),
      focGold: JSON.stringify(focGold),
      focBillRef: focBillRef,
      billId: billId,
      difference: difference,
      premium: premium,
      focPremiumDeduct: Math.min(focPremium, newPremium),
      total: total,
      sell1Baht: currentPricing.sell1Baht,
      user: currentUser.nickname
    });

    if (result.success) {
      endSubmit();
      showToast('✅ สร้างรายการแลกเปลี่ยนสำเร็จ!');
      closeModal('tradeinModal');
      document.getElementById('tradeinPhone').value = '';
      if (document.getElementById('tradeinBillId')) document.getElementById('tradeinBillId').value = '';
      if (document.getElementById('tradeinFocBillRef')) document.getElementById('tradeinFocBillRef').value = '';
      document.getElementById('tradeinFocGold').innerHTML = '';
      document.getElementById('tradeinOldGold').innerHTML = '';
      document.getElementById('tradeinNewGold').innerHTML = '';
      tradeinFocCounter = 0;
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