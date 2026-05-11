async function loadWithdraws() {
  try {
    var tbody = document.getElementById('withdrawTable');
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:30px;"><div style="display:inline-block;width:24px;height:24px;border:3px solid var(--border-color);border-top:3px solid var(--gold-primary);border-radius:50%;animation:spin 0.8s linear infinite;"></div></td></tr>';

    var filters = { type: 'eq.WITHDRAW' };
    var order = withdrawSortOrder === 'asc' ? 'date.asc' : 'date.desc';
    if (currentUser.role === 'User') filters.sale_user_id = 'eq.' + currentUser.id;

    var dateFrom = withdrawDateFrom;
    var dateTo = withdrawDateTo;
    if (!dateFrom && !dateTo && (currentUser.role === 'User' || isManager())) {
      var today = getTodayLocalStr();
      dateFrom = today; dateTo = today;
    }
    if (dateFrom && dateTo) {
      filters['and'] = '(date.gte.' + dateFrom + 'T00:00:00,date.lte.' + dateTo + 'T23:59:59)';
    }

    var rows = await dbSelect('transactions', {
      select: '*,items:transaction_items(product_id,qty,item_role),sale:users!sale_user_id(nickname)',
      filters: filters,
      order: order,
      useCache: false
    });

    var data = (rows || []).map(function(r) {
      var newI = (r.items || []).filter(function(i) { return i.item_role === 'NEW'; });
      return Object.assign({}, r, {
        _itemsJson: JSON.stringify(newI.map(function(i) { return { productId: i.product_id, qty: i.qty }; })),
        _saleName: r.sale ? r.sale.nickname : ''
      });
    });

    if (data.length === 0) {
      tbody.innerHTML = '<tr><td colspan="9" style="text-align: center; padding: 40px;">No records</td></tr>';
      return;
    }

    tbody.innerHTML = data.map(function(row) {
      var items = formatItemsForTable(row._itemsJson);
      var premium = parseFloat(row.premium) || 0;
      var total = parseFloat(row.total) || premium;
      var saleName = row._saleName;
      var status = row.status;
      var actions = '';

      if (status === 'PENDING') {
        if (isManager()) {
          actions = '<button class="btn-action" onclick="reviewWithdraw(\'' + row.id + '\')">Review</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for review</span>';
        }
      } else if (status === 'APPROVED' || status === 'READY') {
        if (currentUser.role === 'User') {
          actions = '<button class="btn-action" onclick="openWithdrawPaymentModal(\'' + row.id + '\')">Confirm</button>';
        } else {
          actions = '<span style="color: var(--text-secondary);">Waiting for confirmation</span>';
        }
      } else {
        var wdPaid = parseFloat(row.paid) || 0;
        var detail = encodeURIComponent(JSON.stringify([
          ['Transaction ID', row.id],
          ['BILL ID', row.bill_id || '-'],
          ['Phone', row.phone],
          ['Withdraw Code', row.withdraw_code || '-'],
          ['Items', items],
          ['Premium', formatNumber(premium) + ' LAK'],
          ['Total', formatNumber(total) + ' LAK'],
          ['Customer Paid', wdPaid > 0 ? formatNumber(wdPaid) + ' LAK' : '-'],
          ['Note', row.note || '-'],
          ['Date', formatDateTime(row.date)],
          ['Status', status],
          ['Sale', saleName]
        ]));
        actions = '<button class="btn-action" onclick="viewTransactionDetail(\'Withdraw\',\'' + detail + '\')" style="background:#555;">👁 View</button>';
      }

      return '<tr>' +
        '<td>' + row.id + '</td>' +
        '<td>' + (row.bill_id || '-') + '</td>' +
        '<td style="font-size:11px;white-space:nowrap;">' + (row.date ? formatDateTime(row.date) : '') + '</td>' +
        '<td>' + row.phone + '</td>' +
        '<td>' + (row.withdraw_code || '') + '</td>' +
        '<td>' + items + '</td>' +
        '<td>' + formatNumber(premium) + '</td>' +
        '<td>' + formatNumber(total) + '</td>' +
        '<td><span class="status-badge status-' + status.toLowerCase() + '">' + status + '</span></td>' +
        '<td>' + saleName + '</td>' +
        '<td>' + actions + '</td>' +
        '</tr>';
    }).join('');
  } catch (error) {
    console.error('Error loading withdraws:', error);
  }
}

let withdrawCounter = 0;

function addWithdrawProduct() {
  withdrawCounter++;
  var productOptions = FIXED_PRODUCTS.map(function(p) {
    return '<option value="' + p.id + '">' + p.name + '</option>';
  }).join('');

  document.getElementById('withdrawProducts').insertAdjacentHTML('beforeend',
    '<div class="product-row" id="withdraw' + withdrawCounter + '">' +
      '<select class="form-select" style="flex: 2;" onchange="calculateWithdrawPremium()">' +
        '<option value="">Select Product</option>' + productOptions +
      '</select>' +
      '<input type="number" class="form-input" placeholder="Qty" min="1" style="flex: 1;" oninput="calculateWithdrawPremium()">' +
      '<button type="button" class="btn-remove" onclick="document.getElementById(\'withdraw' + withdrawCounter + '\').remove(); calculateWithdrawPremium();">×</button>' +
    '</div>'
  );
}

function calculateWithdrawPremium() {
  var products = [];
  document.querySelectorAll('#withdrawProducts .product-row').forEach(function(row) {
    var productId = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) products.push({ productId: productId, qty: qty });
  });

  var premium = 0;
  products.forEach(function(item) {
    if (PREMIUM_PRODUCTS.includes(item.productId) || item.productId === 'G07') {
      premium += PREMIUM_PER_PIECE * item.qty;
    }
  });

  var el = document.getElementById('withdrawPremium');
  if (el) el.value = formatNumber(premium) + ' LAK';
  return premium;
}

async function calculateWithdraw() {
  if (_isSubmitting) return;
  var phone = document.getElementById('withdrawPhone').value.replace(/\D/g, '');
  var withdrawCode = document.getElementById('withdrawCode').value.trim();
  if (!phone || phone.length !== 8) { alert('กรุณากรอกเบอร์โทร 8 หลัก'); return; }
  if (!withdrawCode) { alert('กรุณากรอกรหัสถอน'); return; }
  var billId = document.getElementById('withdrawBillId').value.replace(/\D/g, '');
  if (!billId || billId.length !== 6) { alert('กรุณากรอก BILL ID ตัวเลข 6 หลัก'); return; }

  var products = [];
  document.querySelectorAll('#withdrawProducts .product-row').forEach(function(row) {
    var productId = row.querySelector('select').value;
    var qty = parseInt(row.querySelector('input').value) || 0;
    if (productId && qty > 0) products.push({ productId: productId, qty: qty });
  });

  if (products.length === 0) { alert('กรุณาเลือกสินค้า'); return; }

  var premium = 0;
  products.forEach(function(item) {
    if (PREMIUM_PRODUCTS.includes(item.productId) || item.productId === 'G07') {
      premium += PREMIUM_PER_PIECE * item.qty;
    }
  });
  var total = roundTo1000(premium);

  try {
    _isSubmitting = true;
    showLoading();
    var result = await dbRpc('create_withdraw_tx', {
      p_phone: phone,
      p_bill_id: billId,
      p_items: mergeItems(products),
      p_premium: premium,
      p_total: total,
      p_withdraw_code: withdrawCode,
      p_sell_1baht: currentPricing.sell1Baht
    });

    if (result && result.success) {
      endSubmit();
      showToast('✅ สร้างรายการถอนทองสำเร็จ!');
      closeModal('withdrawModal');
      document.getElementById('withdrawPhone').value = '';
      document.getElementById('withdrawBillId').value = '';
      document.getElementById('withdrawCode').value = '';
      document.getElementById('withdrawProducts').innerHTML = '';
      withdrawCounter = 0;
      addWithdrawProduct();
      loadWithdraws();
    } else {
      alert('❌ เกิดข้อผิดพลาด: ' + (result && result.message ? result.message : 'Unknown'));
      endSubmit();
    }
  } catch (error) {
    alert('❌ เกิดข้อผิดพลาด: ' + error.message);
    endSubmit();
  }
}

async function loadCurrentPricingForWithdraw() {
  try {
    await fetchCurrentPricing();
    return currentPricing.sell1Baht > 0;
  } catch (error) {
    return false;
  }
}

async function openWithdrawModal() {
  var hasPrice = await loadCurrentPricingForWithdraw();
  if (!hasPrice) {
    alert('❌ ยังไม่มีราคาทองในระบบ! กรุณาไปที่หน้า Products → Set New Price ก่อน');
    return;
  }
  openModal('withdrawModal');
}

function resetWithdrawDateFilter() {
  var today = getTodayDateString();
  document.getElementById('withdrawDateFrom').value = today;
  document.getElementById('withdrawDateTo').value = today;
  withdrawDateFrom = today;
  withdrawDateTo = today;
  loadWithdraws();
}

document.addEventListener('DOMContentLoaded', function() {
  var fromInput = document.getElementById('withdrawDateFrom');
  var toInput = document.getElementById('withdrawDateTo');
  if (fromInput && toInput) {
    fromInput.addEventListener('change', function() {
      withdrawDateFrom = this.value;
      if (withdrawDateFrom && !withdrawDateTo) { withdrawDateTo = withdrawDateFrom; toInput.value = withdrawDateTo; }
      if (withdrawDateFrom && withdrawDateTo) loadWithdraws();
    });
    toInput.addEventListener('change', function() {
      withdrawDateTo = this.value;
      if (withdrawDateTo && !withdrawDateFrom) { withdrawDateFrom = withdrawDateTo; fromInput.value = withdrawDateFrom; }
      if (withdrawDateFrom && withdrawDateTo) loadWithdraws();
    });
  }
});

let currentWithdrawPayment = null;
