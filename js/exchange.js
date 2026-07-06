var _exRowCounter = 0;
var _exFreeExVerified = false;
var _exFreeExBillData = null;

async function loadExchanges() {
  try {
    var tbody = document.getElementById('exchangeTable');
    tbody.innerHTML = '<tr><td colspan="13" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    var filters = { type: 'eq.EXCHANGE' };
    var order = exchangeSortOrder === 'asc' ? 'date.asc' : 'date.desc';
    if (currentUser.role === 'User') filters.sale_user_id = 'eq.' + currentUser.id;

    var dateFrom = exchangeDateFrom;
    var dateTo = exchangeDateTo;
    if (!dateFrom && !dateTo && (currentUser.role === 'User' || isManager())) {
      var today = getTodayLocalStr();
      dateFrom = today; dateTo = today;
    }
    // anchor เป็นเวลา Bangkok (+07:00) — DB เก็บ date เป็น UTC (NOW()) ถ้าไม่ใส่ offset
    // PostgREST จะตีความเป็น UTC ทำให้รายการช่วงเช้ามืด (Bangkok) หลุดออกจากช่วง
    if (dateFrom && dateTo) {
      filters['and'] = '(date.gte.' + dateFrom + 'T00:00:00+07:00,date.lte.' + dateTo + 'T23:59:59+07:00)';
    } else if (dateFrom) {
      filters['date'] = 'gte.' + dateFrom + 'T00:00:00+07:00';
    } else if (dateTo) {
      filters['date'] = 'lte.' + dateTo + 'T23:59:59+07:00';
    }

    var rows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role),sale:users!sale_user_id(nickname)',
      filters: filters,
      order: order,
      useCache: false
    });

    var data = (rows || []).map(function(r) {
      var newI = (r.items || []).filter(function(i) { return i.item_role === 'NEW'; });
      var oldI = (r.items || []).filter(function(i) { return i.item_role === 'OLD'; });
      var swI = (r.items || []).filter(function(i) { return i.item_role === 'SWITCH'; });
      var feI = (r.items || []).filter(function(i) { return i.item_role === 'FREE_EX'; });
      var allOld = oldI.concat(swI).concat(feI);
      var toItems = function(arr) { return arr.map(function(i) { return { productId: i.product_id, qty: i.qty }; }); };
      return Object.assign({}, r, {
        _newJson: JSON.stringify(toItems(newI)),
        _oldAllJson: JSON.stringify(toItems(allOld)),
        _oldPureJson: JSON.stringify(toItems(oldI)),
        _switchJson: JSON.stringify(toItems(swI)),
        _freeExJson: JSON.stringify(toItems(feI)),
        _saleName: r.sale ? r.sale.nickname : ''
      });
    });

    if (data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="13" style="text-align:center;padding:40px;">No records</td></tr>';
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var oldGold = formatItemsForTable(row._oldAllJson);
      var newGold = formatItemsForTable(row._newJson);
      var exFee = parseFloat(row.ex_fee) || 0;
      var switchFee = parseFloat(row.switch_fee) || 0;
      var premium = parseFloat(row.premium) || 0;
      var total = parseFloat(row.total) || 0;
      var status = row.status;
      var sale = row._saleName;
      var actions = '';

      if (status === 'PENDING') {
        if (isManager()) {
          actions = '<button class="btn-action" onclick="reviewExchange(\'' + row.id + '\')">Review</button>';
        } else {
          actions = '<span style="color:var(--text-secondary);">Waiting</span>';
        }
      } else if (status === 'APPROVED') {
        if (currentUser.role === 'User') {
          actions = '<button class="btn-action" onclick="openExchangePaymentModal(\'' + row.id + '\')">Confirm</button>';
        } else {
          actions = '<span style="color:var(--text-secondary);">Waiting</span>';
        }
      } else {
        var exPaid = parseFloat(row.paid) || 0;
        var exChange = parseFloat(row.change_amount) || 0;
        var exPayInfo = exPaid > 0 ? formatNumber(exPaid) + ' ' + (row.currency || 'LAK') : '-';
        var detail = encodeURIComponent(JSON.stringify([
          ['Transaction ID', row.id],
          ['BILL ID', row.bill_id || '-'],
          ['Phone', row.phone],
          ['New Gold', newGold],
          ['Old Gold (Exchange)', formatItemsForTable(row._oldPureJson)],
          ['Exchange Fee', formatNumber(exFee) + ' LAK'],
          ['Switch Old Gold', formatItemsForTable(row._switchJson)],
          ['Switch Fee', formatNumber(switchFee) + ' LAK'],
          ['Free Ex Old Gold', formatItemsForTable(row._freeExJson)],
          ['Free Ex Bill', row.free_ex_bill_ref || '-'],
          ['Premium', formatNumber(premium) + ' LAK'],
          ['Total', formatNumber(total) + ' LAK'],
          ['Customer Paid', exPayInfo],
          ['Change', exChange > 0 ? formatNumber(exChange) + ' LAK' : '-'],
          ['Date', formatDateTime(row.date)],
          ['Status', status],
          ['Sale', sale]
        ]));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Exchange\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      }

      return '<tr>' +
        '<td>' + row.id + '</td>' +
        '<td>' + (row.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + (row.date ? formatDateTime(row.date) : '') + '</td>' +
        '<td>' + row.phone + '</td>' +
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
    var billRows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role)',
      filters: { bill_id: 'eq.' + billId },
      useCache: false
    });
    hideLoading();

    if (!billRows || billRows.length === 0) {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ ไม่พบบิล ' + billId + '</span>';
      return;
    }

    var bill = billRows.find(function(b) { return b.status === 'COMPLETED' || b.status === 'PAID'; }) || billRows[0];

    if (bill.status !== 'COMPLETED' && bill.status !== 'PAID') {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้สถานะ ' + bill.status + '</span>';
      return;
    }

    var usedCheck = await dbSelect('transactions', {
      select: 'id',
      filters: { free_ex_bill_ref: 'eq.' + billId },
      useCache: false
    });
    if (usedCheck && usedCheck.length > 0) {
      statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้ถูกนำไปแลก Free Ex แล้ว</span>';
      return;
    }

    if (bill.date) {
      var bd = new Date(bill.date);
      var now = new Date();
      var diffDays = (now - bd) / (1000 * 60 * 60 * 24);
      if (diffDays > 30) {
        statusEl.innerHTML = '<span style="color:#f44336;">❌ บิลนี้เกิน 1 เดือนแล้ว (' + Math.floor(diffDays) + ' วัน)</span>';
        return;
      }
    }

    var billItems = {};
    (bill.items || []).filter(function(i) { return i.item_role === 'NEW'; }).forEach(function(i) {
      billItems[i.product_id] = (billItems[i.product_id] || 0) + parseFloat(i.qty);
    });

    for (var fi = 0; fi < freeExItems.length; fi++) {
      var fItem = freeExItems[fi];
      var available = billItems[fItem.productId] || 0;
      if (fItem.qty > available) {
        statusEl.innerHTML = '<span style="color:#f44336;">❌ ' + fItem.productId + ' ในบิลมี ' + available + ' ชิ้น แต่กรอก ' + fItem.qty + ' ชิ้น</span>';
        return;
      }
    }

    _exFreeExVerified = true;
    _exFreeExBillData = { billId: billId };
    statusEl.innerHTML = '<span style="color:#4caf50;">✅ ตรวจสอบผ่าน — บิล ' + billId + '</span>';

  } catch(e) {
    hideLoading();
    statusEl.innerHTML = '<span style="color:#f44336;">❌ ' + e.message + '</span>';
  }
}

async function calculateExchangeNew() {
  if (_isSubmitting) return;
  var phone = document.getElementById('exchangePhone').value.replace(/\D/g, '');
  if (!phone || phone.length !== 8) { alert('กรุณากรอกเบอร์โทร 8 หลัก'); return; }
  var billId = document.getElementById('exchangeBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) { alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก'); return; }

  var newGold = getItemsFromContainer('exNewGold');
  var oldExchange = getItemsFromContainer('exOldExchange');
  var oldSwitch = getItemsFromContainer('exOldSwitch');
  var oldFreeEx = getItemsFromContainer('exOldFreeEx');

  if (newGold.length === 0) { alert('กรุณาเพิ่มทองใหม่'); return; }
  if (oldExchange.length === 0 && oldSwitch.length === 0 && oldFreeEx.length === 0) {
    alert('กรุณาเพิ่มทองเก่าอย่างน้อย 1 section'); return;
  }

  var newW = calcWeight(newGold);
  var oldW = calcWeight(oldExchange) + calcWeight(oldSwitch) + calcWeight(oldFreeEx);

  if (Math.abs(newW - oldW) > 0.001) {
    alert('❌ น้ำหนักทองเก่าและทองใหม่ต้องเท่ากัน!\nทองใหม่: ' + (newW * 15).toFixed(3) + ' g\nทองเก่ารวม: ' + (oldW * 15).toFixed(3) + ' g');
    return;
  }

  var exchangeFee = 0;
  oldExchange.forEach(function(item) { exchangeFee += (EXCHANGE_FEES[item.productId] || 0) * item.qty; });

  if (oldFreeEx.length > 0) {
    var freeBillId = document.getElementById('exFreeExBillId').value.trim();
    if (!freeBillId) { alert('❌ กรุณากรอกรหัสบิลเก่าสำหรับ Free Exchange'); return; }
    // บังคับให้ผ่านการตรวจสอบบิลก่อน — และบิลที่ตรวจต้องเป็นเลขเดียวกับในช่อง
    if (!_exFreeExVerified || !_exFreeExBillData || _exFreeExBillData.billId !== freeBillId) {
      alert('❌ กรุณากดปุ่ม "ตรวจสอบ" บิล Free Ex ให้ผ่านก่อนทำรายการ');
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

  var freeExBillId = '';
  if (oldFreeEx.length > 0) freeExBillId = document.getElementById('exFreeExBillId').value.trim();

  try {
    _isSubmitting = true;
    showLoading();
    var result = await dbRpc('create_exchange_tx', {
      p_phone: phone,
      p_bill_id: billId,
      p_new_items: mergeItems(newGold),
      p_old_exchange_items: mergeItems(oldExchange),
      p_switch_items: mergeItems(oldSwitch),
      p_free_ex_items: mergeItems(oldFreeEx),
      p_exchange_fee: exchangeFee,
      p_switch_fee: switchFee,
      p_premium: premium,
      p_total: total,
      p_free_ex_bill_ref: freeExBillId,
      p_sell_1baht: currentPricing.sell1Baht
    });

    if (result && result.success) {
      endSubmit();
      showToast('✅ สร้างรายการ Exchange สำเร็จ!');
      try { if (billId) await dbRpc('check_duplicate_bill_id', { p_bill_id: billId }); } catch(e) {}
      closeModal('exchangeModal');
      resetExchangeForm();
      loadExchanges();
    } else {
      alert('❌ ' + (result && result.message ? result.message : 'Unknown'));
      endSubmit();
    }
  } catch(e) {
    alert('❌ ' + e.message);
    endSubmit();
  }
}

function resetExchangeForm() {
  document.getElementById('exchangePhone').value = '';
  document.getElementById('exchangeBillId').value = '';
  ['exNewGold', 'exOldExchange', 'exOldSwitch', 'exOldFreeEx'].forEach(function(id) { document.getElementById(id).innerHTML = ''; });
  document.getElementById('exFreeExBillId').value = '';
  document.getElementById('exFreeExStatus').innerHTML = '';
  _exFreeExVerified = false;
  _exFreeExBillData = null;
  _exRowCounter = 0;
}

async function loadCurrentPricingForExchange() {
  try {
    await fetchCurrentPricing();
    return currentPricing.sell1Baht > 0;
  } catch(e) { return false; }
}

async function openExchangeModal() {
  var hasPrice = await loadCurrentPricingForExchange();
  if (!hasPrice) {
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
