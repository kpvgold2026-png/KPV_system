async function loadTradeins() {
  try {
    var tbody = document.getElementById('tradeinTable');
    tbody.innerHTML = '<tr><td colspan="12" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    var filters = { type: 'eq.TRADEIN' };
    var order = tradeinSortOrder === 'asc' ? 'date.asc' : 'date.desc';
    if (currentUser.role === 'User') filters.sale_user_id = 'eq.' + currentUser.id;

    var dateFrom = tradeinDateFrom;
    var dateTo = tradeinDateTo;
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
      var oldI = (r.items || []).filter(function(i) { return i.item_role === 'OLD'; });
      var newI = (r.items || []).filter(function(i) { return i.item_role === 'NEW'; });
      var focI = (r.items || []).filter(function(i) { return i.item_role === 'FOC'; });
      var allOld = oldI.concat(focI);
      return Object.assign({}, r, {
        _oldJson: JSON.stringify(allOld.map(function(i) { return { productId: i.product_id, qty: i.qty }; })),
        _newJson: JSON.stringify(newI.map(function(i) { return { productId: i.product_id, qty: i.qty }; })),
        _focJson: JSON.stringify(focI.map(function(i) { return { productId: i.product_id, qty: i.qty }; })),
        _pureOldJson: JSON.stringify(oldI.map(function(i) { return { productId: i.product_id, qty: i.qty }; })),
        _saleName: r.sale ? r.sale.nickname : ''
      });
    });

    if (data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="12" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var oldGold = formatItemsForTable(row._oldJson);
      var newGold = formatItemsForTable(row._newJson);
      var premium = parseFloat(row.premium) || 0;
      var saleName = row._saleName;
      var status = row.status;
      var actions = '';

      if (status === 'PENDING') {
        if (isManager()) {
          actions = '<button class="btn-action" onclick="reviewTradein(\'' + row.id + '\')">Review</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for review</span>';
        }
      } else if (status === 'APPROVED') {
        if (currentUser.role === 'User') {
          actions = '<button class="btn-action" onclick="openTradeinPaymentModal(\'' + row.id + '\')">Confirm</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for confirmation</span>';
        }
      } else {
        var paid = parseFloat(row.paid) || 0;
        var change = parseFloat(row.change_amount) || 0;
        var payInfo = paid > 0 ? formatNumber(paid) + ' ' + (row.currency || 'LAK') : '-';
        var focGoldStr = row._focJson !== '[]' ? formatItemsForTable(row._focJson) : '-';
        var pureOldGold = row._focJson !== '[]' ? formatItemsForTable(row._pureOldJson) : oldGold;
        var focPremDeduct = row.foc_premium_deduct ? formatNumber(row.foc_premium_deduct) + ' LAK' : '-';
        var focBillRef = row.foc_bill_ref || '-';
        var detail = encodeURIComponent(JSON.stringify([
          ['Transaction ID', row.id],
          ['BILL ID', row.bill_id || '-'],
          ['Phone', row.phone],
          ['F.O.C รหัสบิลเก่า', focBillRef],
          ['F.O.C (Old Gold)', focGoldStr],
          ['Old Gold', pureOldGold],
          ['New Gold', newGold],
          ['Difference', formatNumber(row.diff_amount) + ' LAK'],
          ['Premium', formatNumber(premium) + ' LAK'],
          ['FOC Premium หัก', focPremDeduct],
          ['Total', formatNumber(row.total) + ' LAK'],
          ['Customer Paid', payInfo],
          ['Change', change > 0 ? formatNumber(change) + ' LAK' : '-'],
          ['Date', formatDateTime(row.date)],
          ['Status', status],
          ['Sale', saleName]
        ]));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Trade-in\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      }

      return '<tr>' +
        '<td>' + row.id + '</td>' +
        '<td>' + (row.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + (row.date ? formatDateTime(row.date) : '') + '</td>' +
        '<td>' + row.phone + '</td>' +
        '<td>' + oldGold + '</td>' +
        '<td>' + newGold + '</td>' +
        '<td>' + formatNumber(row.diff_amount) + '</td>' +
        '<td>' + formatNumber(premium) + '</td>' +
        '<td>' + formatNumber(row.total) + '</td>' +
        '<td><span class="status-badge status-' + status.toLowerCase() + '">' + status + '</span></td>' +
        '<td>' + saleName + '</td>' +
        '<td>' + actions + '</td>' +
        '</tr>';
    }).join('');
  } catch (error) {
    console.error('Error loading tradeins:', error);
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
  if (newPremium > 0 && focPremium > 0) premium = Math.max(0, newPremium - focPremium);

  var total = 0;
  var diffValue = 0;
  if (newWeight > totalOldWeight && currentPricing.sell1Baht > 0) {
    diffValue = (newWeight - totalOldWeight) * currentPricing.sell1Baht;
    total = roundNearest1000(Math.round(diffValue) + premium);
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
  if (!phone || phone.length !== 8) { alert('กรุณากรอกเบอร์โทร 8 หลัก'); return; }
  var billId = document.getElementById('tradeinBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) { alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก'); return; }

  var focGold = mergeItems(collectItems('tradeinFocGold'));
  var oldGold = mergeItems(collectItems('tradeinOldGold'));
  var newGold = mergeItems(collectItems('tradeinNewGold'));

  if (oldGold.length === 0 && focGold.length === 0) { alert('กรุณาเลือกทองเก่าอย่างน้อย 1 รายการ'); return; }
  if (newGold.length === 0) { alert('กรุณาเลือกทองใหม่'); return; }
  if (focGold.length > 0) {
    var focRef = document.getElementById('tradeinFocBillRef') ? document.getElementById('tradeinFocBillRef').value.trim() : '';
    if (!focRef) { alert('กรุณากรอกรหัสบิลเก่าสำหรับ F.O.C'); return; }
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
    alert('❌ น้ำหนักทองใหม่ต้องมากกว่าทองเก่ารวม!\nทองเก่ารวม: ' + totalOldWeight.toFixed(3) + ' บาท\nทองใหม่: ' + newWeight.toFixed(3) + ' บาท');
    return;
  }

  var premium = newPremium;
  if (newPremium > 0 && focPremium > 0) premium = Math.max(0, newPremium - focPremium);

  var difference = (newWeight - totalOldWeight) * currentPricing.sell1Baht;
  var total = roundNearest1000(Math.round(difference) + premium);

  try {
    _isSubmitting = true;
    showLoading();
    var focBillRef = document.getElementById('tradeinFocBillRef') ? document.getElementById('tradeinFocBillRef').value.trim() : '';
    var result = await dbRpc('create_tradein_tx', {
      p_phone: phone,
      p_bill_id: billId,
      p_old_items: oldGold,
      p_new_items: newGold,
      p_foc_items: focGold,
      p_foc_bill_ref: focBillRef,
      p_difference: difference,
      p_premium: premium,
      p_foc_premium_deduct: Math.min(focPremium, newPremium),
      p_total: total,
      p_sell_1baht: currentPricing.sell1Baht
    });

    if (result && result.success) {
      endSubmit();
      showToast('✅ สร้างรายการแลกเปลี่ยนสำเร็จ!');
      try { if (billId) await dbRpc('check_duplicate_bill_id', { p_bill_id: billId }); } catch(e) {}
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
      alert('❌ เกิดข้อผิดพลาด: ' + (result && result.message ? result.message : 'Unknown'));
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function loadCurrentPricing() {
  try {
    await fetchCurrentPricing();
    return currentPricing.sell1Baht > 0;
  } catch (error) {
    return false;
  }
}

async function openTradeinModal() {
  var hasPrice = await loadCurrentPricing();
  if (!hasPrice) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  openModal('tradeinModal');
}

function resetTradeinDateFilter() {
  var today = getTodayDateString();
  document.getElementById('tradeinDateFrom').value = today;
  document.getElementById('tradeinDateTo').value = today;
  tradeinDateFrom = today;
  tradeinDateTo = today;
  loadTradeins();
}

document.addEventListener('DOMContentLoaded', function() {
  var fromInput = document.getElementById('tradeinDateFrom');
  var toInput = document.getElementById('tradeinDateTo');
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
