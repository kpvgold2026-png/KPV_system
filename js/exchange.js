var _exRowCounter = 0;
var _exFreeExVerified = false;
var _exFreeExBillData = null;

async function loadExchanges() {
  try {
    var tbody = document.getElementById('exchangeTable');
    tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';
    var data = await fetchSheetData('Exchanges!A:T');
    var filteredData = data.slice(1);
    if (currentUser.role === 'User' || isManager()) {
      if (exchangeDateFrom || exchangeDateTo) {
        filteredData = filterByDateRange(filteredData, 11, 13, exchangeDateFrom, exchangeDateTo);
      } else {
        filteredData = filterTodayData(filteredData, 11, 13);
      }
    }
    if (exchangeSortOrder === 'asc') {
      filteredData.sort(function(a, b) { return new Date(a[11]) - new Date(b[11]); });
    } else {
      filteredData.sort(function(a, b) { return new Date(b[11]) - new Date(a[11]); });
    }
    var tbody = document.getElementById('exchangeTable');
    if (filteredData.length === 0) {
      tbody.innerHTML = '<tr><td colspan="11" style="text-align:center;padding:40px;">No records</td></tr>';
    } else {
      tbody.innerHTML = filteredData.map(function(row) {
        var oldGold = formatItemsForTable(row[2]);
        var newGold = formatItemsForTable(row[3]);
        var exFee = parseFloat(row[4]) || 0;
        var switchFee = row.length > 15 ? (parseFloat(row[15]) || 0) : 0;
        var premium = parseFloat(row[5]) || 0;
        var total = row[6];
        var status = row[12] || '';
        var sale = row[13] || '';
        var actions = '';
        if (status === 'PENDING') {
          if (isManager()) {
            actions = '<button class="btn-action" onclick="reviewExchange(\'' + row[0] + '\')">Review</button>';
          } else {
            actions = '<span style="color:var(--text-secondary);">Waiting</span>';
          }
        } else if (status === 'READY') {
          if (currentUser.role === 'User') {
            actions = '<button class="btn-action" onclick="openExchangePaymentModal(\'' + row[0] + '\')">Confirm</button>';
          } else {
            actions = '<span style="color:var(--text-secondary);">Waiting</span>';
          }
        } else {
          var exPaid = parseFloat(row[7]) || 0;
          var exChange = parseFloat(row[10]) || 0;
          var exPayInfo = exPaid > 0 ? formatNumber(exPaid) + ' ' + (row[8] || 'LAK') : '-';
          var detail = encodeURIComponent(JSON.stringify([['Transaction ID', row[0]], ['Phone', row[1]], ['Old Gold (Exchange)', formatItemsForTable(row[2])], ['New Gold', formatItemsForTable(row[3])], ['Exchange Fee', formatNumber(exFee) + ' LAK'], ['Switch Old Gold', formatItemsForTable(row[14] || '')], ['Switch Fee', formatNumber(switchFee) + ' LAK'], ['Free Ex Old Gold', formatItemsForTable(row[16] || '')], ['Free Ex Bill', row[17] || '-'], ['Premium', formatNumber(premium) + ' LAK'], ['Total', formatNumber(total) + ' LAK'], ['Customer Paid', exPayInfo], ['Change', exChange > 0 ? formatNumber(exChange) + ' LAK' : '-'], ['Date', formatDateTime(row[11])], ['Status', status], ['Sale', sale]]));
          actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Exchange\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
        }
        return '<tr>' +
          '<td>' + row[0] + '</td>' +
          '<td style="font-size:11px;white-space:nowrap;">' + (row[11] || '') + '</td>' +
          '<td>' + row[1] + '</td>' +
          '<td>' + oldGold + '</td>' +
          '<td>' + newGold + '</td>' +
          '<td>' + formatNumber(exFee) + '</td>' +
          '<td>' + formatNumber(switchFee) + '</td>' +
          '<td>' + formatNumber(premium) + '</td>' +
          '<td>' + formatNumber(total) + '</td>' +
          '<td><span class="status-badge status-' + status.toLowerCase() + '">' + status + '</span></td>' +
          '<td>' + sale + '</td>' +
          '<td>' + actions + '</td></tr>';
      }).join('');
    }
  } catch (e) {
    console.error('loadExchanges error:', e);
  }
}

function addExRow(containerId) {
  _exRowCounter++;
  var rid = 'exr_' + _exRowCounter;
  var opts = FIXED_PRODUCTS.map(function(p) { return '<option value="' + p.id + '">' + p.name + '</option>'; }).join('');
  var extraChange = containerId === 'exOldFreeEx' ? ';onFreeExChanged()' : '';
  document.getElementById(containerId).insertAdjacentHTML('beforeend',
    '<div class="product-row" id="' + rid + '" data-container="' + containerId + '">' +
    '<select class="form-select" style="flex:2;" onchange="updateExTotal()' + extraChange + '"><option value="">Select</option>' + opts + '</select>' +
    '<input type="number" class="form-input" placeholder="Qty" min="1" style="flex:1;" oninput="updateExTotal()' + extraChange + '">' +
    '<button type="button" class="btn-remove" onclick="document.getElementById(\'' + rid + '\').remove();updateExTotal()' + extraChange + '">×</button></div>');
  updateExTotal();
}

function updateExTotal() {
  var newGold = getItemsFromContainer('exNewGold');
  var oldExchange = getItemsFromContainer('exOldExchange');
  var oldSwitch = getItemsFromContainer('exOldSwitch');
  var oldFreeEx = getItemsFromContainer('exOldFreeEx');

  var exFee = 0;
  oldExchange.forEach(function(item) { exFee += (EXCHANGE_FEES[item.productId] || 0) * item.qty; });

  var swFee = 0;
  oldSwitch.forEach(function(item) { swFee += (EXCHANGE_FEES_SWITCH[item.productId] || 0) * item.qty; });

  var newPrem = calcPremium(newGold);
  var freeExPrem = calcPremium(oldFreeEx);
  var premDeduct = Math.min(freeExPrem, newPrem);
  var premium = newPrem - (oldFreeEx.length > 0 ? premDeduct : 0);

  var total = roundTo1000(exFee + swFee + premium);

  var el = document.getElementById('exTotalValue');
  if (el) el.textContent = formatNumber(total) + ' LAK';

  var bd = document.getElementById('exTotalBreakdown');
  if (bd) {
    var parts = [];
    if (exFee > 0) parts.push('Exchange Fee: ' + formatNumber(exFee));
    if (swFee > 0) parts.push('Switch Fee: ' + formatNumber(swFee));
    if (premium > 0) parts.push('Premium: ' + formatNumber(premium));
    if (oldFreeEx.length > 0 && premDeduct > 0) parts.push('FreeEx หัก: -' + formatNumber(premDeduct));
    bd.textContent = parts.join(' | ');
  }
}

function getItemsFromContainer(containerId) {
  var items = [];
  document.querySelectorAll('#' + containerId + ' .product-row').forEach(function(row) {
    var pid = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (pid && qty > 0) items.push({ productId: pid, qty: qty });
  });
  return items;
}

function calcWeight(items) {
  var w = 0;
  items.forEach(function(item) {
    var p = FIXED_PRODUCTS.find(function(fp) { return fp.id === item.productId; });
    if (p) w += p.weight * item.qty;
  });
  return w;
}

function calcPremium(items) {
  var p = 0;
  items.forEach(function(item) {
    if (PREMIUM_PRODUCTS.includes(item.productId)) p += PREMIUM_PER_PIECE * item.qty;
  });
  return p;
}

function onFreeExChanged() {
  _exFreeExVerified = false;
  _exFreeExBillData = null;
  document.getElementById('exFreeExStatus').innerHTML = '<span style="color:#ff9800;">⚠ กรุณากดตรวจสอบ</span>';
}

async function verifyFreeExBill() {
  var billId = document.getElementById('exFreeExBillId').value.trim();
  var freeExItems = getItemsFromContainer('exOldFreeEx');
  var statusEl = document.getElementById('exFreeExStatus');

  if (!billId) { statusEl.innerHTML = '<span style="color:#f44336;">❌ กรุณากรอกรหัสบิล</span>'; return; }
  if (freeExItems.length === 0) { statusEl.innerHTML = '<span style="color:#f44336;">❌ กรุณาเพิ่มทองเก่า Free Ex</span>'; return; }

  try {
    showLoading();
    var sheets = ['Sells!A:M', 'Tradeins!A:O', 'Exchanges!A:T', 'Withdraws!A:J'];
    var results = await Promise.all(sheets.map(function(s) { return fetchSheetData(s); }));

    var bill = null;
    var billNewGold = null;
    var billDate = null;
    var billStatus = '';
    var freeExUsedCol = -1;
    var billSheet = '';

    for (var si = 0; si < results.length; si++) {
      var sdata = results[si];
      if (!sdata || sdata.length <= 1) continue;
      var headers = sdata[0];
      var feuCol = -1;
      for (var h = 0; h < headers.length; h++) { if (headers[h] === 'FreeEx_Used') feuCol = h; }
      for (var ri = 1; ri < sdata.length; ri++) {
        if (String(sdata[ri][0]) === billId) {
          bill = sdata[ri];
          freeExUsedCol = feuCol;
          if (si === 0) { billNewGold = sdata[ri][2]; billDate = sdata[ri][9]; billStatus = String(sdata[ri][10] || ''); billSheet = 'Sells'; }
          else if (si === 1) { billNewGold = sdata[ri][3]; billDate = sdata[ri][11]; billStatus = String(sdata[ri][12] || ''); billSheet = 'Tradeins'; }
          else if (si === 2) { billNewGold = sdata[ri][3]; billDate = sdata[ri][11]; billStatus = String(sdata[ri][12] || ''); billSheet = 'Exchanges'; }
          else if (si === 3) { billNewGold = sdata[ri][2]; billDate = sdata[ri][6]; billStatus = String(sdata[ri][7] || ''); billSheet = 'Withdraws'; }
          break;
        }
      }
      if (bill) break;
    }

    hideLoading();

    if (!bill) { statusEl.innerHTML = '<span style="color:#f44336;">❌ ไม่พบบิล ' + billId + '</span>'; return; }

    if (billStatus !== 'COMPLETED' && billStatus !== 'PAID') {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้สถานะ ' + billStatus + ' (ต้องเป็น COMPLETED)</span>';
      return;
    }

    if (freeExUsedCol >= 0 && bill[freeExUsedCol] && String(bill[freeExUsedCol]).trim() !== '') {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้ถูกนำไปแลก Free Ex แล้ว (' + bill[freeExUsedCol] + ')</span>';
      return;
    }

    var bd = parseSheetDate(billDate);
    if (bd) {
      var now = new Date();
      var diffDays = (now - bd) / (1000 * 60 * 60 * 24);
      if (diffDays > 30) {
        statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้เกิน 1 เดือนแล้ว (' + Math.floor(diffDays) + ' วัน)</span>';
        return;
      }
    }

    var billItems = {};
    try {
      JSON.parse(billNewGold).forEach(function(item) {
        if (!billItems[item.productId]) billItems[item.productId] = 0;
        billItems[item.productId] += item.qty;
      });
    } catch(e) {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ ไม่สามารถอ่านข้อมูลทองจากบิลได้</span>';
      return;
    }

    for (var fi = 0; fi < freeExItems.length; fi++) {
      var fItem = freeExItems[fi];
      var available = billItems[fItem.productId] || 0;
      if (fItem.qty > available) {
        statusEl.innerHTML = '<span style="color:#f44336;">❌ ' + fItem.productId + ' ในบิลมี ' + available + ' ชิ้น แต่กรอก ' + fItem.qty + ' ชิ้น</span>';
        return;
      }
    }

    _exFreeExVerified = true;
    _exFreeExBillData = { billId: billId, sheet: billSheet };
    statusEl.innerHTML = '<span style="color:#4caf50;">✅ ตรวจสอบผ่าน — บิล ' + billId + ' (' + billSheet + ')</span>';

  } catch(e) {
    hideLoading();
    statusEl.innerHTML = '<span style="color:#f44336;">❌ ' + e.message + '</span>';
  }
}

async function calculateExchangeNew() {
  if (_isSubmitting) return;
  var phone = document.getElementById('exchangePhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 10) { alert('กรุณากรอกเบอร์โทร 10 หลัก'); return; }

  var newGold = getItemsFromContainer('exNewGold');
  var oldExchange = getItemsFromContainer('exOldExchange');
  var oldSwitch = getItemsFromContainer('exOldSwitch');
  var oldFreeEx = getItemsFromContainer('exOldFreeEx');

  if (newGold.length === 0) { alert('กรุณาเพิ่มทองใหม่'); return; }
  if (oldExchange.length === 0 && oldSwitch.length === 0 && oldFreeEx.length === 0) { alert('กรุณาเพิ่มทองเก่าอย่างน้อย 1 section'); return; }

  var newW = calcWeight(newGold);
  var oldW = calcWeight(oldExchange) + calcWeight(oldSwitch) + calcWeight(oldFreeEx);

  if (Math.abs(newW - oldW) > 0.001) {
    alert('❌ น้ำหนักทองเก่าและทองใหม่ต้องเท่ากัน!\nทองใหม่: ' + (newW * 15).toFixed(3) + ' g\nทองเก่ารวม: ' + (oldW * 15).toFixed(3) + ' g');
    return;
  }

  var exchangeFee = 0;
  oldExchange.forEach(function(item) { exchangeFee += (EXCHANGE_FEES[item.productId] || 0) * item.qty; });

  if (oldFreeEx.length > 0) {
    var billId = document.getElementById('exFreeExBillId').value.trim();
    if (!billId) {
      alert('❌ กรุณากรอกรหัสบิลเก่าสำหรับ Free Exchange');
      return;
    }
  }

  var switchFee = 0;
  oldSwitch.forEach(function(item) { switchFee += (EXCHANGE_FEES_SWITCH[item.productId] || 0) * item.qty; });

  var newPremium = calcPremium(newGold);
  var freeExPremiumDeduct = 0;

  if (oldFreeEx.length > 0) {
    var freeExPrem = calcPremium(oldFreeEx);
    freeExPremiumDeduct = Math.min(freeExPrem, newPremium);
  }

  var premium = newPremium - freeExPremiumDeduct;
  var total = roundTo1000(exchangeFee + switchFee + premium);

  var allOldGold = oldExchange.concat(oldSwitch).concat(oldFreeEx);

  var freeExBillId = '';
  var freeExBillSheet = '';
  if (oldFreeEx.length > 0) {
    freeExBillId = document.getElementById('exFreeExBillId').value.trim();
    if (_exFreeExBillData) {
      freeExBillSheet = _exFreeExBillData.sheet;
    }
  }

  try {
    _isSubmitting = true;
    showLoading();
    var result = await callAppsScript('ADD_EXCHANGE', {
      phone: phone,
      oldGold: JSON.stringify(mergeItems(allOldGold)),
      newGold: JSON.stringify(mergeItems(newGold)),
      exchangeFee: exchangeFee,
      premium: premium,
      total: total,
      switchOldGold: JSON.stringify(mergeItems(oldSwitch)),
      switchFee: switchFee,
      freeExOldGold: JSON.stringify(mergeItems(oldFreeEx)),
      freeExBillId: freeExBillId,
      freeExPremiumDeduct: freeExPremiumDeduct,
      freeExBillSheet: freeExBillSheet,
      sell1Baht: currentPricing.sell1Baht,
      user: currentUser.nickname
    });
    if (result.success) {
      endSubmit();
      showToast('✅ สร้างรายการ Exchange สำเร็จ!');
      closeModal('exchangeModal');
      resetExchangeForm();
      loadExchanges();
    } else {
      alert('❌ ' + result.message);
      endSubmit();
    }
  } catch(e) {
    alert('❌ ' + e.message);
    endSubmit();
  }
}

function resetExchangeForm() {
  document.getElementById('exchangePhone').value = '';
  ['exNewGold', 'exOldExchange', 'exOldSwitch', 'exOldFreeEx'].forEach(function(id) { document.getElementById(id).innerHTML = ''; });
  document.getElementById('exFreeExBillId').value = '';
  document.getElementById('exFreeExStatus').innerHTML = '';
  _exFreeExVerified = false;
  _exFreeExBillData = null;
  _exRowCounter = 0;
}

async function loadCurrentPricingForExchange() {
  try {
    var pricingData = await fetchSheetData('Pricing!A:B');
    if (pricingData.length > 1) {
      var latestPricing = pricingData[pricingData.length - 1];
      currentPricing = { sell1Baht: parseFloat(String(latestPricing[1]).replace(/,/g, '')) || 0, buyback1Baht: 0 };
      return true;
    }
    return false;
  } catch(e) { return false; }
}

async function openExchangeModal() {
  var hasPrice = await loadCurrentPricingForExchange();
  if (!hasPrice || !currentPricing.sell1Baht || currentPricing.sell1Baht === 0) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  resetExchangeForm();
  addExRow('exNewGold');
  addExRow('exOldExchange');
  openModal('exchangeModal');
}

function resetExchangeDateFilter() {
  var today = getTodayDateString();
  document.getElementById('exchangeDateFrom').value = today;
  document.getElementById('exchangeDateTo').value = today;
  exchangeDateFrom = today;
  exchangeDateTo = today;
  loadExchanges();
}

document.addEventListener('DOMContentLoaded', function() {
  var fromInput = document.getElementById('exchangeDateFrom');
  var toInput = document.getElementById('exchangeDateTo');
  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      exchangeDateFrom = this.value;
      if (exchangeDateFrom && !exchangeDateTo) { exchangeDateTo = exchangeDateFrom; toInput.value = exchangeDateTo; }
      if (exchangeDateFrom && exchangeDateTo) loadExchanges();
    });
    toInput.addEventListener('change', function() {
      exchangeDateTo = this.value;
      if (exchangeDateTo && !exchangeDateFrom) { exchangeDateFrom = exchangeDateTo; fromInput.value = exchangeDateFrom; }
      if (exchangeDateFrom && exchangeDateTo) loadExchanges();
    });
  }
});

var currentExchangePayment = null;
